-- 0004 — уровни постоянных клиентов, бонус на день рождения, акции по дням недели,
-- согласие на обработку данных, удаление аккаунта клиентом, отчёт по сотрудникам, проверка слабых паролей.

-- ----------------------------------------------------------------- настройки и поля
insert into app_private.config (key, value) values
  ('tier1_from', '0'),        -- «Серебро»: с какой суммы покупок за всё время (₽); 0 = уровень выключен
  ('tier1_percent', '0'),     -- процент возврата на этом уровне
  ('tier2_from', '0'),        -- «Золото»
  ('tier2_percent', '0'),
  ('birthday_bonus', '0'),    -- подарок на день рождения (0 = не дарить)
  ('promo_days', ''),         -- дни недели с акцией: цифры 1 (пн) … 7 (вс), например 67
  ('promo_mult', '2'),        -- во сколько раз больше бонусов в эти дни
  ('require_consent', '1')    -- 1 = регистрация требует согласия на обработку данных
on conflict (key) do nothing;

alter table app_private.users add column if not exists birthday date;
alter table app_private.users add column if not exists consent_at timestamptz;
alter table app_private.users add column if not exists deleted_at timestamptz;

-- ----------------------------------------------------------------- процент возврата клиента
-- Итоговый процент = наибольший из базового и процента уровня, умноженный на акцию дня.
create or replace function app_private.earn_info(p_uid int, p_at timestamptz default now()) returns jsonb
language plpgsql stable as $$
declare
  base int := app_private.cfg_int('earn_percent');
  t1f int := app_private.cfg_int('tier1_from'); t1p int := app_private.cfg_int('tier1_percent');
  t2f int := app_private.cfg_int('tier2_from'); t2p int := app_private.cfg_int('tier2_percent');
  turn bigint; pct int := base; tier int := 0; mult int := 1; days text := app_private.cfg('promo_days');
  dow int; nxt jsonb;
begin
  select coalesce(sum(amount), 0) into turn from app_private.events where user_id = p_uid and not cancelled;
  if t1f > 0 and turn >= t1f and t1p > pct then pct := t1p; tier := 1; end if;
  if t2f > 0 and turn >= t2f and t2p > pct then pct := t2p; tier := 2; end if;
  if tier < 2 and t2f > 0 and t2p > pct and turn < t2f then
    nxt := jsonb_build_object('name', 'Золото', 'left', t2f - turn, 'percent', t2p);
  end if;
  if tier = 0 and t1f > 0 and t1p > base and turn < t1f then
    nxt := jsonb_build_object('name', 'Серебро', 'left', t1f - turn, 'percent', t1p);
  end if;
  dow := extract(isodow from p_at at time zone app_private.cfg('timezone'))::int;
  if days <> '' and position(dow::text in days) > 0 then mult := greatest(1, app_private.cfg_int('promo_mult')); end if;
  return jsonb_build_object('percent', least(100, pct * mult), 'base', base, 'tier', tier,
    'tier_name', case tier when 1 then 'Серебро' when 2 then 'Золото' else null end,
    'tier_percent', pct, 'promo', mult, 'next_tier', nxt, 'turnover', turn);
end $$;

-- ----------------------------------------------------------------- активность, сгорание, подарок на день рождения
create or replace function app_private.last_activity(p_uid int) returns timestamptz
language sql stable as $$
  select greatest(u.created_at,
                  coalesce((select max(e.created_at) from app_private.events e
                             where e.user_id = u.id and not e.cancelled), u.created_at),
                  coalesce((select max(a.created_at) from app_private.adjustments a
                             where a.user_id = u.id and a.delta > 0), u.created_at))
    from app_private.users u where u.id = p_uid $$;

create or replace function app_private.sweep_user(p_uid int) returns void
language plpgsql as $$
declare
  d int := app_private.cfg_int('expire_days'); bal int; bd date;
  tz text := app_private.cfg('timezone'); today date := (now() at time zone tz)::date;
  this date; gift int := app_private.cfg_int('birthday_bonus'); tag text;
