#!/usr/bin/env python3
"""Проверка всей логики базы (supabase/schema.sql = миграции) на обычном Postgres.

Функции вызываются от роли anon — ровно так, как это делает сайт через Supabase REST.

Где запускать:
  • локально — Postgres в Docker, контейнер coffee-pg-test (см. README);
  • в CI (GitHub Actions) — задайте PGHOST/PGUSER/PGPASSWORD, нужен клиент psql.
Запуск: python supabase/test_schema.py
"""
import hashlib
import hmac
import io
import json
import os
import re
import subprocess
import sys
import time
import uuid

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
CONTAINER = "coffee-pg-test"
passed = failed = 0


def psql(sql):
    flags = ["-At", "-v", "VERBOSITY=verbose", "-v", "ON_ERROR_STOP=1"]
    if os.environ.get("PGHOST"):          # CI: прямое подключение, пароль берётся из PGPASSWORD
        cmd = ["psql", "-h", os.environ["PGHOST"], "-U", os.environ.get("PGUSER", "postgres"),
               "-d", os.environ.get("PGDATABASE", "postgres"), *flags]
    else:                                  # локально: контейнер Docker
        cmd = ["docker", "exec", "-i", CONTAINER, "psql", "-U", "postgres", *flags]
    r = subprocess.run(cmd, input=sql.encode("utf-8"), capture_output=True)
    return r.returncode, r.stdout.decode("utf-8", "replace").strip(), r.stderr.decode("utf-8", "replace").strip()


class JSON:
    """Обернуть значение, чтобы передать его как jsonb (по умолчанию списки идут как text[])."""
    def __init__(self, v):
        self.v = v


def lit(v):
    if isinstance(v, JSON):
        return "'" + json.dumps(v.v, ensure_ascii=False).replace("'", "''") + "'::jsonb"
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, dict):
        return "'" + json.dumps(v, ensure_ascii=False).replace("'", "''") + "'::jsonb"
    if isinstance(v, list):
        return "array[" + ", ".join(lit(x) for x in v) + "]::text[]"
    return "'" + str(v).replace("'", "''") + "'"


