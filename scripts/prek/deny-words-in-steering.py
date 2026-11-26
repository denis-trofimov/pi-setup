#!/usr/bin/env python3
"""prek-хук: слова из deny-списка ru-spellcheck не живут в каноне (#16159 п.2).

Зачем. `deny.txt` называет лексику, которую агент придумал и не имеет права узаконить: `ru-spellcheck`
считает такое слово находкой в любой публикации. Канон — `config/AGENTS.md` и `skills/**` — читает
каждый агент, и слово оттуда он копирует в заметку как верное: цикл «прочитал канон → скопировал →
получил отказ → переписал» стоил четырёх правок одного слова в #16132. Агент учится словарю по канону,
поэтому канон и проверяется тем же списком, а не вторым перечнем.

Что считается. Только проза: блоки кода и `встроенный код` маскируются, потому что канон цитирует
запрещённые слова как примеры — эти упоминания и должны остаться. Слова сравниваются по словоформам,
как в самом `ru-spellcheck` (`is_denied`): запись без звёздочки — точное совпадение, запись вида
`слово*` — основа, то есть `премис*` ловит `премиса`, `премисы`, `премисов`.

Список — тот же файл, что читает `ru-spellcheck`: `config/ru-spellcheck/deny.txt` в этом репозитории.
Второго перечня нет: разъехавшиеся списки дали бы «канон чист, а заметка красная» и наоборот.

Использование:
  python3 scripts/prek/deny-words-in-steering.py                 # канон этого репозитория
  python3 scripts/prek/deny-words-in-steering.py --root <dir>    # канон другого каталога (тесты)
  SKIP=deny-words-in-steering git commit …                       # штатный обход prek

Коды: 0 — чисто (или списка нет: CI на чужой машине без него проверять нечего); 1 — есть находки;
2 — ошибка вызова.
"""
import argparse
import pathlib
import re
import sys

STEERING_FILES = ("config/AGENTS.md",)
STEERING_DIRS = ("skills",)
DENY_RELATIVE = pathlib.Path("config/ru-spellcheck/deny.txt")

# Слово — буква, дальше буквы и дефис; части через дефис проверяются отдельно, как в ru-spellcheck.
# Буква задана через \w без цифр и подчёркиваний, а не явными диапазонами: явный диапазон ставит
# латиницу вплотную к кириллице, и проверка исходника видит в этом диапазоне смесь алфавитов.
WORD = re.compile(r"[^\W\d_][\w\-]*", re.UNICODE)
FENCED = re.compile(r"```.*?```", re.S)
INLINE_CODE = re.compile(r"`[^`\n]*`")


def blank(match):
    """Заменить маску пробелами, сохранив переводы строк: номера строк остаются файловыми."""
    return re.sub(r"[^\n]", " ", match.group(0))


def mask(text):
    return INLINE_CODE.sub(blank, FENCED.sub(blank, text))


def load_deny(path):
    entries = []
    if not path.is_file():
        return entries
    for line in path.read_text(encoding="utf-8").splitlines():
        word = line.strip()
        if not word or word.startswith("#"):
            continue
        stem = word.endswith("*")
        entries.append((stem, word.rstrip("*").lower().replace("ё", "е")))
    return entries


def is_denied(segment, entries):
    word = segment.lower().replace("ё", "е")
    for stem, entry in entries:
        if (word.startswith(entry) if stem else word == entry):
            return True
    return False


def steering_files(root):
    files = [root / rel for rel in STEERING_FILES if (root / rel).is_file()]
    for dirname in STEERING_DIRS:
        base = root / dirname
        if base.is_dir():
            files.extend(sorted(base.rglob("*.md")))
    return files


def whole_run(text, start, end):
    """Кусок без пробелов вокруг совпадения: путь, адрес или почта решаются по нему целиком."""
    while start > 0 and not text[start - 1].isspace():
        start -= 1
    while end < len(text) and not text[end].isspace():
        end += 1
    return text[start:end]


def check_file(path, root, entries):
    findings = []
    text = path.read_text(encoding="utf-8")
    masked = mask(text)
    for match in WORD.finditer(masked):
        # Путь, адрес или почта: `docs/…/tip.md` — это имя файла, а не слово в прозе.
        if re.search(r"[/@]", whole_run(text, match.start(), match.end())):
            continue
        for segment in match.group(0).split("-"):
            if not segment or not is_denied(segment, entries):
                continue
            line = masked.count("\n", 0, match.start()) + 1
            rel = path.relative_to(root)
            findings.append(f"{rel}:{line}: {segment} — слово из deny-списка")
    return findings


def main(argv):
    parser = argparse.ArgumentParser(add_help=True, description="Слова из deny-списка в каноне (#16159).")
    parser.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[2]),
                        help="корень репозитория (тесты подставляют свой)")
    args = parser.parse_args(argv[1:])

    root = pathlib.Path(args.root).resolve()
    entries = load_deny(root / DENY_RELATIVE)
    if not entries:
        print(f"deny-words-in-steering: нет {DENY_RELATIVE} в {root} — проверять нечего", file=sys.stderr)
        return 0

    findings = []
    for path in steering_files(root):
        findings.extend(check_file(path, root, entries))

    if not findings:
        return 0

    print("deny-words-in-steering: в каноне есть слова из deny-списка.", file=sys.stderr)
    print("Агент учится словарю по этим файлам и копирует слово в заметку как верное.", file=sys.stderr)
    print("Правят текст, а не список: список принадлежит человеку.", file=sys.stderr)
    for line in findings:
        print(line, file=sys.stderr)
    print("Обход, если упоминание осознанное (пример в прозе): "
          "SKIP=deny-words-in-steering git commit …", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