begin
  if d > 0 then
    perform pg_advisory_xact_lock(p_uid);
    select b.balance into bal from app_private.balance(p_uid) b;
    if bal > 0 and app_private.last_activity(p_uid) < now() - make_interval(days => d) then
      insert into app_private.adjustments (user_id, delta, reason) values (p_uid, -bal, 'expire');
      perform app_private.notify_user(p_uid,
        format('⌛ %s %s сгорели: больше %s дней не было покупок.', bal, app_private.bonus_word(bal), d));
    end if;
  end if;
  if gift > 0 then
    select birthday into bd from app_private.users where id = p_uid;
    if bd is not null then
      begin
        this := make_date(extract(year from today)::int, extract(month from bd)::int, extract(day from bd)::int);
      exception when others then
        this := make_date(extract(year from today)::int, 2, 28);          -- 29 февраля в невисокосный год
      end;
      tag := 'birthday:' || extract(year from today)::int;
      if today >= this and today < this + 7
         and not exists (select 1 from app_private.adjustments where user_id = p_uid and reason = tag) then
        perform pg_advisory_xact_lock(p_uid);
        if not exists (select 1 from app_private.adjustments where user_id = p_uid and reason = tag) then
          insert into app_private.adjustments (user_id, delta, reason) values (p_uid, gift, tag);
          perform app_private.notify_user(p_uid,
            format('🎂 С днём рождения! Дарим вам %s %s.', gift, app_private.bonus_word(gift)));
        end if;
      end if;
    end if;
  end if;
end $$;

create or replace function app_private.customer_view(p_uid int) returns jsonb
language plpgsql as $$
declare r jsonb; d int := app_private.cfg_int('expire_days'); bal int; exp bigint; ei jsonb;
begin
  if exists (select 1 from app_private.users where id = p_uid and deleted_at is not null) then
    perform app_private.fail('PT404', 'Клиент не найден');
  end if;
  perform app_private.sweep_user(p_uid);
  select b.balance into bal from app_private.balance(p_uid) b;
  if d > 0 and bal > 0 then
    exp := extract(epoch from app_private.last_activity(p_uid) + make_interval(days => d))::bigint;
  end if;
  ei := app_private.earn_info(p_uid);
  select jsonb_build_object('user', jsonb_build_object('id', u.id, 'name', u.name))
         || to_jsonb(b)
         || jsonb_build_object('earn_percent', (ei ->> 'percent')::int,
                               'earn_base', (ei ->> 'base')::int,
                               'tier', (ei ->> 'tier')::int, 'tier_name', ei -> 'tier_name',
                               'next_tier', ei -> 'next_tier', 'promo', (ei ->> 'promo')::int,
                               'max_spend_percent', app_private.cfg_int('max_spend_percent'),
                               'expire_days', d, 'expires_at', exp)
    into r from app_private.users u, lateral app_private.balance(u.id) b where u.id = p_uid;
  return r;
end $$;

-- ----------------------------------------------------------------- покупка: процент по уровню и акции
create or replace function app_private.do_purchase(p_uid int, p_st jsonb, p_total int, p_spend int,
                                                   p_at timestamptz, p_uuid uuid) returns jsonb
language plpgsql as $$
declare
  maxc int := app_private.cfg_int('max_check'); bal int; max_spend int; paid int; earned int; msg text;
  spend int := coalesce(p_spend, 0); dup record; pct int;
