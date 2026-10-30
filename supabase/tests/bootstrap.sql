-- Заготовка для тестов на обычном Postgres: в Supabase всё это уже есть.
--   * роли anon / authenticated (от имени anon вызываются функции, как через Supabase REST);
--   * заглушка расширения pg_net: вместо реального HTTP-запроса запись в таблицу net.sent, чтобы тесты видели,
--     что и куда «отправлено» (Telegram, push).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create schema if not exists net;
create table if not exists net.sent (id serial primary key, url text, body jsonb, headers jsonb);

create or replace function net.http_post(
  url text, body jsonb default '{}', params jsonb default '{}',
  headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint
language sql as $$ insert into net.sent (url, body, headers) values (url, body, headers) returning id::bigint $$;
