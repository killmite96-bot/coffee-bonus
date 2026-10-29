const $ = (s, el = document) => el.querySelector(s);

const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Корень сайта (папка с index.html), независимо от того, с какой страницы подключён скрипт.
const APP_BASE = new URL('../', document.currentScript.src).href;

// ---------------------------------------------------------------- доступ к Supabase
// Сервера у нас нет: страницы вызывают функции Postgres через Supabase REST (rpc).
// Таблицы закрыты, функции проверяют токен роли. Токены хранятся в localStorage.

const TOKEN_KEY = { user: 'bonus_user', staff: 'bonus_staff', admin: 'bonus_admin' };

function tokenGet(role) { try { return localStorage.getItem(TOKEN_KEY[role]) || ''; } catch { return ''; } }
function tokenSet(role, v) {
  try { v ? localStorage.setItem(TOKEN_KEY[role], v) : localStorage.removeItem(TOKEN_KEY[role]); } catch { /* приватный режим */ }
}

// [функция Postgres, роль токена, как собрать аргументы из тела запроса, роль для сохранения токена после входа]
const ROUTES = {
  'GET /api/config': ['api_config', null, () => ({})],
  'POST /api/auth/telegram': ['auth_telegram', null, b => ({ p_data: b }), 'user'],
  'POST /api/auth/dev': ['auth_dev', null, b => ({ p_name: b.name }), 'user'],
  'GET /api/me': ['me', 'user', () => ({})],
  'GET /api/qr': ['my_qr', 'user', () => ({})],
  'POST /api/staff/login': ['staff_login', null, b => ({ p_pin: String(b.pin ?? '') }), 'staff'],
  'GET /api/staff/me': ['staff_me', 'staff', () => ({})],
  'POST /api/staff/lookup': ['staff_lookup', 'staff', b => ({ p_payload: b.payload, p_card: b.card, p_code: b.code })],
  'POST /api/staff/purchase': ['staff_purchase', 'staff', b => ({
    p_amount: b.amount, p_spend: b.spend || 0, p_payload: b.payload, p_card: b.card, p_code: b.code })],
  'GET /api/staff/recent': ['staff_recent', 'staff', () => ({})],
  'POST /api/staff/cancel': ['staff_cancel', 'staff', b => ({ p_event_id: b.event_id })],
  'POST /api/admin/login': ['admin_login', null, b => ({ p_password: String(b.password ?? '') }), 'admin'],
  'POST /api/admin/password': ['admin_set_password', 'admin', b => ({ p_new: b.password })],
  'GET /api/admin/stats': ['admin_stats', 'admin', () => ({})],
  'POST /api/admin/clients': ['admin_clients', 'admin', b => ({ p_q: b.q || '' })],
  'POST /api/admin/client': ['admin_client', 'admin', b => ({ p_id: b.id })],
  'POST /api/admin/cancel': ['admin_cancel', 'admin', b => ({ p_event_id: b.event_id })],
  'GET /api/admin/locations': ['admin_locations', 'admin', () => ({})],
  'POST /api/admin/locations': ['admin_location_add', 'admin', b => ({ p_name: b.name })],
  'GET /api/admin/staff': ['admin_staff', 'admin', () => ({})],
  'POST /api/admin/staff': ['admin_staff_add', 'admin', b => ({
    p_name: b.name, p_location_id: b.location_id, p_pin: String(b.pin ?? '') })],
  'GET /api/admin/settings': ['admin_settings', 'admin', () => ({})],
  'POST /api/admin/settings': ['admin_settings_save', 'admin', b => ({
    p_earn_percent: Number(b.earn_percent), p_max_spend_percent: Number(b.max_spend_percent),
    p_max_check: Number(b.max_check), p_notify: Number(b.notify) })],
};

function httpError(message, status) { return Object.assign(new Error(message), { status }); }

async function rpc(fn, args) {
  const cfg = window.APP_CONFIG || {};
  if (!cfg.SUPABASE_URL || !cfg.SUPABASE_KEY) {
    throw httpError('Сайт ещё не подключён к базе данных: заполните docs/assets/config.js', 0);
  }
  let r;
  try {
    r = await fetch(cfg.SUPABASE_URL.replace(/\/$/, '') + '/rest/v1/rpc/' + fn, {
      method: 'POST',
      headers: { apikey: cfg.SUPABASE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
  } catch {
    throw httpError('Нет связи с сервером. Проверьте интернет.', 0);
  }
  const data = await r.json().catch(() => null);
  if (!r.ok) throw httpError((data && data.message) || 'Ошибка', r.status);
  if (data && data.__error) throw httpError(data.__error, data.__status || 400);
  return data;
}

// Единая точка входа для страниц: api('/api/me'), api('/api/staff/purchase', 'POST', {...}).
async function api(path, method = 'GET', body) {
  const b = body || {};
  if (path === '/api/logout') {
    for (const role of Object.keys(TOKEN_KEY)) {
      const t = tokenGet(role);
      tokenSet(role, '');
      if (t) rpc('logout', { p_token: t }).catch(() => {});
    }
    return { ok: true };
  }
  let m;
  if (method === 'DELETE' && (m = path.match(/^\/api\/admin\/(staff|locations)\/(\d+)$/))) {
    return call(m[1] === 'staff' ? 'admin_staff_delete' : 'admin_location_delete', 'admin', { p_id: +m[2] });
  }
  const route = ROUTES[method + ' ' + path];
  if (!route) throw httpError('Не найдено: ' + path, 404);
  const [fn, role, build, saveRole] = route;
  const data = await call(fn, role, build(b));
  if (saveRole) {                       // вход: токен прячем в браузер, страницам возвращаем {ok:true}
    tokenSet(saveRole, data.token);
    return { ok: true };
  }
  return data;
}

async function call(fn, role, args) {
  if (role) args = { p_token: tokenGet(role), ...args };
  try {
    return await rpc(fn, args);
  } catch (e) {
    if (e.status === 401 && role) tokenSet(role, '');   // сессия истекла — страница покажет вход
    throw e;
  }
}

// ---------------------------------------------------------------- интерфейс

function toast(text, kind = 'ok') {
  const t = document.createElement('div');
  t.className = 'toast ' + kind;
  t.textContent = text;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3500);
}

const rub = n => Number(n).toLocaleString('ru-RU') + ' ₽';

function bonusWord(n) {
  n = Math.abs(n);
  if (n % 10 === 1 && n % 100 !== 11) return 'бонус';
  if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) return 'бонуса';
  return 'бонусов';
}

// Крупный баланс бонусов (1 бонус = 1 ₽).
function balanceBlock(balance) {
  return `<div class="balance"><b>${Number(balance).toLocaleString('ru-RU')}</b>
    <span>${bonusWord(balance)}</span></div><p class="muted center" style="margin:0">1 бонус = 1 ₽</p>`;
}

// Что произошло в покупке: «+25 бонусов» / «−50 бонусов».
function purchaseDelta(p) {
  const out = [];
  if (p.earned) out.push(`<span class="plus">+${p.earned}</span>`);
  if (p.spent) out.push(`<span class="minus">−${p.spent}</span>`);
  return out.join(' ') || '<span class="muted">0</span>';
}

function fmtDate(ts) {
  return new Date(ts * 1000).toLocaleString('ru-RU',
    { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

if ('serviceWorker' in navigator) navigator.serviceWorker.register(APP_BASE + 'sw.js').catch(() => {});
