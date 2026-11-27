#!/usr/bin/env bash
# ru-spellcheck: одобренная замена для deny-слова — отдельный файл, а не колонка deny-списка.
#
# Повод (#90): за сессию `01a2196c` четыре красных прогона и восемь разных слов на четыре заметки —
# каждое снималось отдельной итерацией правки, потому что отказ говорил «нельзя» и не говорил «пиши
# так». Таблица замен существовала прозой в скилле msb-lk, то есть в проектном файле, хотя сами
# deny-слова глобальные.
#
# Проверяется: (1) строка `<слово> -> <замена>` печатается в находке DENY; (2) строка без `->`
# оставляет прежний текст; (3) `слово*` даёт замену словоформам; (4) проектный
# `.ru-spellcheck-deny-rewrites` читается наравне с машинным; (5) deny остаётся в силе — замена не
# отменяет запрет.
#
# Работает на временном XDG_CONFIG_HOME: живой словарь и список замен не трогаются.
# Exit 0 — всё сошлось; 1 — проверка упала.

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
: > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
: > "$XDG_CONFIG_HOME/ru-spellcheck/deny-rewrites.txt"

# Замена печатается в находке DENY и не отменяет сам запрет.
printf 'инлайн\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
printf 'инлайн -> встроенный\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny-rewrites.txt"
printf 'Инлайн-код не ломать.\n' > "$WORK/note.md"

out="$("$TOOL" "$WORK/note.md" 2>&1)" && fail "deny-слово принято как верное: $out"
case "$out" in
    *"DENY"*"замените на: встроенный"*) ;;
    *) fail "находка DENY не назвала замену: $out" ;;
esac

# Слово без замены: текст отказа прежний, подсказки нет.
printf 'инлайн\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny-rewrites.txt"
out="$("$TOOL" "$WORK/note.md" 2>&1)" && fail "deny-слово без замены принято как верное: $out"
case "$out" in
    *"замените на"*) fail "подсказка появилась без замены в списке: $out" ;;
    *"слово из deny-списка"*) ;;
    *) fail "находка DENY потеряла прежний текст: $out" ;;
esac

# Запись `слово*` даёт замену словоформам — тем самым, которые и ловит deny-список.
printf 'бамп*\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
printf 'бамп* -> поднять версию\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny-rewrites.txt"
printf 'Сделали бампом и забыли.\n' > "$WORK/stem.md"
out="$("$TOOL" "$WORK/stem.md" 2>&1)" && fail "словоформа запрещённого слова принята как верная: $out"
case "$out" in
    *"замените на: поднять версию"*) ;;
    *) fail "замена по стему не применилась: $out" ;;
esac

# Проектный список замен читается рядом с проверяемыми файлами и перекрывает машинный.
repo="$WORK/repo"
mkdir -p "$repo"
git -C "$repo" init -q
: > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
: > "$XDG_CONFIG_HOME/ru-spellcheck/deny-rewrites.txt"
printf 'мастеркод\n' > "$repo/.ru-spellcheck-deny"
printf 'мастеркод -> код в основной ветке\n' > "$repo/.ru-spellcheck-deny-rewrites"
printf 'Мастеркод не трогаем.\n' > "$repo/note.md"
out="$("$TOOL" "$repo/note.md" 2>&1)" && fail "проектный deny-файл не применился: $out"
case "$out" in
    *"замените на: код в основной ветке"*) ;;
    *) fail "проектный список замен не прочитан: $out" ;;
esac

echo "OK: замена печатается в находке DENY, слово без замены — без подсказки, стем и проект работают"
