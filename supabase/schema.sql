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
