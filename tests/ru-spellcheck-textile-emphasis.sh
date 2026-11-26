#!/usr/bin/env bash
# ru-spellcheck: акцент разметки на краю слова (#16126).
#
# В Textile закрывающая звёздочка ставится ДО точки: `*не воспроизведён*.`. Разбор на слова склеивал
# `воспроизведён*.` в одно слово, однократный strip("*_~") по краям не снимал ничего (последний символ —
# точка), и словарь отвечал находкой на верном тексте: «воспроизведён*». Заметка в Redmine стоила
# раунда переписывания, а слово было написано правильно.
#
# Главная граница здесь — не «акцент пропускаем», а «акцент не прячет ошибку»: класс редукции гласных,
# ради которого проверка существует, обязан оставаться находкой и внутри `*нузен*`.
#
# Runs outside any repository, with a throwaway XDG_CONFIG_HOME.
# Exit 0 — all checks passed; 1 — a check failed; 77 — skipped (no hunspell ru_RU).
set -euo pipefail

TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/ru-spellcheck"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x "$TOOL" ]] || fail "нет $TOOL"
command -v python3 >/dev/null || fail "нужен python3"

export XDG_CONFIG_HOME="$WORK/config"
mkdir -p "$XDG_CONFIG_HOME/ru-spellcheck"
: > "$XDG_CONFIG_HOME/ru-spellcheck/allow.txt"

# Код берётся через `||`, а не `$?` после `if !`: под `set -e` упавший вызов обрывает скрипт до
# проверки статуса, и SKIP (77) остался бы мёртвой веткой.
printf 'Расчёт маржой закрыт.\n' > "$WORK/probe.md"
status=0
"$TOOL" "$WORK/probe.md" >/dev/null 2>&1 || status=$?
if [[ $status -eq 2 ]]; then
    echo "SKIP: нет словаря hunspell ru_RU"
    exit 77
fi

# 1. Верный текст в акценте — не находка: закрывающая звёздочка стоит перед точкой.
printf 'Провал *не воспроизведён*. Ещё _маржой_ и **Сдаётся**.\n' > "$WORK/good.md"
status=0
"$TOOL" "$WORK/good.md" > "$WORK/good.out" 2>&1 || status=$?
[[ $status -eq 0 ]] || fail "акцент на верном тексте дал код $status: $(cat "$WORK/good.out")"

# 2. Ошибка внутри акцента остаётся находкой, и слово в отчёте — без разметки.
printf 'Тут *нузен* ответ.\n' > "$WORK/bad.md"
status=0
"$TOOL" "$WORK/bad.md" > "$WORK/bad.out" 2>&1 || status=$?
[[ $status -eq 1 ]] || fail "ошибка внутри акцента не найдена (код $status): $(cat "$WORK/bad.out")"
grep -q 'SPELLING  нузен ' "$WORK/bad.out" || fail "слово названо с разметкой: $(cat "$WORK/bad.out")"
if grep -q 'нузен\*' "$WORK/bad.out"; then
    fail "звёздочка осталась в слове отчёта: $(cat "$WORK/bad.out")"
fi

# 3. Гомоглиф внутри акцента — тоже находка: маскировка разметкой не спасает жёсткий класс.
printf 'Тут *лoкальной* правки нет.\n' > "$WORK/homoglyph.md"
status=0
"$TOOL" --homoglyph-only "$WORK/homoglyph.md" > "$WORK/homoglyph.out" 2>&1 || status=$?
[[ $status -eq 1 ]] || fail "гомоглиф в акценте не найден (код $status): $(cat "$WORK/homoglyph.out")"

echo "OK: акцент разметки не мешает проверке и не прячет ошибку"
