#!/usr/bin/env python3
"""Бонусная система кофейни: кэшбэк бонусами (1 бонус = 1 ₽).

С каждой покупки начисляется процент бонусами; бонусами можно оплатить
не больше заданной доли чека (по умолчанию 20%).
Только стандартная библиотека Python 3.9+. Запуск: python server.py
"""
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
DATA = ROOT / "data"
DATA.mkdir(exist_ok=True)
CFG_PATH = ROOT / "config.json"

mimetypes.add_type("application/manifest+json", ".webmanifest")


# ---------------------------------------------------------------- config

def load_config():
    defaults = {
        "shop_name": "Кофейня",
        "port": 8080,
        "bot_token": "",
        "bot_username": "",
        "admin_password": secrets.token_urlsafe(9),
        "secret": secrets.token_hex(32),
    }
    created = not CFG_PATH.exists()
    cfg = dict(defaults)
    if not created:
        cfg.update(json.loads(CFG_PATH.read_text("utf-8")))
    if created or any(k not in json.loads(CFG_PATH.read_text("utf-8")) for k in defaults):
        CFG_PATH.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), "utf-8")
    cfg["bot_token"] = os.environ.get("BOT_TOKEN", cfg["bot_token"])
    cfg["bot_username"] = os.environ.get("BOT_USERNAME", cfg["bot_username"]).lstrip("@")
    cfg["port"] = int(os.environ.get("PORT", cfg["port"]))
    cfg["_created"] = created
    return cfg


CFG = load_config()
SECRET = CFG["secret"].encode()
DEV_MODE = not CFG["bot_token"]  # без токена бота работает тестовый вход

# earn_percent — сколько % от оплаченной суммы возвращается бонусами
# max_spend_percent — какую долю чека можно оплатить бонусами
# max_check — защита от опечаток в сумме чека (₽)
DEFAULT_SETTINGS = {"earn_percent": 5, "max_spend_percent": 20, "max_check": 20000, "notify": 1}
SETTING_LIMITS = {"earn_percent": (0, 100), "max_spend_percent": (0, 100),
                  "max_check": (100, 1_000_000), "notify": (0, 1)}
CANCEL_WINDOW = 15 * 60   # сколько бариста может отменить свою операцию
DUPLICATE_WINDOW = 30     # секунд: защита от двойного нажатия «Провести»


# ---------------------------------------------------------------- database

DB = sqlite3.connect(DATA / "bonus.db", check_same_thread=False)
DB.row_factory = sqlite3.Row
LOCK = threading.RLock()

DB.executescript("""
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS locations(
    id INTEGER PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS staff(
    id INTEGER PRIMARY KEY, name TEXT NOT NULL, location_id INTEGER NOT NULL,
    pin_hash TEXT NOT NULL UNIQUE, active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS users(
    id INTEGER PRIMARY KEY, tg_id TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
    username TEXT, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS events(
    id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, type TEXT NOT NULL,
    location_id INTEGER, staff_id INTEGER, created_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS events_user ON events(user_id);
""")
# amount — сумма чека, spent — списано бонусов, earned — начислено бонусов.
# (Старые записи вида stamp/redeem из версии со штампами игнорируются: везде type='purchase'.)
for _col in ("cancelled INTEGER NOT NULL DEFAULT 0", "amount INTEGER NOT NULL DEFAULT 0",
             "spent INTEGER NOT NULL DEFAULT 0", "earned INTEGER NOT NULL DEFAULT 0"):
    try:
        DB.execute(f"ALTER TABLE events ADD COLUMN {_col}")
    except sqlite3.OperationalError:
        pass  # колонка уже есть
DB.commit()


def rows(sql, args=()):
    with LOCK:
        return [dict(r) for r in DB.execute(sql, args).fetchall()]


def row(sql, args=()):
    with LOCK:
        r = DB.execute(sql, args).fetchone()
        return dict(r) if r else None


def run(sql, args=()):
    with LOCK:
        cur = DB.execute(sql, args)
        DB.commit()
        return cur.lastrowid


def setting(key):
    r = row("SELECT value FROM settings WHERE key=?", (key,))
    return int(r["value"]) if r else DEFAULT_SETTINGS[key]


def pin_hash(pin):
    return hashlib.sha256(SECRET + b":pin:" + pin.encode()).hexdigest()


