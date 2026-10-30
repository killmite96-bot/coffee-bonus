#!/usr/bin/env python3
"""Быстрые проверки сайта и репозитория (запускаются в CI и локально):

  1. все относительные ссылки и подключаемые файлы в docs/ существуют;
  2. скрипты (отдельные .js и встроенные в HTML) не содержат синтаксических ошибок — нужен Node.js (в CI есть);
  3. в репозитории нет секретов: ключей service_role/secret, токенов Telegram-бота, закрытых ключей.

    python tools/check_site.py
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')   # галочки и русский текст в консоли Windows

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
problems = []


def fail(msg):
    problems.append(msg)
    print("  ✗", msg)


def ok(msg):
    print("  ✓", msg)


# ---------------------------------------------------------------- 1. ссылки
print("== ссылки и подключаемые файлы")
ATTR = re.compile(r'(?:href|src)="([^"#?]+)')
checked = 0
for page in sorted(DOCS.rglob("*.html")):
    for ref in ATTR.findall(page.read_text("utf-8")):
        if re.match(r"^(https?:|data:|mailto:|tel:|//)", ref) or ref.startswith("${") or "${" in ref:
            continue
        target = (page.parent / ref).resolve()
        if target.is_dir():
            target = target / "index.html"
        checked += 1
        if not target.exists():
            fail(f"{page.relative_to(ROOT)}: нет файла {ref}")
manifest = DOCS / "manifest.webmanifest"
if manifest.exists():
    import json
    for icon in json.loads(manifest.read_text("utf-8")).get("icons", []):
        checked += 1
        if not (DOCS / icon["src"]).exists():
            fail(f"manifest.webmanifest: нет файла {icon['src']}")
ok(f"проверено ссылок: {checked}") if not problems else None

# ---------------------------------------------------------------- 2. синтаксис скриптов
print("== синтаксис скриптов")
node = shutil.which("node")
if not node:
    print("  – Node.js не найден, проверка синтаксиса пропущена (в CI он есть)")
else:
    with tempfile.TemporaryDirectory() as tmp:
        files = [p for p in DOCS.rglob("*.js") if "vendor" not in p.parts]
        for page in DOCS.rglob("*.html"):
            for i, code in enumerate(re.findall(r"<script>(.*?)</script>", page.read_text("utf-8"), re.S)):
                f = Path(tmp) / f"{page.parent.name}_{page.stem}_{i}.js"
                f.write_text(code, "utf-8")
                files.append(f)
        bad = 0
        for f in files:
            r = subprocess.run([node, "--check", str(f)], capture_output=True, text=True)
            if r.returncode:
                bad += 1
                fail(f"синтаксическая ошибка в {f.name}: {r.stderr.strip().splitlines()[0] if r.stderr else ''}")
        if not bad:
            ok(f"скриптов без ошибок: {len(files)}")

# ---------------------------------------------------------------- 3. секреты
print("== секреты в репозитории")
tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True).stdout.split("\n")
PATTERNS = {
    "ключ Supabase secret/service_role": re.compile(r"sb_secret_[A-Za-z0-9_-]{16,}"),
    "JWT с ролью service_role": re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*c2VydmljZV9yb2xl[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+"),
    "токен Telegram-бота": re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_-]{30,}"),
    "закрытый ключ": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
}
SKIP_EXT = {".png", ".jpg", ".apk", ".keystore", ".jar"}
leaks = 0
for rel in filter(None, tracked):
    p = ROOT / rel
    if p.suffix.lower() in SKIP_EXT or not p.is_file() or "vendor" in p.parts:
        continue
    text = p.read_text("utf-8", errors="ignore")
    for name, rx in PATTERNS.items():
        if rx.search(text):
            leaks += 1
            fail(f"{rel}: найден {name}")
for forbidden in ("config.json", "debug.keystore"):
    if any(t.endswith(forbidden) for t in tracked):
        leaks += 1
        fail(f"в репозиторий попал файл {forbidden}")
if not leaks:
    ok("секретов не найдено")

print()
if problems:
    sys.exit(f"Найдено проблем: {len(problems)}")
print("Всё в порядке")
