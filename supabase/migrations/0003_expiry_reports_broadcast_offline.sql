-- 0003 — срок жизни бонусов и бонус за регистрацию, отчёты, рассылки, входящие сообщения клиента,
-- пакетная отправка покупок с кассы (работа без интернета).

-- ----------------------------------------------------------------- настройки и таблицы
insert into app_private.config (key, value) values
  ('expire_days', '0'),        -- 0 = бонусы не сгорают; иначе столько дней без покупок — и баланс сгорает
  ('signup_bonus', '0')        -- сколько бонусов дарить при регистрации (0 = не дарить)
on conflict (key) do nothing;

-- Корректировки баланса: бонус за регистрацию (+) и сгорание (−).
create table if not exists app_private.adjustments (
  id bigserial primary key,
  user_id int not null references app_private.users (id),
  delta int not null check (delta <> 0),
  reason text not null,
  created_at timestamptz not null default now());
create index if not exists adjustments_user on app_private.adjustments (user_id);

-- Входящие клиента: всё, что ему отправила система или владелец. Из этой таблицы читает и приложение.
create table if not exists app_private.messages (
  id bigserial primary key,
  user_id int not null references app_private.users (id),
  title text not null,
  body text not null,
  kind text not null default 'info',
  created_at timestamptz not null default now());
create index if not exists messages_user on app_private.messages (user_id, id);

create table if not exists app_private.broadcasts (
  id serial primary key,
  title text not null, body text not null, audience text not null,
  sent int not null default 0, created_at timestamptz not null default now());

-- Идентификатор покупки, созданный на кассе: повторная отправка не создаёт дубль.
alter table app_private.events add column if not exists client_uuid uuid;
create unique index if not exists events_client_uuid on app_private.events (client_uuid) where client_uuid is not null;

alter table app_private.adjustments enable row level security;
alter table app_private.messages enable row level security;
alter table app_private.broadcasts enable row level security;

-- ----------------------------------------------------------------- баланс, сгорание
create or replace function app_private.balance(p_uid int)
returns table (balance int, earned_total int, spent_total int, turnover int, purchases int)
language sql stable as $$
  select (coalesce(sum(earned), 0) - coalesce(sum(spent), 0)
          + (select coalesce(sum(delta), 0) from app_private.adjustments where user_id = p_uid))::int,
         coalesce(sum(earned), 0)::int, coalesce(sum(spent), 0)::int,
         coalesce(sum(amount), 0)::int, count(*)::int
    from app_private.events where user_id = p_uid and not cancelled $$;

create or replace function app_private.last_activity(p_uid int) returns timestamptz
language sql stable as $$
  select greatest(u.created_at, coalesce((select max(e.created_at) from app_private.events e
                                           where e.user_id = u.id and not e.cancelled), u.created_at))
    from app_private.users u where u.id = p_uid $$;

-- Сгорание: если срок включён и клиент не покупал дольше срока — баланс обнуляется (запись в adjustments).
create or replace function app_private.sweep_user(p_uid int) returns void
language plpgsql as $$
declare d int := app_private.cfg_int('expire_days'); bal int;
begin
  if d <= 0 then return; end if;
  perform pg_advisory_xact_lock(p_uid);
  select b.balance into bal from app_private.balance(p_uid) b;
  if bal > 0 and app_private.last_activity(p_uid) < now() - make_interval(days => d) then
    insert into app_private.adjustments (user_id, delta, reason) values (p_uid, -bal, 'expire');
    perform app_private.notify_user(p_uid,
      format('⌛ %s %s сгорели: больше %s дней не было покупок.', bal, app_private.bonus_word(bal), d));
  end if;
end $$;

create or replace function app_private.customer_view(p_uid int) returns jsonb
language plpgsql as $$
declare r jsonb; d int := app_private.cfg_int('expire_days'); bal int; exp bigint;
begin
  perform app_private.sweep_user(p_uid);
  select b.balance into bal from app_private.balance(p_uid) b;
  if d > 0 and bal > 0 then
    exp := extract(epoch from app_private.last_activity(p_uid) + make_interval(days => d))::bigint;
  end if;
  select jsonb_build_object('user', jsonb_build_object('id', u.id, 'name', u.name))
         || to_jsonb(b)
         || jsonb_build_object('earn_percent', app_private.cfg_int('earn_percent'),
                               'max_spend_percent', app_private.cfg_int('max_spend_percent'),
                               'expire_days', d, 'expires_at', exp)
    into r from app_private.users u, lateral app_private.balance(u.id) b where u.id = p_uid;
  return r;
