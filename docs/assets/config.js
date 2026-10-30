// Подключение к Supabase. Здесь только публичные значения (они видны в браузере всем,
// безопасность обеспечивают закрытые таблицы и проверка токенов в schema.sql).
// Источник: Supabase → Project Settings → API keys.
window.APP_CONFIG = {
  // Реквизиты оператора для страницы «Персональные данные» (privacy/): например, 'ИП Иванов И. И., ИНН …' и e-mail или телефон.
  OPERATOR: '',
  CONTACT: '',
  SUPABASE_URL: 'https://faogiedyazbwycalhqqx.supabase.co',
  SUPABASE_KEY: 'sb_publishable_6JVc5RU5i_G1shPou1dpxw_Hmu7HU6x',   // публичный (publishable) ключ. service_role/secret сюда нельзя!
};
