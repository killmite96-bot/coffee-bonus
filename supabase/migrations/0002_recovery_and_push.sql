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
