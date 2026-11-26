#!/usr/bin/env bash
# tests/pi-subagents-review-loop-wait.sh — патч `prompts/review-loop.md` из `patches/`.
#
# Проверяет шесть состояний: на непропатченной фикстуре `--check` выходит с кодом 1, `--dry-run` ничего
# не пишет, применённый патч ставит абзац ПОСЛЕ абзаца запуска раунда и `--check` после него зелёный,
# повторный запуск ничего не дублирует. Пятое состояние — выдуманный upstream: якоря нет, патч обязан
# отказать с кодом 1, а не вставить абзац в случайное место. Шестое — пакета нет: код 0 и объяснение,
# потому что `install.sh` гоняет патчи и на машине без pi-subagents. Настоящий пакет не нужен: его роль
# играет фикстура под PI_CODING_AGENT_DIR. Шестое — на машине с установленным пакетом сверяется,
# что абзац-якорь в `prompts/review-loop.md` всё ещё дословный: иначе патч молча перестанет применяться.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/patches/pi-subagents-review-loop-wait.sh"

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Фикстура синтетическая: дословен только абзац-якорь (его сверяет и тест, и патч), остальное вокруг —
# пересказ, чтобы не тащить в тест весь upstream. Дрейф настоящего промпта ловит шаг 6: при
# установленном пакете якорь сверяется с `prompts/review-loop.md` файлом.
make_fixture() { # $1 — каталог PI_HOME, $2 — текст абзаца-якоря
  mkdir -p "$1/npm/node_modules/pi-subagents/prompts"
  cat >"$1/npm/node_modules/pi-subagents/prompts/review-loop.md" <<EOF
Run a parent-orchestrated review loop for the requested work.

$2

Choose review angles from the actual change.

After reviewers return, synthesize their feedback into:
- P0 blockers;
- P1 fixes worth doing now.

Additional target, implementation request, max-iteration cap, or review focus:

\$@
EOF
}

run_patch() { # $1 — каталог PI_HOME, дальше аргументы патча
  local home="$1"
  shift
  PI_CODING_AGENT_DIR="$home" "$PATCH" "$@" >"$tmp/out" 2>"$tmp/err"
  printf 'rc=%s\n' "$?"
}

ANCHOR='For each review round, launch fresh-context `reviewer` agents in parallel. Reviewers must inspect the repository, relevant instructions, and current diff directly from files and commands. They must not rely on the main conversation history and must not edit files.'
PARA="$ANCHOR"

check() { # $1 — подпись, $2 — ожидаемый код, $3 — каталог PI_HOME, дальше аргументы
  local label="$1" want="$2" home="$3"
  shift 3
  local rc
  rc="$(run_patch "$home" "$@")"
  if [[ "$rc" != "rc=$want" ]]; then
    echo "FAIL $label: ожидался код $want, получилось $rc" >&2
    cat "$tmp/err" >&2
    failures=$((failures + 1))
    return 1
  fi
  echo "ok   $label"
  return 0
}

# 1. Непропатченная фикстура: --check красный и файл не трогает.
home1="$tmp/home1"
make_fixture "$home1" "$PARA"
check 'check на непропатченном prompt' 1 "$home1" --check
if grep -q "Waiting is not the controller's work" "$home1/npm/node_modules/pi-subagents/prompts/review-loop.md"; then
  echo 'FAIL check на непропатченном prompt: --check изменил файл' >&2
  failures=$((failures + 1))
fi

# 2. --dry-run ничего не пишет.
check 'dry-run' 0 "$home1" --dry-run
if grep -q "Waiting is not the controller's work" "$home1/npm/node_modules/pi-subagents/prompts/review-loop.md"; then
  echo 'FAIL dry-run: файл изменён' >&2
  failures=$((failures + 1))
fi

# 3. Применение: абзац стоит после якоря, --check зелёный, повтор идемпотентен.
check 'применение' 0 "$home1"
prompt1="$home1/npm/node_modules/pi-subagents/prompts/review-loop.md"
python3 - "$prompt1" "$ANCHOR" <<'PY' || failures=$((failures + 1))
import sys
from pathlib import Path

path, anchor = Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
if anchor not in text:
    print("FAIL применение: абзац-якорь пропал из prompt", file=sys.stderr)
    sys.exit(1)
after = text.split(anchor, 1)[1]
if not after.startswith("\n\nWaiting is not the controller's work."):
    print("FAIL применение: абзац про ожидание стоит не сразу после якоря", file=sys.stderr)
    sys.exit(1)
if text.count("Waiting is not the controller's work.") != 1:
    print("FAIL применение: абзац вставлен больше одного раза", file=sys.stderr)
    sys.exit(1)
PY
check 'check на пропатченном prompt' 0 "$home1" --check
check 'повторный запуск' 0 "$home1"
if [[ "$(grep -c "Waiting is not the controller's work" "$prompt1")" != "1" ]]; then
  echo 'FAIL повторный запуск: абзац задвоился' >&2
  failures=$((failures + 1))
fi

# 4. Выдуманный upstream: якоря нет — патч отказывает и файл не трогает.
home2="$tmp/home2"
make_fixture "$home2" 'Launch whatever reviewers you like, in parallel.'
prompt2="$home2/npm/node_modules/pi-subagents/prompts/review-loop.md"
before="$(cksum <"$prompt2")"
check 'нет якоря — отказ' 1 "$home2"
if [[ "$(cksum <"$prompt2")" != "$before" ]]; then
  echo 'FAIL нет якоря — отказ: файл всё равно изменён' >&2
  failures=$((failures + 1))
fi
if ! grep -q 'anchor paragraph is gone' "$tmp/err"; then
  echo 'FAIL нет якоря — отказ: сообщение не называет причину' >&2
  cat "$tmp/err" >&2
  failures=$((failures + 1))
fi

# 5. Пакета нет — код 0 и понятная строка: install.sh гоняет патчи и на машине без pi-subagents.
home3="$tmp/home3"
mkdir -p "$home3"
check 'пакета нет — пропуск' 0 "$home3"
if ! grep -q 'nothing to patch' "$tmp/out"; then
  echo 'FAIL пакета нет — пропуск: нет объяснения' >&2
  cat "$tmp/out" >&2
  failures=$((failures + 1))
fi

# 6. Установленный пакет: якорь в нём всё ещё дословный, иначе патч молча перестанет применяться.
installed="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/npm/node_modules/pi-subagents/prompts/review-loop.md"
if [[ -f "$installed" ]]; then
  if grep -qF "$ANCHOR" "$installed"; then
    echo 'ok   якорь установленного prompt'
  else
    echo 'FAIL якорь установленного prompt: абзац переписан upstream — перевыведите якорь из промпта' >&2
    failures=$((failures + 1))
  fi
else
  echo 'pi-subagents: пакет не установлен на этой машине — якорь установленного prompt не проверялся (шаг 6 пропущен)'
fi

if [[ "$failures" -gt 0 ]]; then
  echo "ИТОГ: провалов $failures" >&2
  exit 1
fi
echo 'ИТОГ: все проверки прошли'