end $$;

-- ----------------------------------------------------------------- сообщения клиенту
create or replace function app_private.tg_send(p_uid int, p_text text) returns void
language plpgsql as $$
declare u record; tok text := app_private.cfg('bot_token');
begin
  select name, tg_id into u from app_private.users where id = p_uid;
  if not found then return; end if;
  if coalesce(tok, '') = '' or u.tg_id not like 'tg:%' then
    raise notice '[уведомление → %] %', u.name, p_text;
    return;
  end if;
  begin
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
      body := jsonb_build_object('chat_id', substr(u.tg_id, 4), 'text', p_text));
  exception when others then
    raise notice 'Telegram не принял сообщение: %', sqlerrm;
  end;
end $$;

-- Одно сообщение: во «входящие», push на устройства и в Telegram.
create or replace function app_private.send_message(p_uid int, p_title text, p_body text, p_kind text) returns void
language plpgsql as $$
begin
  insert into app_private.messages (user_id, title, body, kind) values (p_uid, p_title, p_body, p_kind);
  perform app_private.push_user(p_uid, p_title, p_body);
  perform app_private.tg_send(p_uid, case when p_title = app_private.cfg('shop_name') then p_body
                                          else p_title || E'\n' || p_body end);
end $$;

create or replace function app_private.notify_user(p_uid int, p_text text) returns void
language plpgsql as $$
begin
  if app_private.cfg_int('notify') = 0 then return; end if;
  if not exists (select 1 from app_private.users where id = p_uid) then return; end if;
  perform app_private.send_message(p_uid, app_private.cfg('shop_name'), p_text, 'info');
end $$;

create or replace function public.my_messages(p_token text, p_after bigint default null) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user'); last bigint;
begin
  select coalesce(max(id), 0) into last from messages where user_id = uid;
  if p_after is null then return jsonb_build_object('items', '[]'::jsonb, 'last_id', last); end if;
  return jsonb_build_object('last_id', last, 'items', (
    select coalesce(jsonb_agg(x order by x.id), '[]'::jsonb) from (
      select id, title, body, kind, extract(epoch from created_at)::bigint as created_at
        from messages where user_id = uid and id > p_after order by id limit 20) x));
end $$;

create or replace function public.my_inbox(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user');
begin
  return jsonb_build_object('items', (
    select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
      select id, title, body, kind, extract(epoch from created_at)::bigint as created_at
        from messages where user_id = uid order by id desc limit 15) x));
end $$;

-- ----------------------------------------------------------------- регистрация с бонусом
create or replace function public.auth_register(p_name text, p_login text, p_password text) returns jsonb
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
  begin
    insert into users (tg_id, name, login, password_hash, recovery_hash)
    values ('login:' || l, n, l, crypt(p_password, gen_salt('bf')), crypt(recovery_norm(code), gen_salt('bf')))
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

-- ----------------------------------------------------------------- покупка (онлайн и из очереди кассы)
create or replace function app_private.qr_slot_ok_at(p_slot bigint, p_at bigint) returns boolean
language sql immutable as $$ select p_slot <= floor(p_at / 10)::bigint + 1 and p_at < (p_slot + 1) * 10 + 75 $$;

create or replace function app_private.resolve_payload_at(p_payload text, p_at bigint) returns int
language plpgsql as $$
declare m text[]; uid int; w bigint;
begin
  m := regexp_match(trim(coalesce(p_payload, '')), '^BC1\.(\d+)\.(\d+)\.([0-9a-f]{10})$');
  if m is null then perform app_private.fail('PT400', 'Это не QR-код карты лояльности'); end if;
  uid := m[1]::int; w := m[2]::bigint;
  if app_private.qr_sig(uid, w) <> m[3] then perform app_private.fail('PT400', 'QR-код недействителен'); end if;
  if not app_private.qr_slot_ok_at(w, p_at) then perform app_private.fail('PT400', 'QR-код был устаревшим при сканировании'); end if;
  if not exists (select 1 from app_private.users where id = uid) then perform app_private.fail('PT404', 'Клиент не найден'); end if;
  return uid;
end $$;

create or replace function app_private.do_purchase(p_uid int, p_st jsonb, p_total int, p_spend int,
                                                   p_at timestamptz, p_uuid uuid) returns jsonb
language plpgsql as $$
declare
  maxc int := app_private.cfg_int('max_check'); bal int; max_spend int; paid int; earned int; msg text;
  spend int := coalesce(p_spend, 0); dup record;
