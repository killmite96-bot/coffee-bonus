// Сеть в приоритете (каждый раз сверяемся с сервером, чтобы обновления появлялись сразу),
// кэш — запасной вариант: карта откроется и при плохой связи.
const CACHE = 'bonus-v5';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(
  caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim())
));

self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.includes('/rest/v1/')) return;
  e.respondWith(
    // cache: 'no-cache' — не верить копии из HTTP-кэша браузера, а проверить, не изменился ли файл
    fetch(e.request, { cache: 'no-cache' })
      .then(r => {
        if (r.ok) { const c = r.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); }
        return r;
      })
      .catch(() => caches.match(e.request))
  );
});

// ---- push-уведомления (приходят с функции send-push) ----
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Кофе-карта', {
    body: d.body || '',
    icon: 'assets/icon-192.png',
    badge: 'assets/icon-192.png',
    tag: 'bonus',                // новое уведомление заменяет предыдущее, а не копится
    renotify: true,
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) if ('focus' in c) return c.focus();
    return self.clients.openWindow(url);
  }));
});
