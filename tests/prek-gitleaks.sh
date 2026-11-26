#!/usr/bin/env bash
# prek-хук gitleaks: ключ провайдера не проходит коммитом.
#
# Повод: репозиторий — это конфиги и скиллы, где ключ живёт одной строкой. Базовый набор
# gitleaks ловит `ROUTERAI_API_KEY=…` по имени переменной, а ключ отдельной строкой в скилле
# или в README пропускает; поэтому `.gitleaks.toml` добавляет правила на форму ключа.
#
# Проверяется на одноразовом репозитории с настоящим `prek install`: сценарии — чистый коммит
# проходит, ключ RouterAI отдельной строкой блокируется и в отказе названо правило, красная
# плашка из allowlist находкой не считается, `SKIP=gitleaks` проходит.
#
# Exit 0 — всё сошлось; 1 — проверка упала; 77 — пропуск (нет prek).
#
# Gitleaks ставит себе сам prek (язык хука — golang): на первой прогонке это сеть и сборка.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v prek >/dev/null || { echo "SKIP: нет prek"; exit 77; }
[[ -f "$ROOT/prek.toml" ]] || fail "нет prek.toml"
[[ -f "$ROOT/.gitleaks.toml" ]] || fail "нет .gitleaks.toml"

repo="$WORK/repo"
mkdir -p "$repo"
cp "$ROOT/prek.toml" "$repo/prek.toml"
cp "$ROOT/.gitleaks.toml" "$repo/.gitleaks.toml"
printf 'base\n' > "$repo/README.md"

git -C "$repo" init -q -b main
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m base
(cd "$repo" && prek install >/dev/null 2>&1) || fail "prek install не прошёл"

commit() { # $1 — сообщение; вывод prek не нужен, проверяется код возврата
    git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m "$1" >/dev/null 2>&1
}

# 1. Чистая правка проходит: хук не краснеет на обычном коммите.
printf 'x\n' >> "$repo/README.md"
git -C "$repo" add README.md
commit "readme" || fail "обычный коммит заблокирован хуком gitleaks"

# 2. Ключ отдельной строкой (без *_KEY=) блокируется правилом по форме ключа, а не по имени
#    переменной — ровно тот случай, ради которого `.gitleaks.toml` завёлся. Подсказку про обход
#    prek не печатает (в отличие от deny-list-guard, где её печатает сам скрипт), поэтому путь
#    обхода проверяется сценарием 3, а в README он документирован.
#
#    Ключ собран из двух кусков: цельной строкой он был бы находкой самого хука в этом файле
#    (первая же попытка коммита его и поймала).
fake_key="sk-""jjC3J27XDCG2LmlZGp8hkqdlm7tOtHWnsCGRlrwZbqcabUGJmG"
printf 'как в скилле: %s\n' "$fake_key" > "$repo/note.md"
git -C "$repo" add note.md
if commit "leak"; then
    fail "коммит с ключом RouterAI прошёл"
fi
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -m "leak" > "$WORK/leak.log" 2>&1 || true
grep -q "routerai-api-key" "$WORK/leak.log" || fail "в отказе не названо правило: $(cat "$WORK/leak.log")"

# 3. Штатный обход prek проходит — иначе ключ, который надо закоммитить осознанно, был бы тупиком.
SKIP=gitleaks git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m "leak (owner)" \
    >/dev/null 2>&1 || fail "SKIP=gitleaks не пропустил коммит"
git -C "$repo" log --oneline -1 | grep -q "leak (owner)" || fail "коммит с SKIP не появился"

# 4. Красная плашка в документации — не секрет: allowlist из `.gitleaks.toml` её пропускает.
printf 'ключ в журнале: sk-jj-REDACTED, публичный: pk-lf-REDACTED\n' > "$repo/log.md"
git -C "$repo" add log.md
commit "redacted" || fail "allowlist не пропустил плашку REDACTED"

echo "OK: ключ по форме блокируется, плашка REDACTED и SKIP=gitleaks проходят, чистый коммит не задет"
