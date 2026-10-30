#!/usr/bin/env python3
"""Собирает supabase/schema.sql из миграций supabase/migrations/NNNN_*.sql.

schema.sql — это «всё одним файлом» для первой установки: вставили в SQL Editor, нажали Run.
Он целиком идемпотентен, поэтому его же можно применять поверх уже работающей базы.

    python supabase/build_schema.py           # пересобрать schema.sql
    python supabase/build_schema.py --check   # проверить, что schema.sql соответствует миграциям (для CI)
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HEADER = """-- ============================================================================
-- Бонусная система кофейни — полная схема для Supabase (Postgres).
-- ФАЙЛ СОБРАН АВТОМАТИЧЕСКИ из supabase/migrations/*.sql — не правьте его руками:
--     python supabase/build_schema.py
--
-- Как применить: Supabase → SQL Editor → New query → вставить весь файл → Run.
-- Можно запускать повторно: функции пересоздаются, данные не теряются.
-- ============================================================================

"""


def build():
    parts = []
    for f in sorted((HERE / "migrations").glob("[0-9][0-9][0-9][0-9]_*.sql")):
        parts.append(f"-- ################ миграция {f.name} ################\n\n" + f.read_text("utf-8").rstrip() + "\n")
    return HEADER + "\n".join(parts)


if __name__ == "__main__":
    out = HERE / "schema.sql"
    text = build()
    if "--check" in sys.argv:
        if not out.exists() or out.read_text("utf-8") != text:
            sys.exit("schema.sql устарел: выполните  python supabase/build_schema.py  и закоммитьте результат")
        print("schema.sql соответствует миграциям")
    else:
        out.write_text(text, "utf-8", newline="\n")
        print(f"Собрано: {out.name}, {len(text.splitlines())} строк из {len(list((HERE / 'migrations').glob('*.sql')))} миграций")