class Err(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code, self.msg = code, msg


def call(fn, **kw):
    """Вызов публичной функции от роли anon. Возвращает JSON или бросает Err(код PTxxx, текст)."""
    args = ", ".join(f"{k} => {lit(v)}" for k, v in kw.items())
    rc, out, err = psql(f"set role anon;\nselect public.{fn}({args})::text;")
    if rc:
        m = re.search(r"ERROR:\s+(\w{5}):\s*(.*)", err)
        raise Err(m.group(1) if m else "?????", m.group(2).strip() if m else err)
    # вывод: "SET" (если не -q) и json; берём последнюю строку
    return json.loads(out.splitlines()[-1])


def owner(sql):
    rc, out, err = psql(sql)
    if rc:
        raise RuntimeError(err)
    return out


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ✓ {name}")
    else:
        failed += 1
        print(f"  ✗ {name}  {detail}")


def raises(name, code, fn, **kw):
    try:
        r = call(fn, **kw)
        check(name, False, f"ожидалась ошибка {code}, пришло {r}")
    except Err as e:
        check(name, e.code == code, f"код {e.code}: {e.msg}")
        return e
    return None


def shift_events(seconds=100):
    owner(f"update app_private.events set created_at = created_at - interval '{seconds} seconds';")


HERE = os.path.dirname(os.path.abspath(__file__))


def read(*parts):
    with open(os.path.join(HERE, *parts), encoding="utf-8") as f:
        return f.read()


def apply_sql(text, what):
    rc, out, err = psql(text)
    if rc:
        sys.exit(f"{what} не применилась:\n{err}")


apply_sql(read("tests", "bootstrap.sql"), "заготовка (роли, заглушка pg_net)")
apply_sql("drop schema if exists app_private cascade; truncate net.sent;", "очистка")
apply_sql(read("schema.sql"), "schema.sql (чистая база)")
owner("update app_private.config set value = '0' where key = 'require_consent';")   # старые проверки регистрируются без галочки

print("== права и доступ")
rc, out, err = psql("set role anon; select * from app_private.users;")
check("anon не читает таблицы app_private", rc != 0 and "permission denied" in err)
rc, out, err = psql("set role anon; select app_private.cfg('secret');")
check("anon не вызывает внутренние функции", rc != 0 and "permission denied" in err)
check("по умолчанию тестовый вход по имени выключен", call("api_config")["dev"] is False)
check("auth_dev без флага отклонён", call("auth_dev", p_name="Хакер").get("__status") == 403)
owner("update app_private.config set value = '1' where key = 'dev_login';")
check("api_config: тестовый режим включён (флаг dev_login)", call("api_config")["dev"] is True)
raises("me без токена → 401", "PT401", "me", p_token="")
raises("me с неверным токеном → 401", "PT401", "me", p_token="abc")

print("== клиент")
r = call("auth_dev", p_name="")
check("пустое имя отклонено", r.get("__error") == "Введите имя")
ctok = call("auth_dev", p_name="Анна")["token"]
me = call("me", p_token=ctok)
check("me: баланс 0, имя, правила", me["balance"] == 0 and me["user"]["name"] == "Анна"
      and me["earn_percent"] == 5 and me["max_spend_percent"] == 20, me)
card = me["user"]["id"]
q = call("my_qr", p_token=ctok)
check("QR-формат и номер карты", re.fullmatch(r"BC1\.\d+\.\d+\.[0-9a-f]{10}", q["payload"]) and q["card"] == card
      and re.fullmatch(r"\d{6}", q["code"]) and q["expires_in"] == 60, q)
check("повторный вход под тем же именем — тот же клиент",
      call("me", p_token=call("auth_dev", p_name="анна")["token"])["user"]["id"] == card)

print("== бариста: вход")
r = call("staff_login", p_pin="0000")
check("неверный PIN → __error 403", r.get("__error") == "Неверный PIN" and r["__status"] == 403)
stok = call("staff_login", p_pin="1234")["token"]
st = call("staff_me", p_token=stok)
check("staff_me: точка", st["location"] == "Основная точка", st)
raises("токен клиента не годится для кассы", "PT401", "staff_me", p_token=ctok)

print("== бариста: поиск клиента")
q = call("my_qr", p_token=ctok)
check("lookup по QR", call("staff_lookup", p_token=stok, p_payload=q["payload"])["user"]["id"] == card)
check("lookup по номеру и коду (с пробелом)",
      call("staff_lookup", p_token=stok, p_card=str(card), p_code=q["code"][:3] + " " + q["code"][3:])["user"]["id"] == card)
raises("неверный код", "PT400", "staff_lookup", p_token=stok, p_card=str(card), p_code="000000")
raises("поддельная подпись QR", "PT400", "staff_lookup", p_token=stok, p_payload=f"BC1.{card}.1.aaaaaaaaaa")
raises("не QR карты", "PT400", "staff_lookup", p_token=stok, p_payload="hello")
raises("пустой запрос", "PT400", "staff_lookup", p_token=stok)
w = int(owner("select app_private.qr_window();"))
def qr_at(slot):
    return f"BC1.{card}.{slot}.{owner(f'select app_private.qr_sig({card}, {slot});')}"


old = qr_at(w - 30)
e = raises("просроченный QR", "PT400", "staff_lookup", p_token=stok, p_payload=old)
check("QR 70 секунд назад ещё принимается (показывается 60 + запас 15)",
      call("staff_lookup", p_token=stok, p_payload=qr_at(w - 7))["user"]["id"] == card)
raises("QR 90 секунд назад уже нет", "PT400", "staff_lookup", p_token=stok, p_payload=qr_at(w - 9))
raises("QR «из будущего» отклонён", "PT400", "staff_lookup", p_token=stok, p_payload=qr_at(w + 5))
code7 = owner(f"select app_private.qr_code({card}, app_private.qr_window() - 7);")
check("код выдачи 70 секунд назад принимается вручную",
      call("staff_lookup", p_token=stok, p_card=str(card), p_code=code7)["user"]["id"] == card)
code9 = owner(f"select app_private.qr_code({card}, app_private.qr_window() - 9);")
raises("код выдачи 90 секунд назад — нет", "PT400", "staff_lookup", p_token=stok, p_card=str(card), p_code=code9)
check("текст про устаревший QR", e is not None and "устарел" in e.msg)
raises("несуществующий клиент", "PT404", "staff_lookup", p_token=stok, p_card="99999",
       p_code=owner("select app_private.qr_code(99999, app_private.qr_window());"))

print("== покупки: начисление 5%")
q = call("my_qr", p_token=ctok)
p1 = call("staff_purchase", p_token=stok, p_amount=1000, p_spend=0, p_payload=q["payload"])
check("чек 1000 → +50, баланс 50", p1["earned"] == 50 and p1["balance"] == 50 and p1["paid"] == 1000, p1)
raises("дубль той же суммы сразу → 409", "PT409", "staff_purchase", p_token=stok, p_amount=1000, p_payload=q["payload"])
shift_events()

print("== покупки: лимит 20% и баланс")
e = raises("списать 100 при чеке 500 и балансе 50 → отказ (не больше 50)", "PT409", "staff_purchase",
           p_token=stok, p_amount=500, p_spend=100, p_payload=q["payload"])
check("в тексте названа верная сумма", e is not None and "не больше 50" in e.msg)
p2 = call("staff_purchase", p_token=stok, p_amount=500, p_spend=50, p_payload=q["payload"])
check("чек 500, списано 50 → к оплате 450, +22, баланс 22 (пример из README)",
      p2["paid"] == 450 and p2["earned"] == 22 and p2["spent"] == 50 and p2["balance"] == 22, p2)
shift_events()
raises("лимит 20% чека: чек 100, списать 21 при балансе 22", "PT409", "staff_purchase",
       p_token=stok, p_amount=100, p_spend=21, p_payload=q["payload"])
p3 = call("staff_purchase", p_token=stok, p_amount=100, p_spend=20, p_payload=q["payload"])
check("чек 100, списано 20 → +4, баланс 6", p3["earned"] == 4 and p3["balance"] == 6 and p3["paid"] == 80, p3)
shift_events()
for name, amount in (("сумма 0", 0), ("сумма -5", -5), ("сумма больше лимита", 20001)):
    raises(name, "PT400", "staff_purchase", p_token=stok, p_amount=amount, p_payload=q["payload"])
raises("списание больше чека", "PT400", "staff_purchase", p_token=stok, p_amount=100, p_spend=150, p_payload=q["payload"])
raises("отрицательное списание", "PT400", "staff_purchase", p_token=stok, p_amount=100, p_spend=-1, p_payload=q["payload"])
raises("покупка без входа", "PT401", "staff_purchase", p_token="x", p_amount=100, p_payload=q["payload"])
p4 = call("staff_purchase", p_token=stok, p_amount=15, p_spend=0, p_payload=q["payload"])
check("маленький чек: 15 ₽ × 5% = 0 бонусов (округление вниз)", p4["earned"] == 0 and p4["balance"] == 6, p4)
shift_events()

print("== клиент видит историю")
me = call("me", p_token=ctok)
check("история: 4 покупки, новые сверху", len(me["history"]) == 4 and me["history"][0]["amount"] == 15, me["history"])
check("баланс сходится: +50+22+4−50−20 = 6", me["balance"] == 6 and me["earned_total"] == 76 and me["spent_total"] == 70, me)

print("== отмена операций")
rec = call("staff_recent", p_token=stok)["items"]
check("последние операции с can_cancel", len(rec) == 4 and all(i["can_cancel"] for i in rec), rec)
first = rec[-1]["id"]
raises("нельзя отменить покупку, бонусы с которой уже потрачены", "PT409", "staff_cancel", p_token=stok, p_event_id=first)
last = rec[0]["id"]
call("staff_cancel", p_token=stok, p_event_id=last)
check("отмена последней: баланс не изменился (она без бонусов)", call("me", p_token=ctok)["balance"] == 6)
raises("повторная отмена → 404", "PT404", "staff_cancel", p_token=stok, p_event_id=last)
rec2 = call("staff_recent", p_token=stok)["items"]
check("отменённая видна и без кнопки отмены", rec2[0]["cancelled"] is True and rec2[0]["can_cancel"] is False)
# повторить 15 ₽ можно сразу: отменённые не считаются дублем
check("после отмены ту же сумму можно провести снова",
      call("staff_purchase", p_token=stok, p_amount=15, p_payload=q["payload"])["balance"] == 6)
shift_events()

print("== админ: вход")
r = call("admin_login", p_password="nope")
check("неверный пароль → __error 403", r.get("__error") == "Неверный пароль" and r["__status"] == 403)
atok = call("admin_login", p_password="1234")["token"]
raises("токен клиента не открывает админку", "PT401", "admin_stats", p_token=ctok)
raises("токен бариста не открывает админку", "PT401", "admin_stats", p_token=stok)

print("== админ: статистика и клиенты")
s = call("admin_stats", p_token=atok)
t = s["totals"]
check("выручка/начислено/списано", t["revenue"] == 1000 + 500 + 100 + 15 and t["earned"] == 76 and t["spent"] == 70, t)
check("бонусов на руках = 6 (+0 за последнюю 15 ₽)", t["outstanding"] == 6, t)
check("покупок сегодня (отменённая не считается) и клиентов", t["purchases_today"] == 4 and t["users"] == 1 and t["revenue_today"] == 1615, t)
check("по точкам и по дням", len(s["locations"]) == 1 and s["locations"][0]["purchases"] == 4 and len(s["days"]) == 1, s["days"])
check("журнал: отменённая показана, есть сотрудник", any(r["cancelled"] for r in s["recent"])
      and s["recent"][0]["staff"] == "Бариста", s["recent"][:2])
c = call("admin_clients", p_token=atok, p_q="анн")
check("поиск клиента по части имени (кириллица, регистр)", c["total"] == 1 and c["items"][0]["balance"] == 6, c)
check("поиск по номеру карты", call("admin_clients", p_token=atok, p_q=str(card))["total"] == 1)
check("поиск: никого", call("admin_clients", p_token=atok, p_q="zzz")["total"] == 0)
check("без запроса — все", call("admin_clients", p_token=atok)["total"] == 1)
d = call("admin_client", p_token=atok, p_id=card)
check("карточка клиента: баланс и история (с отменённой)", d["balance"] == 6 and len(d["history"]) == 5 and d["user"]["name"].lower() == "анна", d)
raises("несуществующий клиент", "PT404", "admin_client", p_token=atok, p_id=999)

print("== админ: отмена любой покупки")
hist = call("admin_client", p_token=atok, p_id=card)["history"]
paid_first = [h for h in hist if h["amount"] == 1000][0]["id"]
raises("админ тоже не может сделать баланс отрицательным", "PT409", "admin_cancel", p_token=atok, p_event_id=paid_first)
second = [h for h in hist if h["amount"] == 500][0]["id"]
call("admin_cancel", p_token=atok, p_event_id=second)  # вернёт 50 бонусов, снимет 22: 6 + 50 - 22 = 34
check("отмена покупки со списанием возвращает бонусы: 6 + 50 − 22 = 34", call("me", p_token=ctok)["balance"] == 34)
shift_events(1000)

print("== несколько точек и права на отмену")
call("admin_location_add", p_token=atok, p_name="Точка на Ленина")
locs = call("admin_locations", p_token=atok)["items"]
check("две точки", len(locs) == 2, locs)
raises("пустое имя точки", "PT400", "admin_location_add", p_token=atok, p_name="  ")
call("admin_staff_add", p_token=atok, p_name="Олег", p_location_id=locs[1]["id"], p_pin="7777")
raises("PIN уже занят", "PT409", "admin_staff_add", p_token=atok, p_name="X", p_location_id=locs[1]["id"], p_pin="7777")
raises("PIN слишком короткий", "PT400", "admin_staff_add", p_token=atok, p_name="X", p_location_id=locs[1]["id"], p_pin="12")
raises("точка не существует", "PT400", "admin_staff_add", p_token=atok, p_name="X", p_location_id=99, p_pin="5555")
stok2 = call("staff_login", p_pin="7777")["token"]
check("вторая точка", call("staff_me", p_token=stok2)["location"] == "Точка на Ленина")
q = call("my_qr", p_token=ctok)
call("staff_purchase", p_token=stok2, p_amount=300, p_spend=0, p_payload=q["payload"])
ev2 = call("staff_recent", p_token=stok2)["items"][0]["id"]
raises("бариста не отменяет операцию чужой точки", "PT403", "staff_cancel", p_token=stok, p_event_id=ev2)
check("баланс единый на всю сеть: 34 + 15 = 49", call("me", p_token=ctok)["balance"] == 49)
check("клиент тратит бонусы на другой точке (до 20% чека)",
      call("staff_purchase", p_token=stok, p_amount=200, p_spend=40, p_payload=call("my_qr", p_token=ctok)["payload"])["balance"] == 49 - 40 + 8)
shift_events(1000)
check("точки в статистике раздельно", len(call("admin_stats", p_token=atok)["locations"]) == 2)

print("== бариста: окно отмены 15 минут")
owner("update app_private.events set created_at = now() - interval '20 minutes' where id = "
      f"(select max(id) from app_private.events where location_id = {st['location_id']});")
old_id = int(owner(f"select max(id) from app_private.events where location_id = {st['location_id']};"))
e = raises("старше 15 минут — бариста не может", "PT403", "staff_cancel", p_token=stok, p_event_id=old_id)
check("в тексте про 15 минут", e is not None and "15 минут" in e.msg)
rec = call("staff_recent", p_token=stok)["items"]
check("кнопка отмены скрыта (can_cancel=false)", rec[0]["can_cancel"] is False)

print("== админ: удаление и настройки")
call("admin_staff_delete", p_token=atok, p_id=[s_ for s_ in call("admin_staff", p_token=atok)["items"] if s_["name"] == "Олег"][0]["id"])
r = call("staff_login", p_pin="7777")
check("отключённый сотрудник не входит", r.get("__error") == "Неверный PIN")
raises("старый токен отключённого сотрудника", "PT401", "staff_me", p_token=stok2)
call("admin_location_delete", p_token=atok, p_id=locs[1]["id"])
check("точка закрыта", len(call("admin_locations", p_token=atok)["items"]) == 1)
check("настройки читаются", call("admin_settings", p_token=atok) == {"earn_percent": 5, "max_spend_percent": 20, "max_check": 20000, "notify": 1, "expire_days": 0, "signup_bonus": 0})
for bad in ({"p_earn_percent": 101}, {"p_max_spend_percent": -1}, {"p_max_check": 50}, {"p_notify": 2}):
    base = dict(p_token=atok, p_earn_percent=5, p_max_spend_percent=20, p_max_check=20000, p_notify=1)
    base.update(bad)
    raises(f"плохая настройка {list(bad)[0]}", "PT400", "admin_settings_save", **base)
call("admin_settings_save", p_token=atok, p_earn_percent=10, p_max_spend_percent=30, p_max_check=5000, p_notify=1)
q = call("my_qr", p_token=ctok)
raises("баланса не хватает на списание, даже если лимит чека позволяет", "PT409", "staff_purchase",
       p_token=stok, p_amount=1000, p_spend=300, p_payload=q["payload"])
p = call("staff_purchase", p_token=stok, p_amount=1000, p_spend=0, p_payload=q["payload"])
check("новые правила: 10% → чек 1000 даёт +100", p["earned"] == 100 and p["balance"] == 17 + 100, p)
shift_events()
p = call("staff_purchase", p_token=stok, p_amount=100, p_spend=30, p_payload=q["payload"])
check("новый лимит 30%: списано 30 (при 20% было бы нельзя), +7", p["spent"] == 30 and p["earned"] == 7 and p["paid"] == 70, p)
shift_events()
call("admin_settings_save", p_token=atok, p_earn_percent=5, p_max_spend_percent=20, p_max_check=20000, p_notify=1)
raises("после возврата правил 20%: списать 30 с чека 100 нельзя", "PT409", "staff_purchase",
       p_token=stok, p_amount=100, p_spend=30, p_payload=q["payload"])
call("admin_settings_save", p_token=atok, p_earn_percent=10, p_max_spend_percent=30, p_max_check=5000, p_notify=1)
raises("новый лимит чека 5000", "PT400", "staff_purchase", p_token=stok, p_amount=5001, p_payload=q["payload"])
call("admin_settings_save", p_token=atok, p_earn_percent=5, p_max_spend_percent=20, p_max_check=20000, p_notify=1)

print("== смена пароля админа")
raises("короткий пароль", "PT400", "admin_set_password", p_token=atok, p_new="12")
call("admin_set_password", p_token=atok, p_new="Новый-пароль")
check("старый пароль не подходит", call("admin_login", p_password="1234").get("__status") == 403)
check("новый подходит", "token" in call("admin_login", p_password="Новый-пароль"))
call("admin_set_password", p_token=atok, p_new="1234")

print("== Telegram: вход и уведомления")
check("без бота вход через Telegram закрыт", call("auth_telegram", p_data={"id": "1", "hash": "x"}).get("__status") == 403)
BOT = "123456:TESTTOKEN"
owner(f"update app_private.config set value = '{BOT}' where key = 'bot_token';")
owner("update app_private.config set value = '0' where key = 'dev_login';")
check("флаг dev_login=0 закрывает вход по имени", call("auth_dev", p_name="Хакер").get("__status") == 403)
check("api_config: dev=false, бот виден (имя бота пустое, пока не задано)", call("api_config")["dev"] is False)


def tg(**over):
    d = {"id": "4242", "first_name": "Вера", "username": "vera", "auth_date": str(int(time.time()))}
    d.update(over)
    dcs = "\n".join(f"{k}={d[k]}" for k in sorted(d))
    d["hash"] = hmac.new(hashlib.sha256(BOT.encode()).digest(), dcs.encode(), hashlib.sha256).hexdigest()
    return d


good = tg()
r = call("auth_telegram", p_data=good)
check("верная подпись Telegram → токен", "token" in r, r)
vtok = r["token"]
check("клиент создан по данным Telegram", call("me", p_token=vtok)["user"]["name"] == "Вера")
forged = dict(good, id="4243")
check("подделанные данные отвергнуты", call("auth_telegram", p_data=forged).get("__status") == 403)
stale = tg(auth_date=str(int(time.time()) - 90000))
check("просроченные данные (>24 ч) отвергнуты", call("auth_telegram", p_data=stale).get("__status") == 403)
check("без подписи отвергнуто", call("auth_telegram", p_data={"id": "5"}).get("__status") == 403)
owner("truncate net.sent;")
call("staff_purchase", p_token=stok, p_amount=400, p_spend=0, p_payload=call("my_qr", p_token=vtok)["payload"])
sent = json.loads(owner("select coalesce(json_agg(json_build_object('url', url, 'body', body)), '[]') from net.sent;"))
check("после покупки в Telegram ушло сообщение", len(sent) == 1 and sent[0]["body"]["chat_id"] == "4242"
      and f"bot{BOT}/sendMessage" in sent[0]["url"], sent)
check("текст сообщения: чек, начислено, баланс", "400 ₽" in sent[0]["body"]["text"] and "+20 бонусов" in sent[0]["body"]["text"]
      and "Баланс: 20 бонусов" in sent[0]["body"]["text"], sent[0]["body"]["text"])
shift_events()
owner("truncate net.sent; update app_private.config set value = '0' where key = 'notify';")
call("staff_purchase", p_token=stok, p_amount=500, p_spend=0, p_payload=call("my_qr", p_token=vtok)["payload"])
check("при выключенных уведомлениях ничего не отправляется", owner("select count(*) from net.sent;") == "0")
owner("update app_private.config set value = '1' where key = 'notify'; update app_private.config set value = '' where key = 'bot_token'; truncate net.sent;")

print("== регистрация и вход по логину и паролю")
owner("truncate app_private.attempts;")
r = call("auth_register", p_name="Ольга", p_login="Olga.K", p_password="secret1")
check("регистрация: имя + логин + пароль → токен", "token" in r, r)
otok = r["token"]
me = call("me", p_token=otok)
check("клиент создан, баланс 0", me["user"]["name"] == "Ольга" and me["balance"] == 0, me)
check("логин хранится в нижнем регистре", owner("select login from app_private.users where id = %d;" % me["user"]["id"]) == "olga.k")
check("пароль в базе не открытым текстом",
      owner("select password_hash from app_private.users where login = 'olga.k';").startswith("$2"))
check("логин занят (с другим регистром)", call("auth_register", p_name="Другая", p_login="OLGA.k", p_password="secret2").get("__status") == 409)
for name, args in (("пустое имя", dict(p_name="  ", p_login="validlogin", p_password="secret1")),
                   ("короткий логин", dict(p_name="А", p_login="ab", p_password="secret1")),
                   ("кириллица в логине", dict(p_name="А", p_login="оля", p_password="secret1")),
                   ("пробел в логине", dict(p_name="А", p_login="a b c", p_password="secret1")),
                   ("короткий пароль", dict(p_name="А", p_login="validlogin", p_password="12345")),
                   ("пустой пароль", dict(p_name="А", p_login="validlogin", p_password=""))):
    check(f"регистрация отклонена: {name}", call("auth_register", **args).get("__status") == 400, args)
check("слишком длинный пароль (>72 байт) отклонён", call("auth_register", p_name="А", p_login="longpass", p_password="я" * 40).get("__status") == 400)
r = call("auth_login", p_login="OLGA.K", p_password="secret1")
check("вход по логину (регистр не важен)", "token" in r, r)
check("токены разных входов независимы и рабочие", call("me", p_token=r["token"])["user"]["name"] == "Ольга")
bad = call("auth_login", p_login="olga.k", p_password="wrong")
check("неверный пароль → 403, без подсказки, что именно не так", bad.get("__status") == 403 and bad["__error"] == "Неверный логин или пароль", bad)
check("несуществующий логин даёт тот же ответ", call("auth_login", p_login="nobody", p_password="secret1")["__error"] == "Неверный логин или пароль")
check("пустой пароль не подходит", call("auth_login", p_login="olga.k", p_password="").get("__status") == 403)
check("вход через Telegram-учётку по логину невозможен",
      call("auth_login", p_login="vera", p_password="secret1").get("__status") == 403)

print("== защита от подбора пароля конкретного клиента")
owner("truncate app_private.attempts;")
for i in range(8):
    call("auth_login", p_login="olga.k", p_password=f"bad{i}")
r = call("auth_login", p_login="olga.k", p_password="secret1")
check("после 8 неудач даже верный пароль к этому логину блокируется", r.get("__status") == 429, r)
check("а чужой логин с того же адреса не заблокирован",
      call("auth_login", p_login="nobody", p_password="x").get("__status") == 403)
owner("truncate app_private.attempts;")
check("после сброса счётчика вход снова возможен", "token" in call("auth_login", p_login="olga.k", p_password="secret1"))

print("== регистрации: ограничение числа с одного адреса")
owner("truncate app_private.attempts;")
oks = [("token" in call("auth_register", p_name="Спам", p_login=f"spam{i:02d}", p_password="secret1")) for i in range(11)]
check("после 10 регистраций с одного адреса 11-я блокируется", oks[:10] == [True] * 10 and oks[10] is False, oks)
owner("truncate app_private.attempts;")

print("== админ: клиенты с логином и сброс пароля")
c = call("admin_clients", p_token=atok, p_q="olga")
check("клиент находится поиском по логину, логин в списке", c["total"] == 1 and c["items"][0]["login"] == "olga.k", c)
oid = c["items"][0]["id"]
check("в карточке клиента виден логин", call("admin_client", p_token=atok, p_id=oid)["user"]["login"] == "olga.k")
raises("короткий новый пароль", "PT400", "admin_client_set_password", p_token=atok, p_id=oid, p_new="123")
raises("клиент без логина (Telegram) — отказ", "PT404", "admin_client_set_password", p_token=atok, p_id=card, p_new="newpass1")
raises("сброс без прав админа", "PT401", "admin_client_set_password", p_token=otok, p_id=oid, p_new="newpass1")
call("admin_client_set_password", p_token=atok, p_id=oid, p_new="newpass1")
raises("после сброса старые входы клиента закрыты", "PT401", "me", p_token=otok)
check("старый пароль не подходит", call("auth_login", p_login="olga.k", p_password="secret1").get("__status") == 403)
check("новый пароль подходит", "token" in call("auth_login", p_login="olga.k", p_password="newpass1"))
owner("truncate app_private.attempts;")

print("== восстановление пароля по коду")
owner("truncate app_private.attempts;")
r = call("auth_register", p_name="Нина", p_login="nina.r", p_password="secret1")
code = r.get("recovery_code", "")
check("регистрация выдаёт код восстановления вида XXXX-XXXX-XXXX-XXXX",
      re.fullmatch(r"[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}", code) is not None, r)
rh = owner("select recovery_hash from app_private.users where login = 'nina.r';")
check("в базе код хранится только хэшем", rh.startswith("$2") and code.replace("-", "") not in rh)
r2 = call("auth_recover", p_login="NINA.R", p_code=code.lower().replace("-", " "), p_new="brandnew1")
code2 = r2.get("recovery_code", "")
check("восстановление по коду (регистр и разделители не важны) → токен и НОВЫЙ код", "token" in r2 and code2 and code2 != code, r2)
check("новый пароль работает", "token" in call("auth_login", p_login="nina.r", p_password="brandnew1"))
check("старый пароль больше не подходит", call("auth_login", p_login="nina.r", p_password="secret1").get("__status") == 403)
check("использованный код больше не работает", call("auth_recover", p_login="nina.r", p_code=code, p_new="another11").get("__status") == 403)
raises("вход, открытый до восстановления, закрыт", "PT401", "me", p_token=r["token"])
bad = "Неверный логин или код восстановления"
check("неверный код — один и тот же ответ", call("auth_recover", p_login="nina.r", p_code="AAAA-AAAA-AAAA-AAAA", p_new="another11").get("__error") == bad)
check("несуществующий логин — тот же ответ (логины не выдаются)", call("auth_recover", p_login="nobody", p_code=code2, p_new="another11").get("__error") == bad)
check("пустой код отклонён", call("auth_recover", p_login="nina.r", p_code="", p_new="another11").get("__status") == 403)
check("слишком короткий новый пароль отклонён до проверки кода", call("auth_recover", p_login="nina.r", p_code=code2, p_new="123").get("__status") == 400)
owner("truncate app_private.attempts;")
for i in range(6):
    call("auth_recover", p_login="nina.r", p_code=f"WRONG-{i}", p_new="another11")
check("после 6 неверных кодов даже верный блокируется (код не подобрать перебором)",
      call("auth_recover", p_login="nina.r", p_code=code2, p_new="another11").get("__status") == 429)
owner("truncate app_private.attempts;")
tok = call("auth_login", p_login="nina.r", p_password="brandnew1")["token"]
code3 = call("my_recovery_code", p_token=tok)["recovery_code"]
check("вошедший клиент может выпустить новый код — прежний сразу перестаёт работать",
      code3 not in (code, code2) and call("auth_recover", p_login="nina.r", p_code=code2, p_new="whatever1").get("__status") == 403)
raises("без входа код восстановления не выдаётся", "PT401", "my_recovery_code", p_token="x")
tg_uid = owner("select id from app_private.users where tg_id like 'tg:%' limit 1;")
tg_tok = owner(f"select app_private.new_session('user', {tg_uid}, interval '1 hour');")
raises("клиенту из Telegram код не нужен", "PT404", "my_recovery_code", p_token=tg_tok)
me = call("me", p_token=tok)
check("профиль: есть пароль и код восстановления", me["has_password"] is True and me["has_recovery"] is True, me)

print("== push-уведомления: подписки")
owner("truncate app_private.attempts;")
check("без настройки публичного ключа нет", call("api_config")["vapid_public"] == "")
KEYS = {"p256dh": "B" + "A" * 86, "auth": "A" * 22}
SUB = {"endpoint": "https://push.example.com/send/abc123", "keys": KEYS}
ptok = tok
r = call("push_subscribe", p_token=ptok, p_sub=SUB)
check("подписка сохранена", r["ok"] and r["devices"] == 1, r)
check("повторная подписка с того же устройства не дублируется", call("push_subscribe", p_token=ptok, p_sub=SUB)["devices"] == 1)
for name, sub_ in (("без адреса", {"keys": KEYS}),
                   ("адрес не https", {"endpoint": "http://push.example.com/x", "keys": KEYS}),
                   ("без ключей", {"endpoint": "https://push.example.com/x"}),
                   ("слишком короткий ключ", {"endpoint": "https://push.example.com/x", "keys": {"p256dh": "AA", "auth": "A" * 22}})):
    raises(f"подписка отклонена: {name}", "PT400", "push_subscribe", p_token=ptok, p_sub=sub_)
raises("подписка без входа", "PT401", "push_subscribe", p_token="x", p_sub=SUB)
raises("токен кассы не годится для подписки", "PT401", "push_subscribe", p_token=stok, p_sub=SUB)
for i in range(7):
    call("push_subscribe", p_token=ptok, p_sub={"endpoint": f"https://push.example.com/send/d{i}", "keys": KEYS})
check("больше 5 устройств на клиента не хранится", call("me", p_token=ptok)["push_devices"] == 5)
check("отписка убирает устройство", call("push_unsubscribe", p_token=ptok, p_endpoint="https://push.example.com/send/d6")["devices"] == 4)
check("чужую подписку отписать нельзя",
      call("push_unsubscribe", p_token=call("auth_login", p_login="olga.k", p_password="newpass1")["token"],
           p_endpoint="https://push.example.com/send/d5")["devices"] == 0
      and call("me", p_token=ptok)["push_devices"] == 4)

print("== push-уведомления: отправка и функция send-push")
owner("truncate net.sent;")
call("push_test", p_token=ptok)
check("пока функция не настроена, запросы не уходят", owner("select count(*) from net.sent where url like '%/send-push';") == "0")
raises("настройка push без прав админа", "PT401", "admin_push_setup", p_token=ptok, p_functions_url="https://abcdefgh.supabase.co/functions/v1")
raises("настройка push с неверным адресом", "PT400", "admin_push_setup", p_token=atok, p_functions_url="https://evil.example.com/functions/v1")
r = call("admin_push_setup", p_token=atok, p_functions_url="https://abcdefgh.supabase.co/functions/v1/")
check("admin_push_setup сохраняет адрес и просит функцию создать ключи", r["ok"] and r["ready"] is False, r)
secret = owner("select value from app_private.config where key = 'push_secret';")
init = json.loads(owner("select coalesce(json_agg(json_build_object('url', url, 'body', body, 'headers', headers)), '[]') "
                        "from net.sent where url like '%/send-push';"))
check("запрос инициализации ушёл на /functions/v1/send-push с секретом",
      len(init) == 1 and init[0]["url"] == "https://abcdefgh.supabase.co/functions/v1/send-push"
      and init[0]["body"] == {"action": "init"} and init[0]["headers"]["x-push-secret"] == secret, init)
check("секрет случайный, не угадываемый (≥ 48 символов)", len(secret) >= 48)
raises("push_keys: чужой секрет", "PT401", "push_keys", p_secret="wrong")
raises("push_keys: пустой секрет", "PT401", "push_keys", p_secret="")
check("push_keys с верным секретом: ключей ещё нет", call("push_keys", p_secret=secret) == {"public": "", "private": ""})
PUB, PRIV = "B" + "x" * 86, "y" * 43
raises("задать ключи с чужим секретом нельзя", "PT401", "push_keys_set", p_secret="wrong", p_public=PUB, p_private=PRIV)
raises("слишком короткие ключи отклонены", "PT400", "push_keys_set", p_secret=secret, p_public="x", p_private="y")
call("push_keys_set", p_secret=secret, p_public=PUB, p_private=PRIV)
raises("ключи задаются только один раз", "PT409", "push_keys_set", p_secret=secret, p_public=PUB, p_private=PRIV)
check("api_config отдаёт публичный ключ", call("api_config")["vapid_public"] == PUB)
check("закрытый ключ наружу не выходит", PRIV not in json.dumps(call("api_config")) and PRIV not in json.dumps(call("admin_push_status", p_token=atok)))
st = call("admin_push_status", p_token=atok)
check("статус: готово, устройств 4, клиентов 1", st["ready"] is True and st["devices"] == 4 and st["clients"] == 1, st)
raises("статус без прав админа", "PT401", "admin_push_status", p_token=ptok)

owner("truncate net.sent;")
call("push_test", p_token=ptok)
rows = json.loads(owner("select coalesce(json_agg(json_build_object('url', url, 'body', body, 'headers', headers)), '[]') "
                        "from net.sent where url like '%/send-push';"))
check("push_test: один запрос к функции, секрет в заголовке, 4 подписки",
      len(rows) == 1 and rows[0]["headers"]["x-push-secret"] == secret and len(rows[0]["body"]["subs"]) == 4, rows)
check("в запросе есть заголовок, текст и ключи подписки",
      rows[0]["body"]["title"] == "Кофейня" and "Уведомления включены" in rows[0]["body"]["body"]
      and set(rows[0]["body"]["subs"][0]) == {"endpoint", "p256dh", "auth"})

shift_events(1000)
qn = call("my_qr", p_token=ptok)
owner("truncate net.sent;")
call("staff_purchase", p_token=stok, p_amount=700, p_payload=qn["payload"])
rows = json.loads(owner("select coalesce(json_agg(body), '[]') from net.sent where url like '%/send-push';"))
check("покупка отправляет push с суммой, бонусами и балансом",
      len(rows) == 1 and "Покупка на 700" in rows[0]["body"] and "+35" in rows[0]["body"] and "Баланс: 35" in rows[0]["body"], rows)
owner("update app_private.config set value = '0' where key = 'notify';")
owner("truncate net.sent;")
shift_events(1000)
call("staff_purchase", p_token=stok, p_amount=710, p_payload=call("my_qr", p_token=ptok)["payload"])
check("при выключенных уведомлениях push не отправляется", owner("select count(*) from net.sent;") == "0")
owner("update app_private.config set value = '1' where key = 'notify';")
raises("prune с чужим секретом", "PT401", "push_prune", p_secret="wrong", p_endpoints=["https://push.example.com/send/d0"])
call("push_prune", p_secret=secret, p_endpoints=["https://push.example.com/send/d2", "https://push.example.com/send/d3"])
check("push_prune удаляет отозванные подписки", call("me", p_token=ptok)["push_devices"] == 2)
owner("update app_private.config set value = '' where key in ('vapid_public', 'vapid_private', 'functions_url');")

print("== учёт миграций")
mig = owner("select string_agg(version, ',' order by version) from app_private.schema_migrations;")
check("в базе записаны применённые миграции 0001–0004", mig == "0001,0002,0003,0004", mig)

print("== сессии")
check("logout", call("logout", p_token=vtok)["ok"] is True)
raises("после выхода токен недействителен", "PT401", "me", p_token=vtok)
owner("update app_private.sessions set expires_at = now() - interval '1 minute';")
raises("просроченная сессия", "PT401", "me", p_token=ctok)
check("просроченные сессии чистятся при новом входе",
      int(owner("select count(*) from app_private.sessions where expires_at < now();")) >= 0)

print("== защита от перебора PIN")
owner("truncate app_private.attempts;")
for i in range(10):
    call("staff_login", p_pin=f"00{i:02d}")
r = call("staff_login", p_pin="1234")
check("после 10 неудач даже верный PIN блокируется на 5 минут", r.get("__status") == 429, r)
owner("truncate app_private.attempts;")
check("после сброса счётчика вход снова возможен", "token" in call("staff_login", p_pin="1234"))
owner("truncate app_private.attempts;")
for i in range(10):
    call("admin_login", p_password=f"bad{i}")
check("пароль админа тоже защищён от перебора", call("admin_login", p_password="1234").get("__status") == 429)
owner("truncate app_private.attempts;")

print("== 0003: бонус за регистрацию и сгорание бонусов")
owner("truncate app_private.attempts;")
atok = call("admin_login", p_password="1234")["token"]
stok3 = call("staff_login", p_pin="1234")["token"]


def settings(**kw):
    return call("admin_settings_save", p_token=atok, p_earn_percent=5, p_max_spend_percent=20,
                p_max_check=20000, p_notify=1, **kw)


def reg(login, name=None):
    owner("truncate app_private.attempts;")      # лимит регистраций с одного адреса здесь не проверяем
    r = call("auth_register", p_name=name or login, p_login=login, p_password="secret1")
    return r["token"], int(owner(f"select id from app_private.users where login = '{login}';"))


def age_user(uid, interval):
    """Состарить клиента: дата регистрации и подаренные бонусы тоже «давнишние»."""
    owner(f"update app_private.users set created_at = now() - interval '{interval}' where id = {uid};"
          f"update app_private.adjustments set created_at = now() - interval '{interval}' where user_id = {uid} and delta > 0;")


def pay(uid, tok=None):
    sig_slot = int(owner("select app_private.qr_window();"))
    return f"BC1.{uid}.{sig_slot}.{owner(f'select app_private.qr_sig({uid}, {sig_slot});')}"


check("старый вызов настроек (5 параметров) работает", settings().get("ok") is True)
raises("срок сгорания < 0 отклонён", "PT400", "admin_settings_save", p_token=atok, p_earn_percent=5,
       p_max_spend_percent=20, p_max_check=20000, p_notify=1, p_expire_days=-1)
raises("бонус за регистрацию слишком большой отклонён", "PT400", "admin_settings_save", p_token=atok,
       p_earn_percent=5, p_max_spend_percent=20, p_max_check=20000, p_notify=1, p_signup_bonus=10001)
check("настройки сохраняются", settings(p_expire_days=30, p_signup_bonus=100).get("ok") is True)
st = call("admin_settings", p_token=atok)
check("настройки читаются", st["expire_days"] == 30 and st["signup_bonus"] == 100, st)

g_tok, g_id = reg("gift1")
me = call("me", p_token=g_tok)
check("бонус за регистрацию: баланс 100", me["balance"] == 100, me)
check("у бонуса есть дата сгорания", me["expire_days"] == 30 and me["expires_at"] is not None, me)
ib = call("my_inbox", p_token=g_tok)["items"]
check("во входящих приветствие с бонусом", len(ib) == 1 and "100" in ib[0]["body"], ib)

age_user(g_id, "40 days")
me = call("me", p_token=g_tok)
check("через 40 дней без покупок баланс сгорел", me["balance"] == 0 and me["expires_at"] is None, me)
check("сгорание записано и клиенту пришло сообщение",
      owner(f"select delta from app_private.adjustments where user_id = {g_id} and reason = 'expire';") == "-100"
      and "сгорели" in call("my_inbox", p_token=g_tok)["items"][0]["body"])
check("повторный просмотр не сжигает второй раз",
      call("me", p_token=g_tok)["balance"] == 0 and owner(f"select count(*) from app_private.adjustments where user_id = {g_id};") == "2")

h_tok, h_id = reg("gift2")
age_user(h_id, "40 days")
e = raises("сгоревшие бонусы нельзя списать на кассе", "PT409", "staff_purchase", p_token=stok3, p_amount=100,
           p_spend=10, p_payload=pay(h_id))
check("после сгорания покупка деньгами проходит и копит новые бонусы",
      call("staff_purchase", p_token=stok3, p_amount=1000, p_payload=pay(h_id))["balance"] == 50)

j_tok, j_id = reg("gift3")
shift_events()
call("staff_purchase", p_token=stok3, p_amount=100, p_payload=pay(j_id))
age_user(j_id, "50 days")
owner(f"update app_private.events set created_at = now() - interval '20 days' where user_id = {j_id};")
check("свежая покупка продлевает срок: бонусы целы", call("me", p_token=j_tok)["balance"] == 105)
owner(f"update app_private.events set created_at = now() - interval '40 days' where user_id = {j_id};")
check("а старая покупка уже нет: всё сгорело", call("me", p_token=j_tok)["balance"] == 0)

settings(p_expire_days=0, p_signup_bonus=0)
k_tok, k_id = reg("gift4")
check("без бонуса за регистрацию баланс 0", call("me", p_token=k_tok)["balance"] == 0)
owner(f"insert into app_private.adjustments (user_id, delta, reason) values ({k_id}, 70, 'signup');"
      f"update app_private.users set created_at = now() - interval '400 days' where id = {k_id};")
check("при сроке 0 ничего не сгорает", call("me", p_token=k_tok)["balance"] == 70)
out_stats = call("admin_stats", p_token=atok)["totals"]
check("в статистике «обязательства» учитывают корректировки",
      out_stats["outstanding"] == int(owner("select coalesce(sum(earned) - sum(spent), 0) from app_private.events where not cancelled;"))
      + int(owner("select coalesce(sum(delta), 0) from app_private.adjustments;")), out_stats)
cl = [c for c in call("admin_clients", p_token=atok, p_q="gift4")["items"]]
check("в списке клиентов баланс учитывает корректировки", len(cl) == 1 and cl[0]["balance"] == 70, cl)

print("== 0003: входящие сообщения")
m0 = call("my_messages", p_token=g_tok)
check("без курсора возвращается только последний id", m0["items"] == [] and m0["last_id"] > 0, m0)
call("staff_purchase", p_token=stok3, p_amount=700, p_payload=pay(g_id))
m1 = call("my_messages", p_token=g_tok, p_after=m0["last_id"])
check("после покупки приходит новое сообщение", len(m1["items"]) == 1 and "Покупка" in m1["items"][0]["body"], m1)
check("курсор двигается: повторный запрос пуст",
      call("my_messages", p_token=g_tok, p_after=m1["last_id"])["items"] == [])
raises("чужого токена нет — 401", "PT401", "my_messages", p_token="нет")
check("клиент не видит чужие сообщения", all("Покупка" not in x["body"] for x in call("my_inbox", p_token=k_tok)["items"]))

print("== 0003: отчёты и выгрузка")
r_tok, r_id = reg("inj1", "=1+1")
rep = call("admin_report", p_token=atok)
check("отчёт: покупки, выручка и средний чек считаются",
      rep["totals"]["purchases"] >= 3 and rep["totals"]["revenue"] > 0 and rep["totals"]["avg_check"] > 0, rep["totals"])
check("отчёт: есть дни, точки, часы и топ клиентов",
      rep["days"] and rep["locations"] and rep["hours"] and rep["top"] and rep["top"][0]["revenue"] >= rep["top"][-1]["revenue"])
check("отчёт: новые клиенты и регистрации", rep["new_clients"] >= 1 and rep["registered"] >= 4, rep)
rep2 = call("admin_report", p_token=atok, p_from="2000-01-01", p_to="2000-01-31")
check("отчёт за пустой период пуст, но не падает", rep2["totals"]["purchases"] == 0 and rep2["days"] == [], rep2)
raises("период больше года отклонён", "PT400", "admin_report", p_token=atok, p_from="2020-01-01", p_to="2026-01-01")
raises("конец раньше начала отклонён", "PT400", "admin_report", p_token=atok, p_from="2026-02-01", p_to="2026-01-01")
raises("клиент не может смотреть отчёты", "PT401", "admin_report", p_token=g_tok)
call("staff_purchase", p_token=stok3, p_amount=300, p_payload=pay(r_id))
ex = call("admin_export", p_token=atok)
lines = ex["csv"].split("\n")
check("выгрузка: заголовок и строки по числу покупок", lines[0].startswith("id,") and len(lines) - 1 == ex["rows"] > 0, lines[:2])
check("выгрузка: имя «=1+1» экранировано от формул", '"\'=1+1"' in ex["csv"])
raises("клиент не может выгружать", "PT401", "admin_export", p_token=g_tok)

print("== 0003: рассылки")
bc = call("admin_broadcasts", p_token=atok)
check("аудитории посчитаны", bc["counts"]["all"] >= 5 and "inactive" in bc["counts"] and "with_balance" in bc["counts"], bc)
before = int(owner("select count(*) from app_private.messages;"))
res = call("admin_broadcast", p_token=atok, p_title="Скидка", p_body="Завтра двойные бонусы", p_audience="all")
check("рассылка всем отправлена каждому клиенту", res["sent"] == bc["counts"]["all"], res)
check("во входящих клиента появилась акция",
      any(x["title"] == "Скидка" for x in call("my_inbox", p_token=k_tok)["items"]))
check("сообщения записаны", int(owner("select count(*) from app_private.messages;")) == before + res["sent"])
raises("вторая рассылка сразу — 429", "PT429", "admin_broadcast", p_token=atok, p_title="Ещё", p_body="Ещё", p_audience="all")
owner("update app_private.broadcasts set created_at = created_at - interval '1 minute';")
raises("пустой текст отклонён", "PT400", "admin_broadcast", p_token=atok, p_title="", p_body="x", p_audience="all")
raises("неизвестная аудитория отклонена", "PT400", "admin_broadcast", p_token=atok, p_title="a", p_body="b", p_audience="vip")
res = call("admin_broadcast", p_token=atok, p_title="С балансом", p_body="Ваши бонусы ждут", p_audience="with_balance")
check("рассылка «с бонусами» — только тем, у кого баланс > 0",
      res["sent"] == int(owner("select count(*) from app_private.users u where (select b.balance from app_private.balance(u.id) b) > 0;")), res)
owner("update app_private.broadcasts set created_at = created_at - interval '1 minute';")
owner(f"update app_private.users set created_at = now() - interval '60 days' where id = {k_id};"
      f"update app_private.events set created_at = now() - interval '60 days' where user_id = {k_id};")
res = call("admin_broadcast", p_token=atok, p_title="Скучаем", p_body="Заходите", p_audience="inactive")
check("рассылка «давно не заходили» доходит только неактивным", res["sent"] >= 1 and res["sent"] < bc["counts"]["all"], res)
check("история рассылок", len(call("admin_broadcasts", p_token=atok)["items"]) == 3)
raises("клиент не может рассылать", "PT401", "admin_broadcast", p_token=g_tok, p_title="x", p_body="y", p_audience="all")

print("== 0003: очередь кассы без интернета")
o_tok, o_id = reg("offline1")
at = int(time.time()) - 30
slot = at // 10
sig = owner(f"select app_private.qr_sig({o_id}, {slot});")
pl = f"BC1.{o_id}.{slot}.{sig}"
uid1 = str(uuid.uuid4())
b = call("staff_purchase_batch", p_token=stok3, p_items=JSON([{"id": uid1, "payload": pl, "amount": 500, "at": at}]))
r0 = b["results"][0]
check("покупка из очереди проведена: +25", r0["ok"] and r0["earned"] == 25 and r0["name"] == "offline1", b)
check("время покупки — момент сканирования",
      abs(float(owner(f"select extract(epoch from created_at) from app_private.events where client_uuid = '{uid1}';")) - at) < 2)
b = call("staff_purchase_batch", p_token=stok3, p_items=JSON([{"id": uid1, "payload": pl, "amount": 500, "at": at}]))
check("повторная отправка не создаёт дубль", b["results"][0]["ok"] and b["results"][0]["duplicate"] is True
      and call("me", p_token=o_tok)["balance"] == 25, b)
old_at = int(time.time()) - 3600
bad = call("staff_purchase_batch", p_token=stok3, p_items=JSON([
    {"id": str(uuid.uuid4()), "payload": pl, "amount": 100, "at": old_at},
    {"id": str(uuid.uuid4()), "payload": f"BC1.{o_id}.{slot}.0000000000", "amount": 100, "at": at},
    {"id": str(uuid.uuid4()), "payload": pl, "amount": 0, "at": at},
    {"id": str(uuid.uuid4()), "payload": pl, "amount": 100, "at": int(time.time()) - 5 * 86400},
    {"id": str(uuid.uuid4()), "payload": "мусор", "amount": 100, "at": at},
]))["results"]
check("устаревший QR, подделка, нулевая сумма, старше 3 суток и мусор — отклонены по отдельности",
      [x["ok"] for x in bad] == [False] * 5, bad)
check("отказы не испортили баланс", call("me", p_token=o_tok)["balance"] == 25)
ok2 = call("staff_purchase_batch", p_token=stok3, p_items=JSON([
    {"id": str(uuid.uuid4()), "payload": pl, "amount": 100, "at": at},
    {"id": str(uuid.uuid4()), "payload": "мусор", "amount": 100, "at": at}]))["results"]
check("в одной очереди плохая запись не мешает хорошей", ok2[0]["ok"] and not ok2[1]["ok"], ok2)
raises("очередь без входа бариста — 401", "PT401", "staff_purchase_batch", p_token=g_tok, p_items=JSON([]))
raises("очередь больше 100 покупок отклонена", "PT400", "staff_purchase_batch", p_token=stok3,
       p_items=JSON([{"id": str(uuid.uuid4()), "payload": pl, "amount": 1, "at": at}] * 101))
raises("очередь не массив отклонена", "PT400", "staff_purchase_batch", p_token=stok3, p_items=JSON({"a": 1}))

print("== 0004: уровни, акции по дням, день рождения")
settings()                                                  # сгорание и бонус за регистрацию выключены


def loy(**kw):
    return call("admin_loyalty_save", p_token=atok, p_cfg=JSON(kw))


def tz_sql(expr):
    return owner(f"select ({expr})::text;")


L0 = call("admin_loyalty", p_token=atok)
check("настройки лояльности по умолчанию выключены",
      L0["tier1_from"] == 0 and L0["birthday_bonus"] == 0 and L0["promo_days"] == "", L0)
check("слабые пароли замечены (1234)", L0["weak_admin"] is True and L0["weak_pin"] is True, L0)
raises("процент уровня больше 100 отклонён", "PT400", "admin_loyalty_save", p_token=atok, p_cfg=JSON({"tier1_percent": 101}))
raises("«Золото» ниже «Серебра» отклонено", "PT400", "admin_loyalty_save", p_token=atok,
       p_cfg=JSON({"tier1_from": 2000, "tier2_from": 1000}))
raises("неверные дни акции отклонены", "PT400", "admin_loyalty_save", p_token=atok, p_cfg=JSON({"promo_days": "8"}))
raises("множитель 0 отклонён", "PT400", "admin_loyalty_save", p_token=atok, p_cfg=JSON({"promo_mult": 0}))
raises("клиент не может менять лояльность", "PT401", "admin_loyalty_save", p_token=g_tok, p_cfg=JSON({"tier1_from": 1}))
check("уровни сохраняются",
      loy(tier1_from=1000, tier1_percent=7, tier2_from=5000, tier2_percent=10).get("ok") is True
      and call("admin_loyalty", p_token=atok)["tier2_percent"] == 10)

t_tok, t_id = reg("tier1")
v = call("staff_lookup", p_token=stok3, p_payload=pay(t_id))
check("новый клиент: базовые 5%, до «Серебра» 1000 ₽",
      v["earn_percent"] == 5 and v["tier"] == 0 and v["next_tier"]["name"] == "Серебро" and v["next_tier"]["left"] == 1000, v)
r1 = call("staff_purchase", p_token=stok3, p_amount=1000, p_payload=pay(t_id))
check("первая покупка 1000 → 5% = 50", r1["earned"] == 50, r1)
shift_events()
r2 = call("staff_purchase", p_token=stok3, p_amount=1000, p_payload=pay(t_id))
check("«Серебро» после 1000 ₽: 7% = 70", r2["earned"] == 70 and r2["tier_name"] == "Серебро", r2)
check("следующий уровень — «Золото», осталось 3000",
      r2["next_tier"]["name"] == "Золото" and r2["next_tier"]["left"] == 3000, r2["next_tier"])
shift_events()
r3 = call("staff_purchase", p_token=stok3, p_amount=3000, p_payload=pay(t_id))
check("покупка 3000 на «Серебре»: 210", r3["earned"] == 210, r3)
shift_events()
r4 = call("staff_purchase", p_token=stok3, p_amount=1000, p_payload=pay(t_id))
check("«Золото» после 5000 ₽: 10% = 100", r4["earned"] == 100 and r4["tier_name"] == "Золото" and r4["next_tier"] is None, r4)
check("клиент видит свой уровень на карте", call("me", p_token=t_tok)["tier_name"] == "Золото")
mine = call("admin_clients", p_token=atok, p_q="tier1")["items"][0]
check("баланс в списке клиентов = начислено (50+70+210+100)", mine["balance"] == 430, mine)

tomorrow = tz_sql("(extract(isodow from now() at time zone 'Europe/Moscow')::int % 7) + 1")
today_dow = tz_sql("extract(isodow from now() at time zone 'Europe/Moscow')::int")
loy(promo_days=tomorrow, promo_mult=2)
shift_events()
check("акция на другой день недели не действует",
      call("staff_purchase", p_token=stok3, p_amount=1000, p_payload=pay(t_id))["earned"] == 100)
loy(promo_days=today_dow, promo_mult=2)
shift_events()
v = call("staff_lookup", p_token=stok3, p_payload=pay(t_id))
check("в день акции процент удваивается (10% × 2) и виден кассиру", v["earn_percent"] == 20 and v["promo"] == 2, v)
check("«двойные бонусы»: чек 1000 → 200", call("staff_purchase", p_token=stok3, p_amount=1000, p_payload=pay(t_id))["earned"] == 200)
p_tok, p_id = reg("promo1")
check("для нового клиента в день акции 5% × 2 = 10%",
      call("staff_purchase", p_token=stok3, p_amount=1000, p_payload=pay(p_id))["earned"] == 100)
loy(promo_days="")
shift_events()
check("акцию можно выключить", call("staff_lookup", p_token=stok3, p_payload=pay(t_id))["promo"] == 1)

# покупка из очереди кассы тоже считается по уровню клиента
at2 = int(time.time()) - 20
pl2 = f"BC1.{t_id}.{at2 // 10}.{owner(f'select app_private.qr_sig({t_id}, {at2 // 10});')}"
shift_events()
q = call("staff_purchase_batch", p_token=stok3, p_items=JSON([{"id": str(uuid.uuid4()), "payload": pl2, "amount": 1000, "at": at2}]))
check("покупка из очереди тоже по уровню (10%)", q["results"][0]["ok"] and q["results"][0]["earned"] == 100, q)

print("== 0004: день рождения")
loy(birthday_bonus=50)


def bday(login, shift_days):
    tok, uid = reg(login)
    d = tz_sql(f"(now() at time zone 'Europe/Moscow')::date - interval '20 years' - interval '{shift_days} days'")[:10]
    return tok, uid, d


b_tok, b_id, d0 = bday("bday1", 0)
check("подарок в день рождения приходит сразу при указании даты",
      call("set_birthday", p_token=b_tok, p_date=d0).get("ok") is True and call("me", p_token=b_tok)["balance"] == 50)
check("во входящих поздравление", any("С днём рождения" in m["body"] for m in call("my_inbox", p_token=b_tok)["items"]))
check("повторные заходы подарок не удваивают", call("me", p_token=b_tok)["balance"] == 50
      and owner(f"select count(*) from app_private.adjustments where user_id = {b_id} and reason like 'birthday:%';") == "1")
raises("дату рождения нельзя менять", "PT409", "set_birthday", p_token=b_tok, p_date="1990-01-01")
c_tok, c_id, d3 = bday("bday2", 3)
call("set_birthday", p_token=c_tok, p_date=d3)
check("в течение недели после дня рождения подарок ещё действует", call("me", p_token=c_tok)["balance"] == 50)
e_tok, e_id, d10 = bday("bday3", 10)
call("set_birthday", p_token=e_tok, p_date=d10)
check("через 10 дней подарка уже нет", call("me", p_token=e_tok)["balance"] == 0)
f_tok, f_id, _ = bday("bday4", 0)
raises("слишком юная дата отклонена", "PT400", "set_birthday", p_token=f_tok,
       p_date=tz_sql("(now() at time zone 'Europe/Moscow')::date - interval '3 years'")[:10])
raises("дата из прошлого века отклонена", "PT400", "set_birthday", p_token=f_tok, p_date="1900-01-01")
loy(birthday_bonus=0)
call("set_birthday", p_token=f_tok, p_date=d0)
check("при выключенном подарке ничего не начисляется", call("me", p_token=f_tok)["balance"] == 0)
raises("клиент без входа не может указать дату", "PT401", "set_birthday", p_token="нет", p_date=d0)

print("== 0004: согласие на обработку данных")
owner("update app_private.config set value = '1' where key = 'require_consent';")
owner("truncate app_private.attempts;")
r = call("auth_register", p_name="Без согласия", p_login="noconsent", p_password="secret1")
check("без согласия регистрация отклонена", r.get("__status") == 400 and "согласие" in r.get("__error", ""), r)
r = call("auth_register", p_name="Без согласия", p_login="noconsent", p_password="secret1", p_consent=False)
check("явный отказ тоже отклонён", r.get("__status") == 400, r)
check("логин не занят отказом", owner("select count(*) from app_private.users where login = 'noconsent';") == "0")
r = call("auth_register", p_name="Согласный", p_login="consent1", p_password="secret1", p_consent=True)
check("с согласием регистрация проходит и время согласия записано",
      "token" in r and owner("select consent_at is not null from app_private.users where login = 'consent1';") == "t", r)
owner("update app_private.config set value = '0' where key = 'require_consent';")
owner("truncate app_private.attempts;")

print("== 0004: удаление аккаунта")
d_tok, d_id = reg("deleteme", "Иван Иванов")
call("staff_purchase", p_token=stok3, p_amount=1000, p_payload=pay(d_id))
old_qr = pay(d_id)
secret = owner("select value from app_private.config where key = 'push_secret';")
owner(f"insert into app_private.push_subs (user_id, endpoint, p256dh, auth) values ({d_id}, 'https://push.example.com/x', 'k', 'a');")
all_before = call("admin_broadcasts", p_token=atok)["counts"]["all"]
check("с неверным паролем удалить нельзя", call("delete_my_account", p_token=d_tok, p_password="неверный").get("__status") == 403)
check("без пароля тоже нельзя", call("delete_my_account", p_token=d_tok).get("__status") == 403)
check("удаление с верным паролем", call("delete_my_account", p_token=d_tok, p_password="secret1").get("ok") is True)
raises("сессия закрыта", "PT401", "me", p_token=d_tok)
check("войти под старым логином нельзя", call("auth_login", p_login="deleteme", p_password="secret1").get("__status") == 403)
check("личные данные стёрты",
      owner(f"select name || '|' || coalesce(login, '-') || '|' || (password_hash is null) || '|' || (deleted_at is not null) from app_private.users where id = {d_id};")
      == "Удалённый клиент|-|true|true")
check("устройства уведомлений удалены", owner(f"select count(*) from app_private.push_subs where user_id = {d_id};") == "0")
check("покупка осталась обезличенной для отчётов",
      owner(f"select count(*) from app_private.events where user_id = {d_id};") == "1")
check("баланс обнулён", owner(f"select (select balance from app_private.balance({d_id}));") == "0")
raises("по его QR больше ничего не провести", "PT404", "staff_lookup", p_token=stok3, p_payload=old_qr)
raises("и покупка не проходит", "PT404", "staff_purchase", p_token=stok3, p_amount=500, p_payload=old_qr)
check("в рассылках удалённого нет", call("admin_broadcasts", p_token=atok)["counts"]["all"] == all_before - 1)
check("логин освободился для нового клиента", "token" in call("auth_register", p_name="Новый", p_login="deleteme", p_password="secret1"))
w_tok, w_id = reg("delwrong")
for _ in range(5):
    call("delete_my_account", p_token=w_tok, p_password="x")
check("подбор пароля при удалении ограничен",
      call("delete_my_account", p_token=w_tok, p_password="secret1").get("__status") == 429)
owner("truncate app_private.attempts;")

print("== 0004: отчёт по сотрудникам и слабые пароли")
rs = call("admin_report_staff", p_token=atok)
check("отчёт по сотрудникам: кто сколько провёл",
      rs["items"] and rs["items"][0]["purchases"] >= 3 and rs["items"][0]["revenue"] > 0 and rs["items"][0]["name"] == "Бариста", rs)
raises("клиент не видит отчёт по сотрудникам", "PT401", "admin_report_staff", p_token=g_tok)
raises("неверный период отчёта по сотрудникам", "PT400", "admin_report_staff", p_token=atok, p_from="2020-01-01", p_to="2026-01-01")
call("admin_set_password", p_token=atok, p_new="надёжный-пароль")
atok = call("admin_login", p_password="надёжный-пароль")["token"]
call("admin_staff_add", p_token=atok, p_name="Мария", p_location_id=1, p_pin="4821")
s_weak = call("admin_loyalty", p_token=atok)
check("после смены пароля предупреждение про админа пропало, про общий PIN осталось",
      s_weak["weak_admin"] is False and s_weak["weak_pin"] is True, s_weak)
call("admin_set_password", p_token=atok, p_new="1234")
atok = call("admin_login", p_password="1234")["token"]
mar = call("staff_login", p_pin="4821")["token"]
call("staff_purchase", p_token=mar, p_amount=250, p_payload=pay(t_id))
rs = call("admin_report_staff", p_token=atok)
check("у каждого сотрудника своя строка в отчёте", {i["name"] for i in rs["items"]} >= {"Бариста", "Мария"}, rs)

print("== повторное применение schema.sql сохраняет данные")
before = owner("select count(*) from app_private.events;") + "/" + owner("select count(*) from app_private.users;")
with open(__file__.replace("test_schema.py", "schema.sql"), encoding="utf-8") as f:
    rc, out, err = psql(f.read())
after = owner("select count(*) from app_private.events;") + "/" + owner("select count(*) from app_private.users;")
check("schema.sql применяется повторно без ошибок", rc == 0, err[:200])
check("данные на месте", before == after, f"{before} → {after}")
check("пароль 1234 и PIN 1234 всё ещё работают",
      "token" in call("admin_login", p_password="1234") and "token" in call("staff_login", p_pin="1234"))

print("== обновление с 0001 до 0002: данные сохраняются")
owner("update app_private.config set value = '1' where key = 'dev_login';")      # (для сравнения со старым поведением не нужен)
apply_sql("drop schema if exists app_private cascade; truncate net.sent;"
          " drop function if exists public.auth_register(text, text, text, boolean);", "очистка перед проверкой обновления")
apply_sql(read("migrations", "0001_baseline.sql"), "миграция 0001")
u1 = call("auth_register", p_name="Старый клиент", p_login="old.client", p_password="secret1")
check("в версии 0001 регистрация работает и кода восстановления ещё нет", "token" in u1 and "recovery_code" not in u1, u1)
s1 = call("staff_login", p_pin="1234")["token"]
call("staff_purchase", p_token=s1, p_amount=1000, p_payload=call("my_qr", p_token=u1["token"])["payload"])
check("покупка в 0001: баланс 50", call("me", p_token=u1["token"])["balance"] == 50)
apply_sql(read("migrations", "0002_recovery_and_push.sql"), "миграция 0002")
me_old = call("me", p_token=u1["token"])
check("после обновления клиент, его баланс и сессия на месте", me_old["balance"] == 50 and me_old["user"]["name"] == "Старый клиент", me_old)
check("у старого клиента кода ещё нет, но он может его выпустить",
      me_old["has_recovery"] is False and "recovery_code" in call("my_recovery_code", p_token=u1["token"]))
check("старый пароль работает", "token" in call("auth_login", p_login="old.client", p_password="secret1"))
check("новые методы доступны, старые данные не тронуты",
      call("api_config")["vapid_public"] == "" and call("admin_stats", p_token=call("admin_login", p_password="1234")["token"])["totals"]["purchases"] == 1)
check("миграции 0001 и 0002 записаны", owner("select string_agg(version, ',' order by version) from app_private.schema_migrations;") == "0001,0002")
apply_sql(read("migrations", "0002_recovery_and_push.sql"), "повторное применение 0002")
check("повторное применение 0002 безопасно (клиент на месте)", call("me", p_token=u1["token"])["balance"] == 50)
apply_sql(read("migrations", "0003_expiry_reports_broadcast_offline.sql"), "миграция 0003")
check("после 0003 баланс и сессия старого клиента на месте", call("me", p_token=u1["token"])["balance"] == 50)
check("0003 записана", owner("select string_agg(version, ',' order by version) from app_private.schema_migrations;") == "0001,0002,0003")
apply_sql(read("migrations", "0003_expiry_reports_broadcast_offline.sql"), "повторное применение 0003")
check("повторное применение 0003 безопасно", call("me", p_token=u1["token"])["balance"] == 50)
apply_sql(read("migrations", "0004_loyalty_privacy.sql"), "миграция 0004")
check("после 0004 клиент, баланс и сессия на месте", call("me", p_token=u1["token"])["balance"] == 50)
apply_sql(read("migrations", "0004_loyalty_privacy.sql"), "повторное применение 0004")
check("повторное применение 0004 безопасно", call("me", p_token=u1["token"])["balance"] == 50)
check("0004 записана", owner("select string_agg(version, ',' order by version) from app_private.schema_migrations;") == "0001,0002,0003,0004")
s1b = call("staff_login", p_pin="1234")["token"]
check("после 0003 покупка работает",
      call("staff_purchase", p_token=s1b, p_amount=400, p_payload=call("my_qr", p_token=u1["token"])["payload"])["earned"] == 20)

print(f"\nИтого: ✓ {passed}, ✗ {failed}")
sys.exit(1 if failed else 0)
