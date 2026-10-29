const $ = (s, el = document) => el.querySelector(s);

const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

async function api(path, method = 'GET', body) {
  const r = await fetch(path, {
    method,
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(d.error || 'Ошибка'), { status: r.status });
  return d;
}

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

if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
