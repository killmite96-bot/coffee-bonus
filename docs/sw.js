// Сеть в приоритете (каждый раз сверяемся с сервером, чтобы обновления появлялись сразу),
// кэш — запасной вариант: карта откроется и при плохой связи.
const CACHE = 'bonus-v3';

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