begin
  if exists (select 1 from app_private.users where id = p_uid and deleted_at is not null) then
    perform app_private.fail('PT404', 'Клиент не найден');
  end if;
  if p_total is null or p_total < 1 or p_total > maxc then
    perform app_private.fail('PT400', format('Сумма чека: допустимо от 1 до %s ₽', maxc));
  end if;
  if spend < 0 or spend > p_total then perform app_private.fail('PT400', 'Списание: некорректная сумма'); end if;
  perform pg_advisory_xact_lock(p_uid);
  if p_uuid is not null then
    select * into dup from app_private.events where client_uuid = p_uuid;
    if found then
      return app_private.customer_view(dup.user_id) || jsonb_build_object('paid', dup.amount - dup.spent,
             'earned', dup.earned, 'spent', dup.spent, 'duplicate', true);
    end if;
  elsif exists (select 1 from app_private.events where user_id = p_uid and not cancelled and amount = p_total
                 and created_at > now() - interval '30 seconds') then
    perform app_private.fail('PT409', 'Такая же покупка только что проведена. Если это не ошибка — подождите полминуты.');
  end if;
  perform app_private.sweep_user(p_uid);
  select b.balance into bal from app_private.balance(p_uid) b;
  max_spend := least(bal, p_total * app_private.cfg_int('max_spend_percent') / 100);
  if spend > max_spend then
    perform app_private.fail('PT409', format('Списать можно не больше %s бонусов (лимит %s%% чека и баланс клиента)',
                                 max_spend, app_private.cfg_int('max_spend_percent')));
  end if;
  paid := p_total - spend;
  pct := (app_private.earn_info(p_uid, coalesce(p_at, now())) ->> 'percent')::int;
  earned := paid * pct / 100;
  insert into app_private.events (user_id, location_id, staff_id, amount, spent, earned, client_uuid, created_at)
  values (p_uid, (p_st ->> 'location_id')::int, (p_st ->> 'id')::int, p_total, spend, earned, p_uuid,
          coalesce(p_at, now()));

  select b.balance into bal from app_private.balance(p_uid) b;
  msg := format('💰 Покупка на %s ₽.', p_total)
      || case when earned > 0 then format(' Начислено: +%s %s.', earned, app_private.bonus_word(earned)) else '' end
      || case when spend > 0 then format(' Списано: %s %s.', spend, app_private.bonus_word(spend)) else '' end
      || format(' Баланс: %s %s (1 бонус = 1 ₽).', bal, app_private.bonus_word(bal));
  perform app_private.notify_user(p_uid, msg);
  return app_private.customer_view(p_uid) || jsonb_build_object('paid', paid, 'earned', earned, 'spent', spend);
end $$;

-- ----------------------------------------------------------------- регистрация с согласием
drop function if exists public.auth_register(text, text, text);

create or replace function public.auth_register(p_name text, p_login text, p_password text,
                                                p_consent boolean default false) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  n text := left(trim(coalesce(p_name, '')), 60);
  l text := lower(trim(coalesce(p_login, '')));
  k text := 'reg:' || client_key();
  uid int;
  code text := new_recovery_code();
  gift int := cfg_int('signup_bonus');
begin
  if rate_blocked(k, 10) or rate_blocked('global', 120) then
    return login_error('Слишком много попыток. Подождите 5 минут.', 429);
  end if;
  if n = '' then return login_error('Введите имя', 400); end if;
  if l !~ '^[a-z0-9_.-]{3,30}$' then
    return login_error('Логин: 3–30 символов — латинские буквы, цифры, точка, дефис, подчёркивание', 400);
  end if;
  if length(coalesce(p_password, '')) < 6 then return login_error('Пароль — не короче 6 символов', 400); end if;
  if octet_length(p_password) > 72 then return login_error('Пароль слишком длинный (до 72 байт)', 400); end if;
  if cfg('require_consent') = '1' and not coalesce(p_consent, false) then
    return login_error('Нужно согласие на обработку персональных данных', 400);
  end if;
  begin
    insert into users (tg_id, name, login, password_hash, recovery_hash, consent_at)
    values ('login:' || l, n, l, crypt(p_password, gen_salt('bf')), crypt(recovery_norm(code), gen_salt('bf')),
            case when coalesce(p_consent, false) then now() end)
    returning id into uid;
  exception when unique_violation then
    return login_error('Такой логин уже занят', 409);
  end;
  perform rate_fail(k);
  if gift > 0 then
    insert into adjustments (user_id, delta, reason) values (uid, gift, 'signup');
    perform notify_user(uid, format('🎁 Добро пожаловать! Дарим %s %s за регистрацию.', gift, bonus_word(gift)));
  end if;
  return jsonb_build_object('token', new_session('user', uid, interval '30 days'), 'recovery_code', code);
