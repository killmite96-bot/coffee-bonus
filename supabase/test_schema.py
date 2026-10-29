#!/usr/bin/env python3
"""Проверка supabase/schema.sql на локальном Postgres в Docker (контейнер coffee-pg-test).

Вызывает функции от роли anon — ровно так, как это делает сайт через Supabase REST.
Запуск: python supabase/test_schema.py
"""
import hashlib
import hmac
import io
import json
import re
import subprocess
import sys
import time

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
CONTAINER = "coffee-pg-test"
passed = failed = 0


def psql(sql):
    r = subprocess.run(["docker", "exec", "-i", CONTAINER, "psql", "-U", "postgres", "-At",
                        "-v", "VERBOSITY=verbose", "-v", "ON_ERROR_STOP=1"],
                       input=sql.encode("utf-8"), capture_output=True)
    return r.returncode, r.stdout.decode("utf-8", "replace").strip(), r.stderr.decode("utf-8", "replace").strip()


def lit(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, dict):
        return "'" + json.dumps(v, ensure_ascii=False).replace("'", "''") + "'::jsonb"
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


SCHEMA = __file__.replace("test_schema.py", "schema.sql")
psql("drop schema if exists app_private cascade; truncate net.sent;")
with open(SCHEMA, encoding="utf-8") as f:
    rc, out, err = psql(f.read())
if rc:
    sys.exit("schema.sql не применилась на чистой базе:\n" + err)

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
check("настройки читаются", call("admin_settings", p_token=atok) == {"earn_percent": 5, "max_spend_percent": 20, "max_check": 20000, "notify": 1})
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

print("== повторное применение schema.sql сохраняет данные")
before = owner("select count(*) from app_private.events;") + "/" + owner("select count(*) from app_private.users;")
with open(__file__.replace("test_schema.py", "schema.sql"), encoding="utf-8") as f:
    rc, out, err = psql(f.read())
after = owner("select count(*) from app_private.events;") + "/" + owner("select count(*) from app_private.users;")
check("schema.sql применяется повторно без ошибок", rc == 0, err[:200])
check("данные на месте", before == after, f"{before} → {after}")
check("пароль 1234 и PIN 1234 всё ещё работают",
      "token" in call("admin_login", p_password="1234") and "token" in call("staff_login", p_pin="1234"))

print(f"\nИтого: ✓ {passed}, ✗ {failed}")
sys.exit(1 if failed else 0)
