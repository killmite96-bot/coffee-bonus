// Supabase Edge Function «send-push»: отправляет web-push уведомления подписчикам.
//
// Зачем нужна: шифрование и подпись web-push (VAPID, RFC 8291) в SQL не выполнить, а у сайта на GitHub Pages
// нет сервера. Функцию вызывает сама база (pg_net) при покупке и при «пробном» уведомлении.
//
// Безопасность: вызывать её может только тот, кто знает общий секрет из таблицы config (заголовок x-push-secret).
// Секрет проверяет база через rpc push_keys — функция ничего не хранит и без верного секрета ничего не отправит.
// «Verify JWT» для этой функции нужно ВЫКЛЮЧИТЬ (база шлёт запросы без JWT, см. README).
//
// Протокол (JSON, POST):
//   {"action": "init"}                               — создать VAPID-ключи, если их ещё нет
//   {"title": "...", "body": "...", "subs": [{endpoint, p256dh, auth}, ...]} — отправить уведомление
import webpush from "npm:web-push@3.6.7";

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const secret = req.headers.get("x-push-secret") ?? "";
  const base = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!secret || !base || !anon) return json({ error: "unauthorized" }, 401);

  // Вызов защищённых функций базы. Права дают не ключ anon, а секрет в аргументах.
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const r = await fetch(`${base}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: { apikey: anon, "Content-Type": "application/json" },
      body: JSON.stringify(args),
    });
    return { ok: r.ok, status: r.status, data: await r.json().catch(() => null) };
  };

  const keys = await rpc("push_keys", { p_secret: secret });
  if (!keys.ok) return json({ error: "forbidden" }, 401);

  let pub: string = keys.data?.public ?? "";
  let priv: string = keys.data?.private ?? "";
  if (!pub || !priv) {                                  // первый запуск: создаём ключи и сохраняем в базу
    const g = webpush.generateVAPIDKeys();
    const saved = await rpc("push_keys_set", { p_secret: secret, p_public: g.publicKey, p_private: g.privateKey });
    if (!saved.ok) return json({ error: "keys", status: saved.status, detail: saved.data }, 500);
    pub = g.publicKey;
    priv = g.privateKey;
  }

  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  if (body.action === "init") return json({ ok: true, ready: true });

  const subs = (Array.isArray(body.subs) ? body.subs : []).slice(0, 10) as Array<
    { endpoint: string; p256dh: string; auth: string }
  >;
  webpush.setVapidDetails("https://killmite96-bot.github.io/coffee-bonus/", pub, priv);
  const payload = JSON.stringify({
    title: String(body.title ?? "Кофе-карта").slice(0, 80),
    body: String(body.body ?? "").slice(0, 300),
    url: "./",
  });

  const dead: string[] = [];
  const errors: Array<{ status: number; message: string }> = [];
  let sent = 0;
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, {
        TTL: 60 * 60 * 24,
      });
      sent++;
    } catch (e) {
      const status = (e as { statusCode?: number }).statusCode ?? 0;
      if (status === 404 || status === 410) dead.push(s.endpoint);          // подписку браузер уже отозвал
      else errors.push({ status, message: String((e as { body?: string }).body ?? (e as Error).message).slice(0, 200) });
    }
  }));
  if (dead.length) await rpc("push_prune", { p_secret: secret, p_endpoints: dead });

  return json({ sent, pruned: dead.length, errors });
});