def seed():
    """При первом запуске создаём одну точку и одного бариста."""
    if row("SELECT 1 AS x FROM locations"):
        return None
    loc = run("INSERT INTO locations(name) VALUES (?)", ("Основная точка",))
    pin = f"{secrets.randbelow(9000) + 1000}"
    run("INSERT INTO staff(name, location_id, pin_hash) VALUES (?,?,?)",
        ("Бариста", loc, pin_hash(pin)))
    return pin


SEED_PIN = seed()


# ---------------------------------------------------------------- tokens

def sign(payload):
    sig = hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{payload}.{sig}"


def unsign(token):
    payload, _, sig = token.rpartition(".")
    good = hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()[:32]
    return payload if payload and hmac.compare_digest(sig, good) else None


QR_STEP = 30      # секунд на одно окно QR-кода
QR_WINDOWS = 3    # принимаем текущее и два предыдущих окна (~90 сек)


def qr_window():
    return int(time.time() // QR_STEP)


def qr_sig(uid, w):
    return hmac.new(SECRET, f"qr:{uid}:{w}".encode(), hashlib.sha256).hexdigest()[:10]


def qr_code(uid, w):
    d = hmac.new(SECRET, f"code:{uid}:{w}".encode(), hashlib.sha256).digest()
    return f"{int.from_bytes(d[:4], 'big') % 1_000_000:06d}"


def resolve_user(body):
    """Определяет клиента по QR-коду или по паре «номер карты + код»."""
    now = qr_window()
    uid = None
    payload = (body.get("payload") or "").strip()
    if payload:
        m = re.fullmatch(r"BC1\.(\d+)\.(\d+)\.([0-9a-f]{10})", payload)
        if not m:
            raise ApiError(400, "Это не QR-код карты лояльности")
        uid, w = int(m.group(1)), int(m.group(2))
        if not hmac.compare_digest(qr_sig(uid, w), m.group(3)):
            raise ApiError(400, "QR-код недействителен")
        if not now - QR_WINDOWS < w <= now + 1:
            raise ApiError(400, "QR-код устарел — пусть клиент обновит экран")
    else:
        try:
            uid = int(str(body.get("card", "")).strip())
        except ValueError:
            raise ApiError(400, "Введите номер карты и код")
        code = str(body.get("code", "")).strip().replace(" ", "")
        if not any(hmac.compare_digest(qr_code(uid, w), code)
                   for w in range(now - QR_WINDOWS + 1, now + 1)):
            raise ApiError(400, "Неверный или устаревший код")
    if not row("SELECT 1 AS x FROM users WHERE id=?", (uid,)):
        raise ApiError(404, "Клиент не найден")
    return uid


# ---------------------------------------------------------------- business logic

def balance(uid):
    r = row("""SELECT COALESCE(SUM(earned),0) AS e, COALESCE(SUM(spent),0) AS s,
               COALESCE(SUM(amount),0) AS a, COUNT(*) AS n
               FROM events WHERE user_id=? AND type='purchase' AND cancelled=0""", (uid,))
    return {"balance": r["e"] - r["s"], "earned_total": r["e"], "spent_total": r["s"],
            "turnover": r["a"], "purchases": r["n"]}


def customer_view(uid):
    u = row("SELECT id, name FROM users WHERE id=?", (uid,))
    return {"user": u, **balance(uid), "earn_percent": setting("earn_percent"),
            "max_spend_percent": setting("max_spend_percent")}


def plural(n, one, few, many):
    n = abs(n)
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


def money(v, name, lo, hi):
    try:
        v = int(v)
    except (TypeError, ValueError):
        raise ApiError(400, f"{name}: введите целое число рублей")
    if not lo <= v <= hi:
        raise ApiError(400, f"{name}: допустимо от {lo} до {hi} ₽")
    return v


def calc_purchase(uid, total, spend):
    """Возвращает (к оплате, начислится). Бросает ApiError при нарушении лимитов."""
    max_spend = min(balance(uid)["balance"], total * setting("max_spend_percent") // 100)
    if spend > max_spend:
        raise ApiError(409, f"Списать можно не больше {max_spend} бонусов "
                            f"(лимит {setting('max_spend_percent')}% чека и баланс клиента)")
    paid = total - spend
    return paid, paid * setting("earn_percent") // 100


def purchase_message(uid, total, spend, earned):
    bal = balance(uid)["balance"]
    parts = [f"💰 Покупка на {total} ₽."]
    if earned:
        parts.append(f"Начислено: +{earned} {plural(earned, 'бонус', 'бонуса', 'бонусов')}.")
    if spend:
        parts.append(f"Списано: {spend} {plural(spend, 'бонус', 'бонуса', 'бонусов')}.")
    parts.append(f"Баланс: {bal} {plural(bal, 'бонус', 'бонуса', 'бонусов')} (1 бонус = 1 ₽).")
    return " ".join(parts)


def notify(uid, text):
    """Сообщение клиенту в Telegram (в тестовом режиме — строка в консоли)."""
    if not setting("notify"):
        return
    u = row("SELECT name, tg_id FROM users WHERE id=?", (uid,))
    if not u:
        return
    if not CFG["bot_token"] or not u["tg_id"].startswith("tg:"):
        print(f"[уведомление → {u['name']}] {text}")
        return
    chat_id = u["tg_id"][3:]

    def send():
        try:
            data = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
            urllib.request.urlopen(
                f"https://api.telegram.org/bot{CFG['bot_token']}/sendMessage", data, timeout=10).read()
        except Exception as e:  # клиент мог заблокировать бота — не страшно
            print("Telegram не доставил сообщение:", e)

    threading.Thread(target=send, daemon=True).start()


def cancel_event(eid, location_id=None, max_age=None):
    with LOCK:
        e = row("SELECT * FROM events WHERE id=? AND type='purchase'", (eid,))
        if not e or e["cancelled"]:
            raise ApiError(404, "Операция не найдена")
        if location_id is not None and e["location_id"] != location_id:
            raise ApiError(403, "Это операция другой точки")
        if max_age and time.time() - e["created_at"] > max_age:
            raise ApiError(403, f"Отменить можно в течение {max_age // 60} минут. Обратитесь к администратору.")
        if balance(e["user_id"])["balance"] - e["earned"] + e["spent"] < 0:
            raise ApiError(409, "Клиент уже потратил бонусы, начисленные за эту покупку — отмена сделает баланс "
                                "отрицательным")
        run("UPDATE events SET cancelled=1 WHERE id=?", (eid,))
    notify(e["user_id"], "↩️ Последняя покупка по вашей карте отменена, бонусы пересчитаны.")
    return e


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


RATE = {}


def rate_check(ip):
    n, t = RATE.get(ip, (0, 0))
    if time.time() - t > 300:
        n = 0
    if n >= 10:
        raise ApiError(429, "Слишком много попыток. Подождите 5 минут.")


def rate_fail(ip):
    n, t = RATE.get(ip, (0, 0))
    RATE[ip] = (1, time.time()) if time.time() - t > 300 else (n + 1, t)


def verify_telegram(d):
    if not CFG["bot_token"]:
        return False
    given = str(d.get("hash", ""))
    check = "\n".join(f"{k}={d[k]}" for k in sorted(d) if k != "hash")
    key = hashlib.sha256(CFG["bot_token"].encode()).digest()
    good = hmac.new(key, check.encode(), hashlib.sha256).hexdigest()
    try:
        fresh = time.time() - int(d.get("auth_date", 0)) < 86400
    except ValueError:
        fresh = False
    return fresh and hmac.compare_digest(given, good)


def upsert_user(tg_id, name, username):
    with LOCK:
        u = row("SELECT id FROM users WHERE tg_id=?", (tg_id,))
        if u:
            run("UPDATE users SET name=?, username=? WHERE id=?", (name, username, u["id"]))
            return u["id"]
        return run("INSERT INTO users(tg_id,name,username,created_at) VALUES (?,?,?,?)",
                   (tg_id, name, username, int(time.time())))


# ---------------------------------------------------------------- API handlers
# Каждый обработчик получает (request, body) и возвращает словарь для JSON.

def api_config(h, b):
    return {"shop_name": CFG["shop_name"], "dev": DEV_MODE, "bot_username": CFG["bot_username"]}


def api_auth_telegram(h, b):
    if not verify_telegram(b):
        raise ApiError(403, "Не удалось подтвердить вход через Telegram")
    name = (b.get("first_name") or "Гость")[:60]
    uid = upsert_user(f"tg:{b['id']}", name, b.get("username"))
    h.set_session("cu", f"u:{uid}", 30 * 86400)
    return {"ok": True}


def api_auth_dev(h, b):
    if not DEV_MODE:
        raise ApiError(403, "Тестовый вход отключён")
    name = (b.get("name") or "").strip()[:60]
    if not name:
        raise ApiError(400, "Введите имя")
    uid = upsert_user(f"dev:{name.lower()}", name, None)
    h.set_session("cu", f"u:{uid}", 30 * 86400)
    return {"ok": True}


def api_logout(h, b):
    for c in ("cu", "cs", "ca"):
        h.clear_session(c)
    return {"ok": True}


def api_me(h, b):
    uid = h.auth("cu")
    hist = rows("""SELECT e.amount, e.spent, e.earned, e.created_at, l.name AS location FROM events e
                   LEFT JOIN locations l ON l.id = e.location_id
                   WHERE e.user_id=? AND e.type='purchase' AND e.cancelled=0
                   ORDER BY e.id DESC LIMIT 15""", (uid,))
    return {**customer_view(uid), "history": hist}


def api_qr(h, b):
    uid = h.auth("cu")
    w = qr_window()
    return {"payload": f"BC1.{uid}.{w}.{qr_sig(uid, w)}", "card": uid, "code": qr_code(uid, w),
            "expires_in": QR_STEP - int(time.time() % QR_STEP)}


def staff_info(sid):
    s = row("""SELECT s.id, s.name, s.location_id, l.name AS location FROM staff s
               JOIN locations l ON l.id = s.location_id
               WHERE s.id=? AND s.active=1 AND l.active=1""", (sid,))
    if not s:
        raise ApiError(401, "Нужен вход")
    return s


def api_staff_login(h, b):
    ip = h.ip()
    rate_check(ip)
    pin = str(b.get("pin", "")).strip()
    s = row("SELECT id FROM staff WHERE pin_hash=? AND active=1", (pin_hash(pin),)) if pin else None
    if not s:
        rate_fail(ip)
        raise ApiError(403, "Неверный PIN")
    h.set_session("cs", f"s:{s['id']}", 12 * 3600)
    return {"ok": True}


def api_staff_me(h, b):
    return staff_info(h.auth("cs"))


def api_staff_lookup(h, b):
    staff_info(h.auth("cs"))
    return customer_view(resolve_user(b))


def api_staff_purchase(h, b):
    st = staff_info(h.auth("cs"))
    uid = resolve_user(b)
    total = money(b.get("amount"), "Сумма чека", 1, setting("max_check"))
    spend = money(b.get("spend", 0), "Списание", 0, total)
    with LOCK:
        dup = row("""SELECT 1 AS x FROM events WHERE user_id=? AND type='purchase' AND cancelled=0
                     AND amount=? AND created_at > ?""", (uid, total, int(time.time()) - DUPLICATE_WINDOW))
        if dup:
            raise ApiError(409, "Такая же покупка только что проведена. Если это не ошибка — подождите полминуты.")
        paid, earned = calc_purchase(uid, total, spend)
        run("""INSERT INTO events(user_id,type,amount,spent,earned,location_id,staff_id,created_at)
               VALUES (?,?,?,?,?,?,?,?)""",
            (uid, "purchase", total, spend, earned, st["location_id"], st["id"], int(time.time())))
    notify(uid, purchase_message(uid, total, spend, earned))
    return {**customer_view(uid), "paid": paid, "earned": earned, "spent": spend}


def api_staff_recent(h, b):
    st = staff_info(h.auth("cs"))
    items = rows("""SELECT e.id, e.amount, e.spent, e.earned, e.cancelled, e.created_at, u.name
                    FROM events e JOIN users u ON u.id = e.user_id
                    WHERE e.location_id=? AND e.type='purchase' ORDER BY e.id DESC LIMIT 10""",
                 (st["location_id"],))
    for i in items:
        i["can_cancel"] = not i["cancelled"] and time.time() - i["created_at"] <= CANCEL_WINDOW
    return {"items": items}


def api_staff_cancel(h, b):
    st = staff_info(h.auth("cs"))
    cancel_event(b.get("event_id"), location_id=st["location_id"], max_age=CANCEL_WINDOW)
    return {"ok": True}


# --- админка

def admin(h):
    h.auth("ca")


def api_admin_login(h, b):
    ip = h.ip()
    rate_check(ip)
    if not hmac.compare_digest(str(b.get("password", "")), CFG["admin_password"]):
        rate_fail(ip)
        raise ApiError(403, "Неверный пароль")
    h.set_session("ca", "a:0", 12 * 3600)
    return {"ok": True}


def api_admin_stats(h, b):
    admin(h)
    today = "date(created_at,'unixepoch','localtime') = date('now','localtime')"
    t = row(f"""SELECT COUNT(*) AS purchases, COALESCE(SUM(amount),0) AS revenue,
                COALESCE(SUM(earned),0) AS earned, COALESCE(SUM(spent),0) AS spent,
                COALESCE(SUM(CASE WHEN {today} THEN 1 END),0) AS purchases_today,
                COALESCE(SUM(CASE WHEN {today} THEN amount END),0) AS revenue_today
                FROM events WHERE type='purchase' AND cancelled=0""")
    t["outstanding"] = t["earned"] - t["spent"]   # бонусов на руках у клиентов
    t["users"] = row("SELECT COUNT(*) AS n FROM users")["n"]
    by_loc = rows("""SELECT l.name, COUNT(e.id) AS purchases, COALESCE(SUM(e.amount),0) AS revenue,
                     COALESCE(SUM(e.earned),0) AS earned, COALESCE(SUM(e.spent),0) AS spent
                     FROM locations l LEFT JOIN events e
                       ON e.location_id = l.id AND e.type='purchase' AND e.cancelled=0
                     WHERE l.active=1 GROUP BY l.id ORDER BY l.id""")
    days = rows("""SELECT date(created_at,'unixepoch','localtime') AS day, COUNT(*) AS purchases,
                   SUM(amount) AS revenue, SUM(earned) AS earned, SUM(spent) AS spent
                   FROM events WHERE type='purchase' AND cancelled=0
                   AND created_at > strftime('%s','now','-7 days')
                   GROUP BY day ORDER BY day DESC""")
    recent = rows("""SELECT e.id, e.amount, e.spent, e.earned, e.cancelled, e.created_at,
                     u.name AS client, l.name AS location, s.name AS staff
                     FROM events e JOIN users u ON u.id = e.user_id
                     LEFT JOIN locations l ON l.id = e.location_id
                     LEFT JOIN staff s ON s.id = e.staff_id
                     WHERE e.type='purchase' ORDER BY e.id DESC LIMIT 20""")
    return {"totals": t, "locations": by_loc, "days": days, "recent": recent}


def api_admin_clients(h, b):
    admin(h)
    q = (b.get("q") or "").strip().lower().lstrip("@")
    items = rows("""SELECT u.id, u.name, u.username, u.created_at,
                    COUNT(e.id) AS purchases, COALESCE(SUM(e.amount),0) AS turnover,
                    COALESCE(SUM(e.earned),0) - COALESCE(SUM(e.spent),0) AS balance,
                    MAX(e.created_at) AS last_visit
                    FROM users u LEFT JOIN events e
                      ON e.user_id = u.id AND e.type='purchase' AND e.cancelled=0
                    GROUP BY u.id ORDER BY COALESCE(MAX(e.created_at), u.created_at) DESC""")
    out = [c for c in items
           if not q or q in c["name"].lower() or q in (c["username"] or "").lower() or q == str(c["id"])]
    return {"total": len(out), "items": out[:200]}


def api_admin_client(h, b):
    admin(h)
    u = row("SELECT id, name, username, created_at FROM users WHERE id=?", (b.get("id"),))
    if not u:
        raise ApiError(404, "Клиент не найден")
    hist = rows("""SELECT e.id, e.amount, e.spent, e.earned, e.cancelled, e.created_at,
                   l.name AS location, s.name AS staff
                   FROM events e LEFT JOIN locations l ON l.id = e.location_id
                   LEFT JOIN staff s ON s.id = e.staff_id
                   WHERE e.user_id=? AND e.type='purchase' ORDER BY e.id DESC LIMIT 30""", (u["id"],))
    return {"user": u, **balance(u["id"]), "history": hist}


def api_admin_cancel(h, b):
    admin(h)
    cancel_event(b.get("event_id"))
    return {"ok": True}


def api_admin_locations(h, b):
    admin(h)
    return {"items": rows("SELECT id, name FROM locations WHERE active=1 ORDER BY id")}


def api_admin_location_add(h, b):
    admin(h)
    name = (b.get("name") or "").strip()[:80]
    if not name:
        raise ApiError(400, "Введите название точки")
    run("INSERT INTO locations(name) VALUES (?)", (name,))
    return {"ok": True}


def api_admin_staff(h, b):
    admin(h)
    return {"items": rows("""SELECT s.id, s.name, l.name AS location FROM staff s
                             JOIN locations l ON l.id = s.location_id
                             WHERE s.active=1 AND l.active=1 ORDER BY s.id""")}


def api_admin_staff_add(h, b):
    admin(h)
    name = (b.get("name") or "").strip()[:60]
    pin = str(b.get("pin", "")).strip()
    loc = row("SELECT id FROM locations WHERE id=? AND active=1", (b.get("location_id"),))
    if not name or not loc:
        raise ApiError(400, "Укажите имя и точку")
    if not re.fullmatch(r"\d{4,8}", pin):
        raise ApiError(400, "PIN — от 4 до 8 цифр")
    try:
        run("INSERT INTO staff(name, location_id, pin_hash) VALUES (?,?,?)",
            (name, loc["id"], pin_hash(pin)))
    except sqlite3.IntegrityError:
        raise ApiError(409, "Такой PIN уже занят, выберите другой")
    return {"ok": True}


def api_admin_settings(h, b):
    admin(h)
    return {k: setting(k) for k in DEFAULT_SETTINGS}


def api_admin_settings_save(h, b):
    admin(h)
    values = {}
    for k, (lo, hi) in SETTING_LIMITS.items():
        try:
            v = int(b[k])
        except (KeyError, ValueError, TypeError):
            raise ApiError(400, "Некорректное значение")
        if not lo <= v <= hi:
            raise ApiError(400, f"Значение должно быть от {lo} до {hi}")
        values[k] = v
    for k, v in values.items():
        run("INSERT INTO settings(key,value) VALUES (?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (k, str(v)))
    return {"ok": True}


def api_admin_delete(h, b, what, item_id):
    admin(h)
    if what == "staff":
        run("UPDATE staff SET active=0 WHERE id=?", (item_id,))
    elif what == "locations":
        run("UPDATE locations SET active=0 WHERE id=?", (item_id,))
        run("UPDATE staff SET active=0 WHERE location_id=?", (item_id,))
    else:
        raise ApiError(404, "Не найдено")
    return {"ok": True}


ROUTES = {
    ("GET", "/api/config"): api_config,
    ("POST", "/api/auth/telegram"): api_auth_telegram,
    ("POST", "/api/auth/dev"): api_auth_dev,
    ("POST", "/api/logout"): api_logout,
    ("GET", "/api/me"): api_me,
    ("GET", "/api/qr"): api_qr,
    ("POST", "/api/staff/login"): api_staff_login,
    ("GET", "/api/staff/me"): api_staff_me,
    ("POST", "/api/staff/lookup"): api_staff_lookup,
    ("POST", "/api/staff/purchase"): api_staff_purchase,
    ("GET", "/api/staff/recent"): api_staff_recent,
    ("POST", "/api/staff/cancel"): api_staff_cancel,
    ("POST", "/api/admin/login"): api_admin_login,
    ("GET", "/api/admin/stats"): api_admin_stats,
    ("POST", "/api/admin/clients"): api_admin_clients,
    ("POST", "/api/admin/client"): api_admin_client,
    ("POST", "/api/admin/cancel"): api_admin_cancel,
    ("GET", "/api/admin/locations"): api_admin_locations,
    ("POST", "/api/admin/locations"): api_admin_location_add,
    ("GET", "/api/admin/staff"): api_admin_staff,
    ("POST", "/api/admin/staff"): api_admin_staff_add,
    ("GET", "/api/admin/settings"): api_admin_settings,
    ("POST", "/api/admin/settings"): api_admin_settings_save,
}

PAGES = {"/": "index.html", "/barista": "barista.html", "/admin": "admin.html",
         "/sw.js": "sw.js", "/manifest.webmanifest": "manifest.webmanifest"}


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "CoffeeBonus/2.0"

    def log_message(self, fmt, *args):
        if "/api/" in (args[0] if args else ""):
            super().log_message(fmt, *args)

    def ip(self):
        fwd = self.headers.get("X-Forwarded-For")
        return fwd.split(",")[0].strip() if fwd else self.client_address[0]

    # --- сессии
    def set_session(self, name, payload, ttl):
        token = sign(f"{payload}:{int(time.time()) + ttl}")
        secure = "; Secure" if self.headers.get("X-Forwarded-Proto") == "https" else ""
        self._cookies.append(f"{name}={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={ttl}{secure}")

    def clear_session(self, name):
        self._cookies.append(f"{name}=; Path=/; HttpOnly; Max-Age=0")

    def auth(self, name):
        jar = SimpleCookie(self.headers.get("Cookie", ""))
        if name not in jar:
            raise ApiError(401, "Нужен вход")
        payload = unsign(jar[name].value)
        try:
            _, ident, exp = payload.split(":")
            if int(exp) < time.time():
                raise ValueError
            return int(ident)
        except (AttributeError, ValueError):
            raise ApiError(401, "Нужен вход")

    # --- ответы
    def send_json(self, obj, status=200):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for c in self._cookies:
            self.send_header("Set-Cookie", c)
        self.end_headers()
        self.wfile.write(data)

    def send_file(self, path):
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def telegram_callback(self):
        """Вход через Telegram без всплывающего окна: Telegram возвращает клиента сюда с подписанными данными.
        Так вход работает и в обычном браузере, и в приложении (WebView)."""
        data = {k: v[0] for k, v in urllib.parse.parse_qs(self.path.partition("?")[2]).items()}
        if not data.get("id") or not verify_telegram(data):
            raise ApiError(403, "Не удалось подтвердить вход через Telegram")
        uid = upsert_user(f"tg:{data['id']}", (data.get("first_name") or "Гость")[:60], data.get("username"))
        self.set_session("cu", f"u:{uid}", 30 * 86400)
        self.send_response(302)
        self.send_header("Location", "/")
        for c in self._cookies:
            self.send_header("Set-Cookie", c)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def handle_any(self, method):
        self._cookies = []
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        try:
            if method == "GET" and path == "/api/auth/telegram-callback":
                return self.telegram_callback()
            if path.startswith("/api/"):
                body = {}
                length = int(self.headers.get("Content-Length") or 0)
                if length:
                    try:
                        body = json.loads(self.rfile.read(min(length, 65536)))
                    except ValueError:
                        raise ApiError(400, "Некорректный запрос")
                if method == "DELETE":
                    m = re.fullmatch(r"/api/admin/(staff|locations)/(\d+)", path)
                    if not m:
                        raise ApiError(404, "Не найдено")
                    return self.send_json(api_admin_delete(self, body, m.group(1), int(m.group(2))))
                fn = ROUTES.get((method, path))
                if not fn:
                    raise ApiError(404, "Не найдено")
                return self.send_json(fn(self, body))
            if method != "GET":
                raise ApiError(405, "Не поддерживается")
            if path in PAGES:
                return self.send_file(STATIC / PAGES[path])
            if path.startswith("/static/"):
                f = (STATIC / path[len("/static/"):]).resolve()
                if STATIC in f.parents and f.is_file():
                    return self.send_file(f)
            raise ApiError(404, "Не найдено")
        except ApiError as e:
            self.send_json({"error": e.message}, e.status)
        except Exception as e:  # noqa: BLE001
            print("Ошибка:", repr(e))
            self.send_json({"error": "Внутренняя ошибка сервера"}, 500)

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    print("=" * 60)
    print(f" {CFG['shop_name']} — бонусная система")
    print(f" Клиенты:  http://localhost:{CFG['port']}/")
    print(f" Бариста:  http://localhost:{CFG['port']}/barista")
    print(f" Админка:  http://localhost:{CFG['port']}/admin")
    if CFG["_created"]:
        print(f"\n Пароль администратора: {CFG['admin_password']}  (хранится в config.json)")
    if SEED_PIN:
        print(f" PIN тестового бариста: {SEED_PIN}  (смените в админке)")
    if DEV_MODE:
        print("\n Токен Telegram-бота не задан — включён ТЕСТОВЫЙ вход по имени.")
        print(" Для боевого режима заполните bot_token и bot_username в config.json.")
    print("=" * 60)
    ThreadingHTTPServer(("0.0.0.0", CFG["port"]), Handler).serve_forever()


if __name__ == "__main__":
    main()
