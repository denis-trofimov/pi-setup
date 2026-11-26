#!/usr/bin/env bash
# deny-words-in-steering: слова из deny-списка в каноне (#16159 п.2).
#
# Агент учится словарю по канону. Слово из `~/.config/ru-spellcheck/deny.txt`, прочитанное в
# `AGENTS.md` или в скилле, он копирует в заметку как верное, и гейт публикации отказывает — цикл
# «прочитал канон → скопировал → переписал» стоил четырёх правок одного слова в #16132.
#
# Проверяются границы, а не только находка: примеры в блоке кода и в `встроенном коде` — не находка
# (канон цитирует запрещённые слова именно так), имя пути — тоже. Без этих кейсов хук краснел бы на
# собственном правиле, и его пришлось бы отключать.
set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/prek/deny-words-in-steering.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$HOOK" ]] || fail "нет $HOOK"
command -v python3 >/dev/null || fail "нужен python3"

root="$WORK/root"
mkdir -p "$root/config/ru-spellcheck" "$root/skills/пример"
printf '%s\n' '# список' 'инлайн' 'бамп*' > "$root/config/ru-spellcheck/deny.txt"
printf 'Канон без запрещённых слов.\n' > "$root/config/AGENTS.md"
printf 'Скилл без запрещённых слов.\n' > "$root/skills/пример/SKILL.md"

run() { python3 "$HOOK" --root "$root"; }

run >/dev/null || fail "чистый канон обязан проходить"

# Находка в прозе канона — красный, с файлом и номером строки.
printf 'Канон без запрещённых слов.\nЗдесь слово инлайн стоит в прозе.\n' > "$root/config/AGENTS.md"
out="$(run 2>&1)" && fail "слово из списка в прозе обязано ловиться"
grep -q 'config/AGENTS.md:2' <<<"$out" || fail "в находке нет файла и строки: $out"
grep -q 'инлайн' <<<"$out" || fail "в находке нет слова: $out"

# Пример во встроенном коде — упоминание, а не употребление.
printf 'Канон.\nСлово `инлайн` здесь только цитируется.\n' > "$root/config/AGENTS.md"
run >/dev/null || fail "слово в обратных кавычках — не находка"

# …и в блоке кода тоже.
cat > "$root/config/AGENTS.md" <<'EOF'
Канон.

```text
инлайн
```
EOF
run >/dev/null || fail "слово в блоке кода — не находка"

# Запись со звёздочкой — основа: `бамп*` ловит `бампа`, `бампы`.
printf 'Канон.\nПодъём версии — не бампа, а подъём.\n' > "$root/config/AGENTS.md"
out="$(run 2>&1)" && fail "основа из списка обязана ловиться"
grep -q 'бампа' <<<"$out" || fail "не названа словоформа: $out"

# Путь — имя файла, а не слово в прозе: `docs/инлайн.md` остаётся зелёным.
printf 'Канон.\nСмотри `docs/инлайн.md` и https://example.test/инлайн.\n' > "$root/config/AGENTS.md"
run >/dev/null || fail "слово внутри пути или адреса — не находка"

# Нет списка — проверять нечего: CI на чужой машине и репозиторий без политики.
mv "$root/config/ru-spellcheck/deny.txt" "$WORK/deny.bak"
run >/dev/null || fail "без deny-списка хук обязан пропускать"
mv "$WORK/deny.bak" "$root/config/ru-spellcheck/deny.txt"

# Скиллы — та же проверка, что и AGENTS.md.
printf 'Скилл.\nПравка живёт в том же файле, не инлайн.\n' > "$root/skills/пример/SKILL.md"
printf 'Канон без запрещённых слов.\n' > "$root/config/AGENTS.md"
run >/dev/null 2>&1 && fail "слово в скилле обязано ловиться"

echo "OK: deny-слова в каноне ловятся, примеры в коде и имена путей проходят"
