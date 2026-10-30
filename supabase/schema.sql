-- ============================================================================
-- Бонусная система кофейни — полная схема для Supabase (Postgres).
-- ФАЙЛ СОБРАН АВТОМАТИЧЕСКИ из supabase/migrations/*.sql — не правьте его руками:
--     python supabase/build_schema.py
--
-- Как применить: Supabase → SQL Editor → New query → вставить весь файл → Run.
-- Можно запускать повторно: функции пересоздаются, данные не теряются.
-- ============================================================================

-- ################ миграция 0001_baseline.sql ################

-- ============================================================================
-- Бонусная система кофейни — серверная часть для Supabase (Postgres).
-- Заменяет server.py: вся логика (QR, бонусы, лимит 20%, отмена, роли) живёт здесь.
--
-- Как применить: Supabase → SQL Editor → New query → вставить весь файл → Run.
-- Файл можно запускать повторно: функции пересоздаются, данные не теряются.
--
-- Безопасность: таблицы лежат в схеме app_private, которую Supabase не публикует
-- и к которой у ролей anon/authenticated нет доступа. Снаружи вызываются только
-- функции схемы public, и каждая проверяет сессионный токен своей роли.
-- ============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
do $$ begin
  create extension if not exists pg_net;      -- нужен для уведомлений в Telegram
exception when others then
  raise notice 'pg_net не включён — уведомления в Telegram работать не будут: %', sqlerrm;
end $$;

create schema if not exists app_private;

-- ----------------------------------------------------------------- таблицы

create table if not exists app_private.config (key text primary key, value text not null);

create table if not exists app_private.locations (
  id serial primary key, name text not null, active boolean not null default true);

create table if not exists app_private.staff (
  id serial primary key, name text not null,
  location_id int not null references app_private.locations (id),
  pin_hash text not null unique, active boolean not null default true);

create table if not exists app_private.users (
  id serial primary key, tg_id text not null unique, name text not null,
  username text, created_at timestamptz not null default now());

-- Регистрация клиента по логину и паролю (имя + логин + пароль). Вход через Telegram — по желанию.
alter table app_private.users add column if not exists login text;
alter table app_private.users add column if not exists password_hash text;
create unique index if not exists users_login_key on app_private.users (lower(login)) where login is not null;

-- amount — сумма чека (₽), spent — списано бонусов, earned — начислено бонусов
create table if not exists app_private.events (
  id bigserial primary key,
  user_id int not null references app_private.users (id),
  location_id int references app_private.locations (id),
  staff_id int references app_private.staff (id),
  amount int not null check (amount > 0),
  spent int not null default 0 check (spent >= 0),
  earned int not null default 0 check (earned >= 0),
  cancelled boolean not null default false,
  created_at timestamptz not null default now());
create index if not exists events_user on app_private.events (user_id);

create table if not exists app_private.sessions (
  token_hash text primary key,
  role text not null check (role in ('user', 'staff', 'admin')),
  subject int not null default 0,
  expires_at timestamptz not null);

create table if not exists app_private.attempts (
  key text primary key, n int not null, since timestamptz not null);

alter table app_private.config enable row level security;
alter table app_private.locations enable row level security;
alter table app_private.staff enable row level security;
alter table app_private.users enable row level security;
alter table app_private.events enable row level security;
alter table app_private.sessions enable row level security;
alter table app_private.attempts enable row level security;

-- ----------------------------------------------------------------- начальные данные
-- ВНИМАНИЕ: на время тестирования пароль админа и PIN бариста — 1234. Замените перед запуском
-- для настоящих клиентов (см. README, раздел «Пароли»).

insert into app_private.config (key, value) values
  ('secret', encode(extensions.gen_random_bytes(32), 'hex')),
  ('shop_name', 'Кофейня'),
  ('bot_token', ''),
  ('bot_username', ''),
  ('timezone', 'Europe/Moscow'),
  ('earn_percent', '5'),
  ('max_spend_percent', '20'),
  ('max_check', '20000'),
  ('notify', '1'),
  ('dev_login', '0')            -- 1 = разрешить вход по одному имени без пароля (только для проверок)
on conflict (key) do nothing;

insert into app_private.config (key, value)
values ('admin_hash', extensions.crypt('1234', extensions.gen_salt('bf')))
on conflict (key) do nothing;

do $$
declare loc int;
begin
  if not exists (select 1 from app_private.locations) then
    insert into app_private.locations (name) values ('Основная точка') returning id into loc;
    insert into app_private.staff (name, location_id, pin_hash)
    values ('Бариста', loc, encode(extensions.hmac('pin:1234',
            (select value from app_private.config where key = 'secret'), 'sha256'), 'hex'));
  end if;
end $$;

-- ----------------------------------------------------------------- вспомогательные функции

create or replace function app_private.cfg(p_key text) returns text
language sql stable as $$ select value from app_private.config where key = p_key $$;

create or replace function app_private.cfg_int(p_key text) returns int
language sql stable as $$ select value::int from app_private.config where key = p_key $$;

create or replace function app_private.fail(p_code text, p_msg text) returns void
language plpgsql as $$ begin raise exception '%', p_msg using errcode = p_code; end $$;

create or replace function app_private.pin_hash(p_pin text) returns text
language sql stable as $$
  select encode(extensions.hmac('pin:' || coalesce(p_pin, ''), app_private.cfg('secret'), 'sha256'), 'hex') $$;

create or replace function app_private.new_session(p_role text, p_subject int, p_ttl interval)
returns text language plpgsql as $$
declare t text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from app_private.sessions where expires_at < now();
  insert into app_private.sessions values
    (encode(extensions.digest(t, 'sha256'), 'hex'), p_role, p_subject, now() + p_ttl);
  return t;
end $$;

create or replace function app_private.auth(p_token text, p_role text) returns int
language plpgsql as $$
declare s int;
begin
  select subject into s from app_private.sessions
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and role = p_role and expires_at > now();
  if not found then
    perform app_private.fail('PT401', 'Нужен вход');
  end if;
  return s;
end $$;

-- Ограничение попыток входа. Ошибки при входе возвращаются обычным ответом ({"__error":..}),
-- а не исключением: иначе откатился бы и счётчик неудачных попыток.
create or replace function app_private.client_key() returns text
language plpgsql stable as $$
begin
  return coalesce(nullif(trim(split_part(
    (nullif(current_setting('request.headers', true), '')::json) ->> 'x-forwarded-for', ',', 1)), ''), 'global');
exception when others then
  return 'global';
end $$;

create or replace function app_private.rate_blocked(p_key text, p_limit int) returns boolean
language sql stable as $$
  select coalesce((select n >= p_limit and since > now() - interval '5 minutes'
                     from app_private.attempts where key = p_key), false) $$;

create or replace function app_private.rate_fail(p_key text) returns void
language sql as $$
  insert into app_private.attempts (key, n, since) values (p_key, 1, now())
  on conflict (key) do update set
    n = case when app_private.attempts.since < now() - interval '5 minutes' then 1 else app_private.attempts.n + 1 end,
    since = case when app_private.attempts.since < now() - interval '5 minutes' then now() else app_private.attempts.since end $$;

create or replace function app_private.login_error(p_msg text, p_status int) returns jsonb
language sql immutable as $$ select jsonb_build_object('__error', p_msg, '__status', p_status) $$;

-- QR-код клиента: выдаётся на 60 секунд (столько клиент его и видит), принимается ещё 15 секунд —
-- запас на связь и очередь у кассы. Привязка идёт к 10-секундным «слотам» времени выдачи.
create or replace function app_private.qr_window() returns bigint
language sql stable as $$ select floor(extract(epoch from now()) / 10)::bigint $$;

create or replace function app_private.qr_slot_ok(p_slot bigint) returns boolean
language sql stable as $$
  select p_slot <= app_private.qr_window() + 1
     and extract(epoch from now()) < (p_slot + 1) * 10 + 75 $$;

create or replace function app_private.qr_sig(p_uid int, p_w bigint) returns text
language sql stable as $$
  select left(encode(extensions.hmac('qr:' || p_uid || ':' || p_w, app_private.cfg('secret'), 'sha256'), 'hex'), 10) $$;

create or replace function app_private.qr_code(p_uid int, p_w bigint) returns text
language sql stable as $$
  select lpad((('x' || encode(substring(extensions.hmac('code:' || p_uid || ':' || p_w,
         app_private.cfg('secret'), 'sha256') from 1 for 4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0') $$;

create or replace function app_private.resolve_user(p_payload text, p_card text, p_code text) returns int
language plpgsql as $$
declare
  now_w bigint := app_private.qr_window();
  uid int; w bigint; m text[]; ok boolean := false; i int;
begin
  if coalesce(trim(p_payload), '') <> '' then
    m := regexp_match(trim(p_payload), '^BC1\.(\d+)\.(\d+)\.([0-9a-f]{10})$');
    if m is null then perform app_private.fail('PT400', 'Это не QR-код карты лояльности'); end if;
    uid := m[1]::int; w := m[2]::bigint;
    if app_private.qr_sig(uid, w) <> m[3] then perform app_private.fail('PT400', 'QR-код недействителен'); end if;
    if not app_private.qr_slot_ok(w) then
      perform app_private.fail('PT400', 'QR-код устарел — пусть клиент обновит экран');
    end if;
  else
    if coalesce(trim(p_card), '') !~ '^\d{1,9}$' then
      perform app_private.fail('PT400', 'Введите номер карты и код');
    end if;
    uid := trim(p_card)::int;
    for i in 0..9 loop
      if app_private.qr_slot_ok(now_w - i)
         and app_private.qr_code(uid, now_w - i) = replace(coalesce(p_code, ''), ' ', '') then ok := true; end if;
    end loop;
    if not ok then perform app_private.fail('PT400', 'Неверный или устаревший код'); end if;
  end if;
  if not exists (select 1 from app_private.users where id = uid) then
    perform app_private.fail('PT404', 'Клиент не найден');
  end if;
  return uid;
end $$;

create or replace function app_private.balance(p_uid int)
returns table (balance int, earned_total int, spent_total int, turnover int, purchases int)
language sql stable as $$
  select (coalesce(sum(earned), 0) - coalesce(sum(spent), 0))::int, coalesce(sum(earned), 0)::int,
         coalesce(sum(spent), 0)::int, coalesce(sum(amount), 0)::int, count(*)::int
    from app_private.events where user_id = p_uid and not cancelled $$;

create or replace function app_private.customer_view(p_uid int) returns jsonb
language sql stable as $$
  select jsonb_build_object('user', jsonb_build_object('id', u.id, 'name', u.name))
         || to_jsonb(b)
         || jsonb_build_object('earn_percent', app_private.cfg_int('earn_percent'),
                               'max_spend_percent', app_private.cfg_int('max_spend_percent'))
    from app_private.users u, lateral app_private.balance(u.id) b where u.id = p_uid $$;

create or replace function app_private.bonus_word(p_n int) returns text
language sql immutable as $$
  select case when abs(p_n) % 10 = 1 and abs(p_n) % 100 <> 11 then 'бонус'
              when abs(p_n) % 10 between 2 and 4 and abs(p_n) % 100 not between 12 and 14 then 'бонуса'
              else 'бонусов' end $$;

-- Сообщение клиенту в Telegram. Ошибки доставки никогда не ломают покупку.
create or replace function app_private.notify_user(p_uid int, p_text text) returns void
language plpgsql as $$
declare u record; tok text := app_private.cfg('bot_token');
begin
  if app_private.cfg_int('notify') = 0 then return; end if;
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

create or replace function app_private.upsert_user(p_tg text, p_name text, p_username text) returns int
language sql as $$
  insert into app_private.users (tg_id, name, username) values (p_tg, p_name, p_username)
  on conflict (tg_id) do update set name = excluded.name, username = excluded.username
  returning id $$;

create or replace function app_private.cancel_event(p_id bigint, p_location int, p_max_age int)
returns void language plpgsql as $$
declare e app_private.events; b record;
begin
  select * into e from app_private.events where id = p_id for update;
  if not found or e.cancelled then perform app_private.fail('PT404', 'Операция не найдена'); end if;
  if p_location is not null and e.location_id is distinct from p_location then
    perform app_private.fail('PT403', 'Это операция другой точки');
  end if;
  if p_max_age is not null and extract(epoch from now() - e.created_at) > p_max_age then
    perform app_private.fail('PT403', format('Отменить можно в течение %s минут. Обратитесь к администратору.', p_max_age / 60));
  end if;
  perform pg_advisory_xact_lock(e.user_id);
  select * into b from app_private.balance(e.user_id);
  if b.balance - e.earned + e.spent < 0 then
    perform app_private.fail('PT409', 'Клиент уже потратил бонусы, начисленные за эту покупку — отмена сделает баланс отрицательным');
  end if;
  update app_private.events set cancelled = true where id = p_id;
  perform app_private.notify_user(e.user_id, '↩️ Последняя покупка по вашей карте отменена, бонусы пересчитаны.');
end $$;

-- ----------------------------------------------------------------- API: клиент

create or replace function public.api_config() returns jsonb
language sql stable security definer set search_path = app_private, extensions, pg_temp as $$
  select jsonb_build_object('shop_name', cfg('shop_name'), 'dev', cfg('dev_login') = '1',
                            'bot_username', case when cfg('bot_token') <> '' then cfg('bot_username') else '' end) $$;

create or replace function public.auth_telegram(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare tok text := cfg('bot_token'); dcs text; good text; uid int;
begin
  if coalesce(tok, '') = '' or p_data is null or p_data ->> 'id' is null then
    return login_error('Не удалось подтвердить вход через Telegram', 403);
  end if;
  select string_agg(key || '=' || value, E'\n' order by key) into dcs
    from jsonb_each_text(p_data) where key <> 'hash';
  good := encode(hmac(convert_to(dcs, 'utf8'), digest(tok, 'sha256'), 'sha256'), 'hex');
  if good <> coalesce(p_data ->> 'hash', '')
     or coalesce((p_data ->> 'auth_date')::bigint, 0) < extract(epoch from now()) - 86400 then
    return login_error('Не удалось подтвердить вход через Telegram', 403);
  end if;
  uid := upsert_user('tg:' || (p_data ->> 'id'), left(coalesce(p_data ->> 'first_name', 'Гость'), 60), p_data ->> 'username');
  return jsonb_build_object('token', new_session('user', uid, interval '30 days'));
end $$;

create or replace function public.auth_dev(p_name text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare n text := left(trim(coalesce(p_name, '')), 60);
begin
  if cfg('dev_login') <> '1' then return login_error('Тестовый вход отключён', 403); end if;
  if n = '' then return login_error('Введите имя', 400); end if;
  return jsonb_build_object('token', new_session('user', upsert_user('dev:' || lower(n), n, null), interval '30 days'));
end $$;

create or replace function public.auth_register(p_name text, p_login text, p_password text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  n text := left(trim(coalesce(p_name, '')), 60);
  l text := lower(trim(coalesce(p_login, '')));
  k text := 'reg:' || client_key();
  uid int;
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
    insert into users (tg_id, name, login, password_hash)
    values ('login:' || l, n, l, crypt(p_password, gen_salt('bf')))
    returning id into uid;
  exception when unique_violation then
    return login_error('Такой логин уже занят', 409);
  end;
  perform rate_fail(k);                       -- считаем регистрации с одного адреса, чтобы не засыпали базу
  return jsonb_build_object('token', new_session('user', uid, interval '30 days'));
end $$;

create or replace function public.auth_login(p_login text, p_password text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  l text := lower(trim(coalesce(p_login, '')));
  k text := client_key();
  lk text := 'login:' || l;                   -- отдельный счётчик на логин: защита от подбора пароля к чужому аккаунту
  u record;
begin
  if rate_blocked(k, 10) or rate_blocked('global', 120) or rate_blocked(lk, 8) then
    return login_error('Слишком много попыток. Подождите 5 минут.', 429);
  end if;
  select id, password_hash into u from users where lower(login) = l;
  if not found or coalesce(p_password, '') = '' or crypt(p_password, u.password_hash) <> u.password_hash then
    perform rate_fail(k); if k <> 'global' then perform rate_fail('global'); end if; perform rate_fail(lk);
    return login_error('Неверный логин или пароль', 403);
  end if;
  return jsonb_build_object('token', new_session('user', u.id, interval '30 days'));
end $$;

create or replace function public.logout(p_token text) returns jsonb
language sql security definer set search_path = app_private, extensions, pg_temp as $$
  with d as (delete from app_private.sessions
              where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') returning 1)
  select jsonb_build_object('ok', true) $$;

create or replace function public.me(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user');
begin
  return customer_view(uid) || jsonb_build_object('history', (
    select coalesce(jsonb_agg(h order by h.id desc), '[]'::jsonb) from (
      select e.id, e.amount, e.spent, e.earned, extract(epoch from e.created_at)::bigint as created_at,
             l.name as location
        from events e left join locations l on l.id = e.location_id
       where e.user_id = uid and not e.cancelled order by e.id desc limit 15) h));
end $$;

create or replace function public.my_qr(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user'); w bigint := qr_window();
begin
  return jsonb_build_object('payload', 'BC1.' || uid || '.' || w || '.' || qr_sig(uid, w),
    'card', uid, 'code', qr_code(uid, w), 'expires_in', 60);
end $$;

-- ----------------------------------------------------------------- API: бариста

create or replace function public.staff_login(p_pin text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare k text := client_key(); sid int;
begin
  if rate_blocked(k, 10) or rate_blocked('global', 60) then
    return login_error('Слишком много попыток. Подождите 5 минут.', 429);
  end if;
  select s.id into sid from staff s join locations l on l.id = s.location_id
   where s.pin_hash = pin_hash(p_pin) and s.active and l.active;
  if sid is null then
    perform rate_fail(k); if k <> 'global' then perform rate_fail('global'); end if;
    return login_error('Неверный PIN', 403);
  end if;
  return jsonb_build_object('token', new_session('staff', sid, interval '12 hours'));
end $$;

create or replace function app_private.staff_info(p_sid int) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  select jsonb_build_object('id', s.id, 'name', s.name, 'location_id', s.location_id, 'location', l.name)
    into r from app_private.staff s join app_private.locations l on l.id = s.location_id
   where s.id = p_sid and s.active and l.active;
  if r is null then perform app_private.fail('PT401', 'Нужен вход'); end if;
  return r;
end $$;

create or replace function public.staff_me(p_token text) returns jsonb
language sql security definer set search_path = app_private, extensions, pg_temp as $$
  select staff_info(auth(p_token, 'staff')) $$;

create or replace function public.staff_lookup(p_token text, p_payload text default null,
                                               p_card text default null, p_code text default null) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform staff_info(auth(p_token, 'staff'));
  return customer_view(resolve_user(p_payload, p_card, p_code));
end $$;

create or replace function public.staff_purchase(p_token text, p_amount int, p_spend int default 0,
                                                 p_payload text default null, p_card text default null,
                                                 p_code text default null) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  st jsonb := staff_info(auth(p_token, 'staff'));
  uid int := resolve_user(p_payload, p_card, p_code);
  total int := p_amount; spend int := coalesce(p_spend, 0);
  maxc int := cfg_int('max_check'); bal int; max_spend int; paid int; earned int; msg text;
begin
  if total is null or total < 1 or total > maxc then
    perform fail('PT400', format('Сумма чека: допустимо от 1 до %s ₽', maxc));
  end if;
  if spend < 0 or spend > total then perform fail('PT400', 'Списание: некорректная сумма'); end if;
  perform pg_advisory_xact_lock(uid);
  if exists (select 1 from events where user_id = uid and not cancelled and amount = total
              and created_at > now() - interval '30 seconds') then
    perform fail('PT409', 'Такая же покупка только что проведена. Если это не ошибка — подождите полминуты.');
  end if;
  select b.balance into bal from balance(uid) b;
  max_spend := least(bal, total * cfg_int('max_spend_percent') / 100);
  if spend > max_spend then
    perform fail('PT409', format('Списать можно не больше %s бонусов (лимит %s%% чека и баланс клиента)',
                                 max_spend, cfg_int('max_spend_percent')));
  end if;
  paid := total - spend;
  earned := paid * cfg_int('earn_percent') / 100;
  insert into events (user_id, location_id, staff_id, amount, spent, earned)
  values (uid, (st ->> 'location_id')::int, (st ->> 'id')::int, total, spend, earned);

  select b.balance into bal from balance(uid) b;
  msg := format('💰 Покупка на %s ₽.', total)
      || case when earned > 0 then format(' Начислено: +%s %s.', earned, bonus_word(earned)) else '' end
      || case when spend > 0 then format(' Списано: %s %s.', spend, bonus_word(spend)) else '' end
      || format(' Баланс: %s %s (1 бонус = 1 ₽).', bal, bonus_word(bal));
  perform notify_user(uid, msg);
  return customer_view(uid) || jsonb_build_object('paid', paid, 'earned', earned, 'spent', spend);
end $$;

create or replace function public.staff_recent(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare st jsonb := staff_info(auth(p_token, 'staff'));
begin
  return jsonb_build_object('items', (
    select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
      select e.id, e.amount, e.spent, e.earned, e.cancelled, extract(epoch from e.created_at)::bigint as created_at,
             u.name, (not e.cancelled and now() - e.created_at <= interval '15 minutes') as can_cancel
        from events e join users u on u.id = e.user_id
       where e.location_id = (st ->> 'location_id')::int order by e.id desc limit 10) x));
end $$;

create or replace function public.staff_cancel(p_token text, p_event_id bigint) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare st jsonb := staff_info(auth(p_token, 'staff'));
begin
  perform cancel_event(p_event_id, (st ->> 'location_id')::int, 15 * 60);
  return jsonb_build_object('ok', true);
end $$;

-- ----------------------------------------------------------------- API: администратор

create or replace function public.admin_login(p_password text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare k text := client_key(); h text := cfg('admin_hash');
begin
  if rate_blocked(k, 10) or rate_blocked('global', 60) then
    return login_error('Слишком много попыток. Подождите 5 минут.', 429);
  end if;
  if coalesce(p_password, '') = '' or crypt(p_password, h) <> h then
    perform rate_fail(k); if k <> 'global' then perform rate_fail('global'); end if;
    return login_error('Неверный пароль', 403);
  end if;
  return jsonb_build_object('token', new_session('admin', 0, interval '12 hours'));
end $$;

create or replace function public.admin_set_password(p_token text, p_new text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  if length(coalesce(p_new, '')) < 4 then perform fail('PT400', 'Пароль — не короче 4 символов'); end if;
  update config set value = crypt(p_new, gen_salt('bf')) where key = 'admin_hash';
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
        'outstanding', coalesce(sum(earned) - sum(spent), 0),
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
           coalesce(sum(e.earned), 0) - coalesce(sum(e.spent), 0) as balance,
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

create or replace function public.admin_client(p_token text, p_id int) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare u jsonb;
begin
  perform auth(p_token, 'admin');
  select jsonb_build_object('id', id, 'name', name, 'username', username, 'login', login,
                            'created_at', extract(epoch from created_at)::bigint)
    into u from users where id = p_id;
  if u is null then perform fail('PT404', 'Клиент не найден'); end if;
  return jsonb_build_object('user', u) || to_jsonb((select b from balance(p_id) b))
    || jsonb_build_object('history', (
      select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
        select e.id, e.amount, e.spent, e.earned, e.cancelled, extract(epoch from e.created_at)::bigint as created_at,
               l.name as location, s.name as staff
          from events e left join locations l on l.id = e.location_id left join staff s on s.id = e.staff_id
         where e.user_id = p_id order by e.id desc limit 30) x));
end $$;

create or replace function public.admin_client_set_password(p_token text, p_id int, p_new text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  if not exists (select 1 from users where id = p_id and login is not null) then
    perform fail('PT404', 'У клиента нет логина (он входит через Telegram)');
  end if;
  if length(coalesce(p_new, '')) < 6 then perform fail('PT400', 'Пароль — не короче 6 символов'); end if;
  if octet_length(p_new) > 72 then perform fail('PT400', 'Пароль слишком длинный (до 72 байт)'); end if;
  update users set password_hash = crypt(p_new, gen_salt('bf')) where id = p_id;
  delete from sessions where role = 'user' and subject = p_id;      -- старые входы клиента закрываются
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_cancel(p_token text, p_event_id bigint) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  perform cancel_event(p_event_id, null, null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_locations(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  return jsonb_build_object('items', (select coalesce(jsonb_agg(x order by x.id), '[]'::jsonb)
           from (select id, name from locations where active) x));
end $$;

create or replace function public.admin_location_add(p_token text, p_name text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare n text := left(trim(coalesce(p_name, '')), 80);
begin
  perform auth(p_token, 'admin');
  if n = '' then perform fail('PT400', 'Введите название точки'); end if;
  insert into locations (name) values (n);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_location_delete(p_token text, p_id int) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  update locations set active = false where id = p_id;
  update staff set active = false where location_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_staff(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  return jsonb_build_object('items', (select coalesce(jsonb_agg(x order by x.id), '[]'::jsonb) from (
    select s.id, s.name, l.name as location from staff s join locations l on l.id = s.location_id
     where s.active and l.active) x));
end $$;

create or replace function public.admin_staff_add(p_token text, p_name text, p_location_id int, p_pin text)
returns jsonb language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare n text := left(trim(coalesce(p_name, '')), 60);
begin
  perform auth(p_token, 'admin');
  if n = '' or not exists (select 1 from locations where id = p_location_id and active) then
    perform fail('PT400', 'Укажите имя и точку');
  end if;
  if coalesce(trim(p_pin), '') !~ '^\d{4,8}$' then perform fail('PT400', 'PIN — от 4 до 8 цифр'); end if;
  begin
    insert into staff (name, location_id, pin_hash) values (n, p_location_id, pin_hash(trim(p_pin)));
  exception when unique_violation then
    perform fail('PT409', 'Такой PIN уже занят, выберите другой');
  end;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_staff_delete(p_token text, p_id int) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  update staff set active = false where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_settings(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  return jsonb_build_object('earn_percent', cfg_int('earn_percent'), 'max_spend_percent', cfg_int('max_spend_percent'),
                            'max_check', cfg_int('max_check'), 'notify', cfg_int('notify'));
end $$;

create or replace function public.admin_settings_save(p_token text, p_earn_percent int, p_max_spend_percent int,
                                                      p_max_check int, p_notify int) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  if p_earn_percent is null or p_earn_percent not between 0 and 100
     or p_max_spend_percent is null or p_max_spend_percent not between 0 and 100
     or p_max_check is null or p_max_check not between 100 and 1000000
     or p_notify is null or p_notify not between 0 and 1 then
    perform fail('PT400', 'Некорректное значение');
  end if;
  update config set value = p_earn_percent::text where key = 'earn_percent';
  update config set value = p_max_spend_percent::text where key = 'max_spend_percent';
  update config set value = p_max_check::text where key = 'max_check';
  update config set value = p_notify::text where key = 'notify';
  return jsonb_build_object('ok', true);
end $$;

-- ----------------------------------------------------------------- права

revoke all on schema app_private from public, anon, authenticated;
revoke all on all tables in schema app_private from public, anon, authenticated;
revoke all on all sequences in schema app_private from public, anon, authenticated;
revoke all on all functions in schema app_private from public, anon, authenticated;
grant usage on schema public to anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;

-- ################ миграция 0002_recovery_and_push.sql ################

-- ============================================================================
-- 0002 — восстановление пароля по коду, push-уведомления с сайта, учёт миграций.
-- Файл можно применять повторно: всё идемпотентно.
-- ============================================================================

-- ----------------------------------------------------------------- учёт применённых миграций

create table if not exists app_private.schema_migrations (
  version text primary key, title text not null, applied_at timestamptz not null default now());
alter table app_private.schema_migrations enable row level security;
insert into app_private.schema_migrations (version, title)
values ('0001', 'Базовая схема: бонусы, QR, роли, регистрация по логину')
on conflict do nothing;

-- ----------------------------------------------------------------- настройки push

-- push_secret — общий секрет между базой и Edge Function send-push (создаётся автоматически).
-- VAPID-ключи функция генерирует сама при первом запуске и сохраняет сюда же.
insert into app_private.config (key, value) values
  ('push_secret', encode(extensions.gen_random_bytes(24), 'hex')),
  ('vapid_public', ''),
  ('vapid_private', ''),
  ('functions_url', '')
on conflict (key) do nothing;

create table if not exists app_private.push_subs (
  id serial primary key,
  user_id int not null references app_private.users (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now());
create index if not exists push_subs_user on app_private.push_subs (user_id);
alter table app_private.push_subs enable row level security;

-- ----------------------------------------------------------------- код восстановления пароля

alter table app_private.users add column if not exists recovery_hash text;

-- Код вида ABCD-EFGH-JKLM-NPQR: 16 символов из 32 («читаемый» алфавит без 0/O/1/I) = 80 бит.
create or replace function app_private.new_recovery_code() returns text
language plpgsql as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := extensions.gen_random_bytes(16);
  s text := '';
  i int;
begin
  for i in 0..15 loop
    s := s || substr(alphabet, (get_byte(b, i) & 31) + 1, 1);
    if i in (3, 7, 11) then s := s || '-'; end if;
  end loop;
  return s;
end $$;

create or replace function app_private.recovery_norm(p text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) $$;

-- Регистрация теперь выдаёт код восстановления (показывается один раз).
create or replace function public.auth_register(p_name text, p_login text, p_password text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  n text := left(trim(coalesce(p_name, '')), 60);
  l text := lower(trim(coalesce(p_login, '')));
  k text := 'reg:' || client_key();
  uid int;
  code text := new_recovery_code();
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
  perform rate_fail(k);                       -- считаем регистрации с одного адреса, чтобы не засыпали базу
  return jsonb_build_object('token', new_session('user', uid, interval '30 days'), 'recovery_code', code);
end $$;

-- Забыли пароль: логин + код восстановления + новый пароль. Код при этом заменяется новым.
create or replace function public.auth_recover(p_login text, p_code text, p_new text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  l text := lower(trim(coalesce(p_login, '')));
  k text := client_key();
  lk text := 'rec:' || l;                     -- отдельный счётчик на логин: код не подобрать перебором
  u record;
  code text;
begin
  if rate_blocked(k, 10) or rate_blocked('global', 120) or rate_blocked(lk, 6) then
    return login_error('Слишком много попыток. Подождите 5 минут.', 429);
  end if;
  if length(coalesce(p_new, '')) < 6 then return login_error('Новый пароль — не короче 6 символов', 400); end if;
  if octet_length(p_new) > 72 then return login_error('Пароль слишком длинный (до 72 байт)', 400); end if;
  select id, recovery_hash into u from users where lower(login) = l;
  if not found or u.recovery_hash is null or recovery_norm(p_code) = ''
     or crypt(recovery_norm(p_code), u.recovery_hash) <> u.recovery_hash then
    perform rate_fail(k); if k <> 'global' then perform rate_fail('global'); end if; perform rate_fail(lk);
    return login_error('Неверный логин или код восстановления', 403);
  end if;
  code := new_recovery_code();
  update users set password_hash = crypt(p_new, gen_salt('bf')),
                   recovery_hash = crypt(recovery_norm(code), gen_salt('bf'))
   where id = u.id;
  delete from sessions where role = 'user' and subject = u.id;     -- прежние входы закрываются
  return jsonb_build_object('token', new_session('user', u.id, interval '30 days'), 'recovery_code', code);
end $$;

-- Новый код восстановления для уже вошедшего клиента (для тех, кто регистрировался до появления кодов,
-- или потерял код). Прежний код перестаёт работать.
create or replace function public.my_recovery_code(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user'); code text := new_recovery_code();
begin
  if not exists (select 1 from users where id = uid and login is not null) then
    perform fail('PT404', 'Вы вошли через Telegram — пароль и код восстановления не нужны');
  end if;
  update users set recovery_hash = crypt(recovery_norm(code), gen_salt('bf')) where id = uid;
  return jsonb_build_object('recovery_code', code);
end $$;

-- ----------------------------------------------------------------- push-уведомления

-- Профиль клиента: добавили число устройств с уведомлениями и признаки пароля/кода.
create or replace function public.me(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user');
begin
  return customer_view(uid) || jsonb_build_object(
    'push_devices', (select count(*) from push_subs where user_id = uid),
    'has_password', exists (select 1 from users where id = uid and login is not null),
    'has_recovery', exists (select 1 from users where id = uid and recovery_hash is not null),
    'history', (
      select coalesce(jsonb_agg(h order by h.id desc), '[]'::jsonb) from (
        select e.id, e.amount, e.spent, e.earned, extract(epoch from e.created_at)::bigint as created_at,
               l.name as location
          from events e left join locations l on l.id = e.location_id
         where e.user_id = uid and not e.cancelled order by e.id desc limit 15) h));
end $$;

-- Для страницы: публичный VAPID-ключ нужен браузеру, чтобы оформить подписку.
create or replace function public.api_config() returns jsonb
language sql stable security definer set search_path = app_private, extensions, pg_temp as $$
  select jsonb_build_object('shop_name', cfg('shop_name'), 'dev', cfg('dev_login') = '1',
                            'bot_username', case when cfg('bot_token') <> '' then cfg('bot_username') else '' end,
                            'vapid_public', cfg('vapid_public')) $$;

create or replace function public.push_subscribe(p_token text, p_sub jsonb) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare
  uid int := auth(p_token, 'user');
  ep text := p_sub ->> 'endpoint';
  k1 text := p_sub #>> '{keys,p256dh}';
  k2 text := p_sub #>> '{keys,auth}';
begin
  if ep is null or ep !~ '^https://' or length(ep) > 1000
     or k1 is null or length(k1) not between 60 and 200 or k2 is null or length(k2) not between 16 and 100 then
    perform fail('PT400', 'Некорректная подписка на уведомления');
  end if;
  insert into push_subs (user_id, endpoint, p256dh, auth) values (uid, ep, k1, k2)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
  delete from push_subs where id in (select id from push_subs where user_id = uid order by id desc offset 5);  -- не больше 5 устройств
  return jsonb_build_object('ok', true, 'devices', (select count(*) from push_subs where user_id = uid));
end $$;

create or replace function public.push_unsubscribe(p_token text, p_endpoint text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user');
begin
  delete from push_subs where user_id = uid and endpoint = p_endpoint;
  return jsonb_build_object('ok', true, 'devices', (select count(*) from push_subs where user_id = uid));
end $$;

-- Отправка push клиенту: база собирает подписки и просит Edge Function send-push отправить.
-- Любые сбои молча игнорируются — покупка из-за уведомления сорваться не должна.
create or replace function app_private.push_user(p_uid int, p_title text, p_body text) returns void
language plpgsql as $$
declare subs jsonb; base text := cfg('functions_url');
begin
  if cfg('vapid_public') = '' or base = '' then return; end if;
  select jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)) into subs
    from app_private.push_subs where user_id = p_uid;
  if subs is null then return; end if;
  begin
    perform net.http_post(
      url := base || '/send-push',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cfg('push_secret')),
      body := jsonb_build_object('title', p_title, 'body', p_body, 'subs', subs));
  exception when others then
    raise notice 'push не отправлен: %', sqlerrm;
  end;
end $$;

create or replace function app_private.notify_user(p_uid int, p_text text) returns void
language plpgsql as $$
declare u record; tok text := app_private.cfg('bot_token');
begin
  if app_private.cfg_int('notify') = 0 then return; end if;
  select name, tg_id into u from app_private.users where id = p_uid;
  if not found then return; end if;
  perform app_private.push_user(p_uid, app_private.cfg('shop_name'), p_text);      -- push на устройства клиента
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

-- Клиент включил уведомления — отправляем пробное, чтобы он сразу увидел, что работает.
create or replace function public.push_test(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare uid int := auth(p_token, 'user');
begin
  perform push_user(uid, cfg('shop_name'), 'Уведомления включены. Сюда будут приходить бонусы за покупки.');
  return jsonb_build_object('ok', true);
end $$;

-- ---- методы для Edge Function send-push: защищены общим секретом, а не токеном роли ----

create or replace function app_private.check_push_secret(p_secret text) returns void
language plpgsql as $$
begin
  if coalesce(p_secret, '') = '' or extensions.digest(p_secret, 'sha256') <> extensions.digest(app_private.cfg('push_secret'), 'sha256') then
    perform app_private.fail('PT401', 'Нет доступа');
  end if;
end $$;

create or replace function public.push_keys(p_secret text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform check_push_secret(p_secret);
  return jsonb_build_object('public', cfg('vapid_public'), 'private', cfg('vapid_private'));
end $$;

create or replace function public.push_keys_set(p_secret text, p_public text, p_private text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform check_push_secret(p_secret);
  if cfg('vapid_public') <> '' then perform fail('PT409', 'Ключи уже заданы'); end if;       -- задаются один раз
  if length(coalesce(p_public, '')) not between 80 and 100 or length(coalesce(p_private, '')) not between 40 and 50 then
    perform fail('PT400', 'Некорректные ключи');
  end if;
  update config set value = p_public where key = 'vapid_public';
  update config set value = p_private where key = 'vapid_private';
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.push_prune(p_secret text, p_endpoints text[]) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform check_push_secret(p_secret);
  delete from push_subs where endpoint = any (p_endpoints);        -- подписки, которые браузер уже отозвал
  return jsonb_build_object('ok', true);
end $$;

-- ---- администратор: подключение и статус push ----

create or replace function public.admin_push_setup(p_token text, p_functions_url text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
declare u text := rtrim(trim(coalesce(p_functions_url, '')), '/');
begin
  perform auth(p_token, 'admin');
  if u !~ '^https://[a-z0-9-]+\.supabase\.co/functions/v1$' then
    perform fail('PT400', 'Адрес функций вида https://<проект>.supabase.co/functions/v1');
  end if;
  update config set value = u where key = 'functions_url';
  begin
    perform net.http_post(url := u || '/send-push',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cfg('push_secret')),
      body := jsonb_build_object('action', 'init'));       -- функция создаст VAPID-ключи и сохранит их в базу
  exception when others then
    perform fail('PT500', 'Не удалось обратиться к функции (включён ли pg_net?)');
  end;
  return jsonb_build_object('ok', true, 'ready', cfg('vapid_public') <> '');
end $$;

create or replace function public.admin_push_status(p_token text) returns jsonb
language plpgsql security definer set search_path = app_private, extensions, pg_temp as $$
begin
  perform auth(p_token, 'admin');
  return jsonb_build_object('ready', cfg('vapid_public') <> '', 'functions_url', cfg('functions_url'),
                            'devices', (select count(*) from push_subs),
                            'clients', (select count(distinct user_id) from push_subs));
end $$;

-- ----------------------------------------------------------------- права и учёт

insert into app_private.schema_migrations (version, title)
values ('0002', 'Восстановление пароля по коду, push-уведомления, учёт миграций')
on conflict do nothing;

revoke all on all tables in schema app_private from public, anon, authenticated;
revoke all on all sequences in schema app_private from public, anon, authenticated;
revoke all on all functions in schema app_private from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;

-- ################ миграция 0003_expiry_reports_broadcast_offline.sql ################

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

-- ################ миграция 0004_loyalty_privacy.sql ################

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
