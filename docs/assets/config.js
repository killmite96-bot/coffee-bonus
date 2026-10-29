// Подключение к Supabase. Здесь только публичные значения (они видны в браузере всем,
// безопасность обеспечивают закрытые таблицы и проверка токенов в schema.sql).
// Заполните после создания проекта: Supabase → Project Settings → API.
window.APP_CONFIG = {
  SUPABASE_URL: '',   // например: https://abcdefgh.supabase.co
  SUPABASE_KEY: '',   // публичный ключ: anon (eyJ...) или publishable (sb_publishable_...). НЕ service_role!
};