end $$;

-- ----------------------------------------------------------------- клиент: день рождения, профиль, удаление
create or replace function public.me(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user');
begin
  return customer_view(uid) || jsonb_build_object(
    'push_devices', (select count(*) from push_subs where user_id = uid),
    'has_password', exists (select 1 from users where id = uid and login is not null),
    'has_recovery', exists (select 1 from users where id = uid and recovery_hash is not null),
    'birthday', (select birthday::text from users where id = uid),
    'birthday_bonus', cfg_int('birthday_bonus'),
    'history', (
      select coalesce(jsonb_agg(h order by h.id desc), '[]'::jsonb) from (
        select e.id, e.amount, e.spent, e.earned, extract(epoch from e.created_at)::bigint as created_at,
               l.name as location
          from events e left join locations l on l.id = e.location_id
         where e.user_id = uid and not e.cancelled order by e.id desc limit 15) h));
end $$;

-- Дату рождения можно указать один раз (иначе подарок можно было бы получать каждый месяц).
create or replace function public.set_birthday(p_token text, p_date date) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user');
begin
  if p_date is null or p_date < date '1920-01-01' or p_date > current_date - interval '10 years' then
    perform fail('PT400', 'Проверьте дату рождения');
  end if;
  if exists (select 1 from users where id = uid and birthday is not null) then
    perform fail('PT409', 'Дату рождения уже указали, изменить её нельзя');
  end if;
  update users set birthday = p_date where id = uid;
  perform sweep_user(uid);          -- если день рождения сегодня или на этой неделе — подарок придёт сразу
  return jsonb_build_object('ok', true);
end $$;

-- Удаление аккаунта: личные данные стираются, покупки остаются обезличенными для отчётов.
create or replace function public.delete_my_account(p_token text, p_password text default null) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user'); u record; k text; bal int;
begin
  select * into u from users where id = uid;
  k := 'del:' || uid;
  -- ошибки возвращаем значением, а не исключением: иначе откат транзакции сотрёт счётчик попыток
  if rate_blocked(k, 5) then return login_error('Слишком много попыток. Подождите 5 минут.', 429); end if;
  if u.password_hash is not null
     and (p_password is null or crypt(p_password, u.password_hash) <> u.password_hash) then
    perform rate_fail(k);
    return login_error('Неверный пароль', 403);
  end if;
  select b.balance into bal from balance(uid) b;
  if bal <> 0 then insert into adjustments (user_id, delta, reason) values (uid, -bal, 'delete'); end if;
  update users set name = 'Удалённый клиент', login = null, password_hash = null, recovery_hash = null,
                   username = null, birthday = null, tg_id = 'deleted:' || uid, deleted_at = now()
   where id = uid;
  delete from push_subs where user_id = uid;
  delete from messages where user_id = uid;
  delete from sessions where role = 'user' and subject = uid;
  return jsonb_build_object('ok', true);
end $$;

-- рассылки не получают удалённые клиенты
create or replace function app_private.audience_ids(p_audience text) returns setof int
language sql stable as $$
  select u.id from app_private.users u
   where u.deleted_at is null and case p_audience
           when 'all' then true
           when 'inactive' then app_private.last_activity(u.id) < now() - interval '30 days'
           when 'with_balance' then (select b.balance from app_private.balance(u.id) b) > 0
           else false end $$;

-- ----------------------------------------------------------------- администратор
create or replace function public.admin_loyalty(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  return jsonb_build_object(
    'tier1_from', cfg_int('tier1_from'), 'tier1_percent', cfg_int('tier1_percent'),
    'tier2_from', cfg_int('tier2_from'), 'tier2_percent', cfg_int('tier2_percent'),
    'birthday_bonus', cfg_int('birthday_bonus'), 'promo_days', cfg('promo_days'), 'promo_mult', cfg_int('promo_mult'),
    'weak_admin', crypt('1234', cfg('admin_hash')) = cfg('admin_hash'),
    'weak_pin', exists (select 1 from staff where active and pin_hash = pin_hash('1234')));
end $$;

create or replace function public.admin_loyalty_save(p_token text, p_cfg jsonb) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  k text; v text;
  nums text[] := array['tier1_from', 'tier1_percent', 'tier2_from', 'tier2_percent', 'birthday_bonus', 'promo_mult'];
  lim int[] := array[10000000, 100, 10000000, 100, 10000, 5];
  i int; days text;
begin
  perform auth(p_token, 'admin');
  for i in 1 .. array_length(nums, 1) loop
    k := nums[i];
    if p_cfg ? k then
      v := p_cfg ->> k;
      if v is null or v !~ '^\d{1,8}$' or v::int > lim[i] or (k = 'promo_mult' and v::int < 1) then
        perform fail('PT400', 'Некорректное значение: ' || k);
      end if;
    end if;
  end loop;
  if p_cfg ? 'promo_days' then
    days := coalesce(p_cfg ->> 'promo_days', '');
    if days !~ '^[1-7]{0,7}$' then perform fail('PT400', 'Дни акции: цифры от 1 (пн) до 7 (вс)'); end if;
  end if;
  if coalesce((p_cfg ->> 'tier1_from')::int, cfg_int('tier1_from')) > 0
     and coalesce((p_cfg ->> 'tier2_from')::int, cfg_int('tier2_from')) > 0
     and coalesce((p_cfg ->> 'tier2_from')::int, cfg_int('tier2_from')) <= coalesce((p_cfg ->> 'tier1_from')::int, cfg_int('tier1_from')) then
    perform fail('PT400', 'Порог «Золота» должен быть выше порога «Серебра»');
  end if;
  for i in 1 .. array_length(nums, 1) loop
    if p_cfg ? nums[i] then update config set value = (p_cfg ->> nums[i])::int::text where key = nums[i]; end if;
  end loop;
  if p_cfg ? 'promo_days' then update config set value = days where key = 'promo_days'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_report_staff(p_token text, p_from date default null, p_to date default null)
returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  tz text := cfg('timezone'); today date := (now() at time zone tz)::date;
  f date := coalesce(p_from, today - 29); t date := coalesce(p_to, today);
begin
  perform auth(p_token, 'admin');
  if t < f or t - f > 366 then perform fail('PT400', 'Некорректный период (не больше 366 дней)'); end if;
  return jsonb_build_object('items', (
    select coalesce(jsonb_agg(x order by x.revenue desc), '[]'::jsonb) from (
      select coalesce(s.name, '—') as name, coalesce(l.name, '—') as location, count(*) as purchases,
             sum(e.amount) as revenue, sum(e.spent) as spent,
             count(*) filter (where e.cancelled) as cancelled
        from events e left join staff s on s.id = e.staff_id left join locations l on l.id = e.location_id
       where (e.created_at at time zone tz)::date between f and t
       group by s.id, s.name, l.name) x));
end $$;

-- ----------------------------------------------------------------- права и учёт
insert into app_private.schema_migrations (version, title)
values ('0004', 'Уровни, день рождения, акции по дням, согласие на данные, удаление аккаунта')
on conflict do nothing;

revoke all on all tables in schema app_private from public, anon, authenticated;
revoke all on all sequences in schema app_private from public, anon, authenticated;
revoke all on all functions in schema app_private from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
