#!/usr/bin/env python3
"""Локальный стенд для проверки сайта без Supabase.

Имитирует Supabase REST (POST /rest/v1/rpc/<функция>) поверх тестового Postgres в Docker
(контейнер coffee-pg-test с применённым schema.sql) и раздаёт папку docs/ по адресу
http://localhost:8090/coffee-bonus/ — точно так же, как GitHub Pages.

Запуск: python supabase/rest_shim.py     (Ctrl+C — остановить)
Только для разработки: реальный сайт использует Supabase.
"""
import json
import mimetypes
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "docs"
PREFIX = "/coffee-bonus"
PORT = 8090
CONTAINER = "coffee-pg-test"
mimetypes.add_type("application/manifest+json", ".webmanifest")

LOCAL_CONFIG = (f"window.APP_CONFIG = {{ SUPABASE_URL: 'http://localhost:{PORT}', SUPABASE_KEY: 'local-test-key' }};\n")


def lit(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return "'" + json.dumps(v, ensure_ascii=False).replace("'", "''") + "'::jsonb"
    return "'" + str(v).replace("'", "''") + "'"   # как PostgREST: значение приводится к типу параметра


def rpc(fn, args, client_ip):
    if not re.fullmatch(r"[a-z_0-9]+", fn):
        return 404, {"message": "Функция не найдена"}
    call = ", ".join(f"{k} => {lit(v)}" for k, v in args.items() if re.fullmatch(r"p_[a-z_]+", k))
    sql = (f"set role anon;\nselect set_config('request.headers', "
           f"'{json.dumps({'x-forwarded-for': client_ip})}', false);\nselect public.{fn}({call})::text;")
    r = subprocess.run(["docker", "exec", "-i", CONTAINER, "psql", "-U", "postgres", "-qAt",
                        "-v", "VERBOSITY=verbose", "-v", "ON_ERROR_STOP=1"],
                       input=sql.encode("utf-8"), capture_output=True)
    if r.returncode:
        err = r.stderr.decode("utf-8", "replace")
        m = re.search(r"ERROR:\s+(\w{5}):\s*(.*)", err)
        code, msg = (m.group(1), m.group(2).strip()) if m else ("P0001", err.strip()[:300])
        status = int(code[2:]) if code.startswith("PT") and code[2:].isdigit() else 400
        return status, {"code": code, "message": msg}
    out = r.stdout.decode("utf-8", "replace").strip().splitlines()
    return 200, json.loads(out[-1]) if out else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        if "/rpc/" in (a[0] if a else ""):
            sys.stderr.write("%s\n" % (fmt % a))

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _send(self, status, body, ctype):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        m = re.fullmatch(r"/rest/v1/rpc/([a-z_0-9]+)", self.path.split("?")[0])
        if not m:
            return self._send(404, b'{"message":"not found"}', "application/json")
        n = int(self.headers.get("Content-Length") or 0)
        try:
            args = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._send(400, b'{"message":"bad json"}', "application/json")
        status, data = rpc(m.group(1), args, self.client_address[0])
        self._send(status, json.dumps(data, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == PREFIX:
            self.send_response(301)
            self.send_header("Location", PREFIX + "/")
            self.end_headers()
            return
        if not path.startswith(PREFIX + "/"):
            return self._send(404, b"not found", "text/plain")
        rel = path[len(PREFIX) + 1:]
        if rel == "assets/config.js":                      # локальный конфиг вместо пустого из репозитория
            return self._send(200, LOCAL_CONFIG.encode(), "application/javascript; charset=utf-8")
        f = (DOCS / rel).resolve()
        if f.is_dir():
            f = f / "index.html"
        if DOCS not in f.parents and f != DOCS or not f.is_file():
            return self._send(404, "Страница не найдена".encode(), "text/plain; charset=utf-8")
        ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
        self._send(200, f.read_bytes(), ctype + ("; charset=utf-8" if ctype.startswith("text/") or "javascript" in ctype else ""))


if __name__ == "__main__":
    print(f"Стенд: http://localhost:{PORT}{PREFIX}/   (база: контейнер {CONTAINER})")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
