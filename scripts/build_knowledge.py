#!/usr/bin/env python3
"""Собирает knowledge/clinic.md в модуль для функции Зои.

Человек правит Markdown-файл, а функция получает его как обычный TypeScript-модуль,
который выкладывается вместе с кодом. Запуск: python3 scripts/build_knowledge.py
"""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
src = root / "knowledge" / "clinic.md"
dst = root / "supabase" / "functions" / "zoya" / "knowledge.ts"

text = src.read_text(encoding="utf-8")
sections = [line[3:].strip() for line in text.splitlines() if line.startswith("## ")]
if "Основное" not in sections:
    raise SystemExit("В базе знаний нет обязательного раздела «## Основное»")

escaped = text.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")
dst.write_text(
    "// СГЕНЕРИРОВАНО из knowledge/clinic.md командой scripts/build_knowledge.py — не редактировать вручную.\n"
    f"export const KNOWLEDGE = `{escaped}`;\n",
    encoding="utf-8",
)
print(f"OK: {len(sections)} разделов → {dst.relative_to(root)}: " + ", ".join(sections))