begin
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
  earned := paid * app_private.cfg_int('earn_percent') / 100;
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

create or replace function public.staff_purchase(p_token text, p_amount int, p_spend int default 0,
                                                 p_payload text default null, p_card text default null,
                                                 p_code text default null) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare st jsonb := staff_info(auth(p_token, 'staff'));
begin
  return do_purchase(resolve_user(p_payload, p_card, p_code), st, p_amount, p_spend, null, null);
end $$;

-- Очередь кассы без интернета: покупки по QR, проведённые при отсутствии связи (только начисление).
-- QR проверяется по времени сканирования, а не отправки. У каждой покупки свой id — дублей не будет.
create or replace function public.staff_purchase_batch(p_token text, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  st jsonb := staff_info(auth(p_token, 'staff'));
  it jsonb; res jsonb := '[]'::jsonb; r jsonb; uid int; at_s bigint; id_txt text;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 100 then
    perform fail('PT400', 'Некорректная очередь (до 100 покупок за раз)');
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    id_txt := it ->> 'id';
    begin
      at_s := (it ->> 'at')::bigint;
      if at_s > extract(epoch from now()) + 120 or at_s < extract(epoch from now()) - 3 * 86400 then
        perform fail('PT400', 'Время покупки вне допустимого диапазона (до 3 суток назад)');
      end if;
      uid := resolve_payload_at(it ->> 'payload', at_s);
      r := do_purchase(uid, st, (it ->> 'amount')::int, 0, to_timestamp(at_s), id_txt::uuid);
      res := res || jsonb_build_array(jsonb_build_object('id', id_txt, 'ok', true,
               'name', r #>> '{user,name}', 'earned', r -> 'earned',
               'duplicate', coalesce(r -> 'duplicate', 'false'::jsonb)));
    exception when others then
      res := res || jsonb_build_array(jsonb_build_object('id', id_txt, 'ok', false, 'error', sqlerrm));
    end;
  end loop;
  return jsonb_build_object('results', res);
end $$;

-- ----------------------------------------------------------------- администратор: настройки, статистика, клиенты
drop function if exists public.admin_settings_save(text, int, int, int, int);

create or replace function public.admin_settings(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  return jsonb_build_object('earn_percent', cfg_int('earn_percent'), 'max_spend_percent', cfg_int('max_spend_percent'),
                            'max_check', cfg_int('max_check'), 'notify', cfg_int('notify'),
                            'expire_days', cfg_int('expire_days'), 'signup_bonus', cfg_int('signup_bonus'));
end $$;

create or replace function public.admin_settings_save(p_token text, p_earn_percent int, p_max_spend_percent int,
                                                      p_max_check int, p_notify int,
                                                      p_expire_days int default null, p_signup_bonus int default null)
returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  if p_earn_percent is null or p_earn_percent not between 0 and 100
     or p_max_spend_percent is null or p_max_spend_percent not between 0 and 100
     or p_max_check is null or p_max_check not between 100 and 1000000
     or p_notify is null or p_notify not between 0 and 1
     or p_expire_days not between 0 and 3650 or p_signup_bonus not between 0 and 10000 then
    perform fail('PT400', 'Некорректное значение');
  end if;
  update config set value = p_earn_percent::text where key = 'earn_percent';
  update config set value = p_max_spend_percent::text where key = 'max_spend_percent';
  update config set value = p_max_check::text where key = 'max_check';
  update config set value = p_notify::text where key = 'notify';
  if p_expire_days is not null then update config set value = p_expire_days::text where key = 'expire_days'; end if;
  if p_signup_bonus is not null then update config set value = p_signup_bonus::text where key = 'signup_bonus'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_stats(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare tz text := cfg('timezone');
begin
  perform auth(p_token, 'admin');
  return jsonb_build_object(
    'totals', (select jsonb_build_object(
        'purchases', count(*), 'revenue', coalesce(sum(amount), 0),
        'earned', coalesce(sum(earned), 0), 'spent', coalesce(sum(spent), 0),
        'outstanding', coalesce(sum(earned) - sum(spent), 0) + (select coalesce(sum(delta), 0) from adjustments),
        'purchases_today', count(*) filter (where (created_at at time zone tz)::date = (now() at time zone tz)::date),
        'revenue_today', coalesce(sum(amount) filter (where (created_at at time zone tz)::date = (now() at time zone tz)::date), 0),
        'users', (select count(*) from users))
       from events where not cancelled),
    'locations', (select coalesce(jsonb_agg(x order by x.id), '[]'::jsonb) from (
        select l.id, l.name, count(e.id) as purchases, coalesce(sum(e.amount), 0) as revenue,
               coalesce(sum(e.earned), 0) as earned, coalesce(sum(e.spent), 0) as spent
          from locations l left join events e on e.location_id = l.id and not e.cancelled
         where l.active group by l.id) x),
    'days', (select coalesce(jsonb_agg(x order by x.day desc), '[]'::jsonb) from (
        select (created_at at time zone tz)::date::text as day, count(*) as purchases,
               sum(amount) as revenue, sum(earned) as earned, sum(spent) as spent
          from events where not cancelled and created_at > now() - interval '7 days' group by 1) x),
    'recent', (select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
        select e.id, e.amount, e.spent, e.earned, e.cancelled, extract(epoch from e.created_at)::bigint as created_at,
               u.name as client, l.name as location, s.name as staff
          from events e join users u on u.id = e.user_id
          left join locations l on l.id = e.location_id left join staff s on s.id = e.staff_id
         order by e.id desc limit 20) x));
end $$;

create or replace function public.admin_clients(p_token text, p_q text default '') returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare q text := lower(ltrim(trim(coalesce(p_q, '')), '@')); r jsonb;
begin
  perform auth(p_token, 'admin');
  with c as (
    select u.id, u.name, u.username, u.login, extract(epoch from u.created_at)::bigint as created_at,
           count(e.id) as purchases, coalesce(sum(e.amount), 0) as turnover,
           coalesce(sum(e.earned), 0) - coalesce(sum(e.spent), 0)
             + (select coalesce(sum(a.delta), 0) from adjustments a where a.user_id = u.id) as balance,
           extract(epoch from max(e.created_at))::bigint as last_visit,
           coalesce(max(e.created_at), u.created_at) as sortkey
      from users u left join events e on e.user_id = u.id and not e.cancelled group by u.id),
  f as (select * from c where q = '' or position(q in lower(name)) > 0
                           or position(q in lower(coalesce(username, ''))) > 0
                           or position(q in lower(coalesce(login, ''))) > 0 or q = id::text)
  select jsonb_build_object('total', (select count(*) from f), 'items', (
           select coalesce(jsonb_agg(to_jsonb(t) - 'sortkey' order by t.sortkey desc), '[]'::jsonb)
             from (select * from f order by sortkey desc limit 200) t))
    into r;
  return r;
end $$;

-- ----------------------------------------------------------------- отчёты
create or replace function public.admin_report(p_token text, p_from date default null, p_to date default null)
returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  tz text := cfg('timezone'); today date := (now() at time zone tz)::date;
  f date := coalesce(p_from, today - 29); t date := coalesce(p_to, today); r jsonb;
begin
  perform auth(p_token, 'admin');
  if t < f or t - f > 366 then perform fail('PT400', 'Некорректный период (не больше 366 дней)'); end if;
  with ev as (select e.*, (e.created_at at time zone tz)::date as d from events e where not e.cancelled),
       per as (select * from ev where d between f and t),
       firsts as (select user_id, min(d) as fd from ev group by user_id)
  select jsonb_build_object(
    'from', f, 'to', t,
    'totals', (select jsonb_build_object('purchases', count(*), 'revenue', coalesce(sum(amount), 0),
                 'avg_check', coalesce(round(avg(amount)), 0), 'earned', coalesce(sum(earned), 0),
                 'spent', coalesce(sum(spent), 0), 'clients', count(distinct user_id)) from per),
    'new_clients', (select count(*) from firsts where fd between f and t),
    'returning_clients', (select count(distinct p.user_id) from per p join firsts x using (user_id) where x.fd < f),
    'repeat_clients', (select count(*) from (select user_id from per group by user_id having count(*) > 1) z),
    'registered', (select count(*) from users where (created_at at time zone tz)::date between f and t),
    'days', (select coalesce(jsonb_agg(x order by x.day), '[]'::jsonb) from (
        select d::text as day, count(*) as purchases, sum(amount) as revenue, sum(earned) as earned, sum(spent) as spent
          from per group by d) x),
    'locations', (select coalesce(jsonb_agg(x order by x.revenue desc), '[]'::jsonb) from (
        select coalesce(l.name, '—') as name, count(*) as purchases, sum(p.amount) as revenue
          from per p left join locations l on l.id = p.location_id group by l.name) x),
    'hours', (select coalesce(jsonb_agg(x order by x.hour), '[]'::jsonb) from (
        select extract(hour from created_at at time zone tz)::int as hour, count(*) as purchases
          from per group by 1) x),
    'top', (select coalesce(jsonb_agg(x order by x.revenue desc), '[]'::jsonb) from (
        select u.id, u.name, count(*) as purchases, sum(p.amount) as revenue
          from per p join users u on u.id = p.user_id group by u.id order by sum(p.amount) desc limit 10) x))
    into r;
  return r;
end $$;

create or replace function app_private.csv_q(p_v text) returns text
language sql immutable as $$
  select '"' || replace(case when coalesce(p_v, '') ~ '^[=+@-]' then '''' || p_v else coalesce(p_v, '') end, '"', '""') || '"' $$;

create or replace function public.admin_export(p_token text, p_from date default null, p_to date default null)
returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  tz text := cfg('timezone'); today date := (now() at time zone tz)::date;
  f date := coalesce(p_from, today - 29); t date := coalesce(p_to, today); body text; n int;
begin
  perform auth(p_token, 'admin');
  if t < f or t - f > 366 then perform fail('PT400', 'Некорректный период (не больше 366 дней)'); end if;
  select count(*), string_agg(
           e.id || ',' || csv_q(to_char(e.created_at at time zone tz, 'YYYY-MM-DD HH24:MI')) || ','
           || csv_q(l.name) || ',' || csv_q(s.name) || ',' || u.id || ',' || csv_q(u.name) || ','
           || e.amount || ',' || e.spent || ',' || e.earned || ','
           || case when e.cancelled then 'отменена' else 'проведена' end,
           E'\n' order by e.id)
    into n, body
    from events e join users u on u.id = e.user_id
    left join locations l on l.id = e.location_id left join staff s on s.id = e.staff_id
   where (e.created_at at time zone tz)::date between f and t;
  return jsonb_build_object('rows', n,
    'csv', 'id,время,точка,сотрудник,клиент №,клиент,сумма чека,списано бонусов,начислено бонусов,статус'
           || E'\n' || coalesce(body, ''));
end $$;

-- ----------------------------------------------------------------- рассылки
create or replace function app_private.audience_ids(p_audience text) returns setof int
language sql stable as $$
  select u.id from app_private.users u
   where case p_audience
           when 'all' then true
           when 'inactive' then app_private.last_activity(u.id) < now() - interval '30 days'
           when 'with_balance' then (select b.balance from app_private.balance(u.id) b) > 0
           else false end $$;

create or replace function public.admin_broadcasts(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  return jsonb_build_object(
    'counts', jsonb_build_object(
      'all', (select count(*) from audience_ids('all')),
      'inactive', (select count(*) from audience_ids('inactive')),
      'with_balance', (select count(*) from audience_ids('with_balance')),
      'push_clients', (select count(distinct user_id) from push_subs)),
    'items', (select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
        select id, title, body, audience, sent, extract(epoch from created_at)::bigint as created_at
          from broadcasts order by id desc limit 10) x));
end $$;

create or replace function public.admin_broadcast(p_token text, p_title text, p_body text, p_audience text)
returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare ttl text := left(trim(coalesce(p_title, '')), 60); b text := left(trim(coalesce(p_body, '')), 300);
        n int := 0; uid int;
begin
  perform auth(p_token, 'admin');
  if ttl = '' or b = '' then perform fail('PT400', 'Введите заголовок и текст'); end if;
  if p_audience not in ('all', 'inactive', 'with_balance') then perform fail('PT400', 'Неизвестная аудитория'); end if;
  if exists (select 1 from broadcasts where created_at > now() - interval '30 seconds') then
    perform fail('PT429', 'Рассылка только что отправлена — подождите полминуты');
  end if;
  for uid in select * from audience_ids(p_audience) loop
    perform send_message(uid, ttl, b, 'promo');
    n := n + 1;
  end loop;
  insert into broadcasts (title, body, audience, sent) values (ttl, b, p_audience, n);
  delete from messages where created_at < now() - interval '90 days';
  return jsonb_build_object('ok', true, 'sent', n);
end $$;

-- ----------------------------------------------------------------- права и учёт
insert into app_private.schema_migrations (version, title)
values ('0003', 'Сгорание бонусов, бонус за регистрацию, отчёты, рассылки, очередь кассы')
on conflict do nothing;

revoke all on all tables in schema app_private from public, anon, authenticated;
revoke all on all sequences in schema app_private from public, anon, authenticated;
revoke all on all functions in schema app_private from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
