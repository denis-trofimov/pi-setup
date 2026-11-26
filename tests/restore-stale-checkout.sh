#!/usr/bin/env bash
# `--restore` раскладывает файлы чекаута, а не origin (#16137). 26.11.2026 основной чекаут стоял на
# main на один коммит позади origin/main: `./install.sh --restore` отработал с кодом 0, напечатал
# «AGENTS.md is up to date» и разложил старую версию — правки уже смерженного PR на машину не попали.
# В выводе не было ни имени коммита, ни предупреждения об отставании, и шаг «проверить, что выкатилось»
# выглядел выполненным.
#
# Проверяется: (1) первая строка раскладки называет ветку и коммит; (2) чекаут, отставший от upstream
# на один коммит, получает предупреждение с числом коммитов и подсказкой `pull --ff-only`, а показанный
# коммит — свой, старый, а не origin; (3) грязное дерево названо отдельной строкой, потому что копируются
# файлы с диска, а не коммит.
#
# Работает на временном HOME и временном remote: живая копия этой машины не трогается.
# Exit 0 — всё сошлось; 1 — проверка упала.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

export GIT_AUTHOR_NAME="restore stale test"
export GIT_AUTHOR_EMAIL="restore-stale@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# Клон, а не cp -a: в клоне install.sh берёт содержимое из себя, а не из дерева под ревью, поэтому
# install.sh и sync.sh копируются поверх (tests/README.md).
#
# Ветка заводится явно (`checkout -B work`), а remote свой (`upstream`): в CI репозиторий лежит в
# detached HEAD, и `git clone --bare "$ROOT"` даёт bare без ветки — клон такой базы тоже detached,
# `@{upstream}` не резолвится, а push падает на `HEAD does not point to a branch`.
bare="$WORK/remote.git"
git -c init.defaultBranch=main init -q --bare "$bare"
clone="$WORK/clone"
git clone -q --no-hardlinks "$ROOT" "$clone"
git -C "$clone" checkout -q -B work
cp "$ROOT"/install.sh "$ROOT"/sync.sh "$clone"/
git -C "$clone" add -A
# Правка уже в коммите (тест гоняют после сдачи) — коммитить нечего, и это не провал.
if ! git -C "$clone" diff --cached --quiet; then
  git -C "$clone" commit -q -m "install.sh под проверкой"
fi
git -C "$clone" remote add upstream "$bare"
git -C "$clone" push -q upstream work
git -C "$clone" branch -q --set-upstream-to=upstream/work work
git -C "$bare" symbolic-ref HEAD refs/heads/work
upstream_branch="$(git -C "$clone" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"

home="$WORK/home"
pi_home="$home/.pi/agent"
bin="$home/.local/bin"
mkdir -p "$pi_home/docs" "$home/.config/ru-spellcheck" "$bin"
cp "$clone/config/settings.example.json" "$pi_home/settings.json"
cp "$clone/config/ru-spellcheck/allow.txt" "$home/.config/ru-spellcheck/allow.txt"
cp "$clone/config/ru-spellcheck/deny.txt" "$home/.config/ru-spellcheck/deny.txt"

restore_log() { # restore_log <файл лога>
  env HOME="$home" PI_HOME="$pi_home" BIN_DIR="$bin" XDG_CONFIG_HOME="$home/.config" \
    bash "$clone/install.sh" --restore --dry-run --no-backup >"$1" 2>&1 || {
    sed -n '1,40p' "$1" >&2
    fail "restore --dry-run завершился ошибкой (см. выше)"
  }
}

# (1) Ветка и коммит названы; отставший чекаут — единственный случай с предупреждением.
tip="$(git -C "$clone" rev-parse --short HEAD)"
branch="$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
log1="$WORK/restore-current.log"
restore_log "$log1"
grep -qF "Раскладка из $branch@$tip" "$log1" \
  || fail "первая строка раскладки не называет $branch@$tip"
grep -q "warning: чекаут отстаёт" "$log1" \
  && fail "предупреждение об отставании на актуальном чекауте"

# (2) Второй клон уводит remote на коммит вперёд — первый остаётся позади.
other="$WORK/other"
git clone -q "$bare" "$other"
git -C "$other" checkout -q -B work
git -C "$other" commit -q --allow-empty -m "чужой коммит в базе"
git -C "$other" push -q origin HEAD
behind="$WORK/restore-behind.log"
restore_log "$behind"
grep -q "warning: чекаут отстаёт от $upstream_branch на 1 коммит" "$behind" \
  || fail "нет предупреждения об отставании на 1 коммит от $upstream_branch"
grep -q "Раскладка из .*@$tip$" "$behind" \
  || fail "раскладка показывает не свой коммит $tip"
grep -q "pull --ff-only" "$behind" \
  || fail "в предупреждении нет подсказки pull --ff-only"

# (3) Грязное дерево названо: копируются файлы с диска, а не коммит.
printf 'локальная правка\n' >> "$clone/README.md"
dirty="$WORK/restore-dirty.log"
restore_log "$dirty"
grep -q "незакоммиченные правки" "$dirty" \
  || fail "грязное дерево не названо в выводе раскладки"
git -C "$clone" checkout -q -- README.md

echo "OK: restore называет ветку и коммит, предупреждает об отставании от upstream и о грязном дереве"
