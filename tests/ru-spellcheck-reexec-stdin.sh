#!/usr/bin/env bash
# ru-spellcheck: stdin не теряется, когда процесс перезапускается другим интерпретатором (#16161).
#
# `need_enchant()` перезапускает скрипт через `os.execv(/usr/bin/python3, …)`, если в текущем
# интерпретаторе нет enchant (venv, setup-python на раннере). Пока вход читался до этого вызова,
# старый процесс успевал забрать весь stdin, новый получал пустой вход и отвечал кодом 0 — «чисто».
# Локально дефект невидим: `python3` здесь и есть /usr/bin/python3, перезапуска нет.
#
# Тест воспроизводит перезапуск venv-ом без enchant. Exit 0 — вход дошёл до проверки; 1 — потерян;
# 77 — воспроизвести нечем (нет venv с отдельным интерпретатором).
set -euo pipefail

TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/ru-spellcheck"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

export XDG_CONFIG_HOME="$WORK/config"
mkdir -p "$XDG_CONFIG_HOME/ru-spellcheck"
: > "$XDG_CONFIG_HOME/ru-spellcheck/allow.txt"

command -v python3 >/dev/null || { echo "SKIP: нет python3"; exit 77; }
python3 -m venv "$WORK/venv" >/dev/null 2>&1 || { echo "SKIP: нет модуля venv"; exit 77; }
venv_py="$WORK/venv/bin/python3"
[[ -x "$venv_py" ]] || { echo "SKIP: venv не создал интерпретатор"; exit 77; }
# Без enchant — иначе перезапуска не будет и тест проверит не тот путь.
"$venv_py" -c 'import enchant' >/dev/null 2>&1 && { echo "SKIP: в venv виден enchant, перезапуск не воспроизвести"; exit 77; }

repo="$WORK/repo"
mkdir -p "$repo"
git -C "$repo" init -q
# Запись deny-списка не зависит от словаря: находка обязана быть при любом наборе hunspell.
printf 'примере\n' > "$repo/.ru-spellcheck-deny"

out="$(cd "$repo" && printf 'Текст в примере.\n' | "$venv_py" "$TOOL" - 2>&1)" && rc=0 || rc=$?
[[ $rc -eq 1 ]] || fail "stdin потерян при перезапуске: код $rc, вывод: ${out:-<пусто>}"
grep -q 'DENY' <<<"$out" || fail "вход прочитан, но находки нет: $out"

echo "OK: stdin доходит до проверки и после перезапуска другим интерпретатором"
