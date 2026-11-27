#!/usr/bin/env bash
# patches/pi-fff-ignored-path.sh: путь вне индекса назван явно, а не подменён чужими совпадениями (#97).
#
# Повод: в ретро сессии #16200 `ffgrep` с `path` в git-ignored каталог (`runtime/detached/<id>/log`)
# вернул совпадения из `AGENTS.md`, `Makefile` и `scripts/ci/…`. Путь не в индексе, ограниченный
# запрос не нашёл ничего, и инструмент ушёл в ветку «может, вы имели в виду» — по всему репозиторию.
# Вывод при этом выглядит обычным: пути и номера строк, отличить «нашёл в этом файле» от «нашёл в
# другом» по нему нельзя.
#
# Патч ставит явный ответ «путь вне индекса» и флаг `includeIgnored`, который читает путь с диска.
#
# Проверяется механика патча на синтетической копии пакета: (1) все пять якорей переписаны; (2) файл
# остаётся разбираемым TypeScript; (3) второй прогон идемпотентен; (4) `--check` различает состояния;
# (5) на незнакомом тексте патч не притворяется успешным. Сам обработчик (`isGitIgnoredPath` и
# сканирование с диска) в CI не запускается: пакета там нет, а `@earendil-works/pi-coding-agent`
# и `@ff-labs/fff-node` для импорта не установлены.
# Exit 0 — всё сошлось; 1 — проверка упала.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/patches/pi-fff-ignored-path.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Копия пакета: те же пять якорей, что и в установленном pi-fff, но без настоящего кода вокруг них.
fixture() {
	local pkg="$WORK/$1/npm/node_modules/@ff-labs/pi-fff/src"
	mkdir -p "$pkg"
	cat > "$pkg/index.ts" <<'TS'
import nodePath from "node:path";
import { isFsRoot, isHomeDir, resolveDbPaths } from "./paths";
import { buildQuery } from "./query";

export { SCAN_TIMEOUT_MS } from "./sdk";

  const grepSchema = Type.Object({
    pattern: Type.String({
      description: "Search pattern (literal text or regex)",
    }),
  });

  const grep = {
    async execute(_toolCallId, params, signal) {
      const pattern = params.pattern;
      const aux = await resolveFinderForPath(params.path, pattern, params.exclude);
      const picker = aux ? aux.finder : await ensureFinder(activeCwd);
      const effectiveLimit = Math.max(1, params.limit ?? DEFAULT_GREP_LIMIT);
      return { content: [{ type: "text", text: "" }], details: {} };
    },
  };
TS
	printf '%s\n' "$pkg"
}

PKG="$(fixture lesson)"
export PI_CODING_AGENT_DIR="$WORK/lesson"

# (1) Непротоптанная копия: `--check` говорит «не пропатчен» и выходит с 1.
if bash "$PATCH" --check >/dev/null 2>&1; then
	fail "--check сказал «пропатчен» до патча"
fi

# `--dry-run` ничего не пишет.
bash "$PATCH" --dry-run >/dev/null || fail "--dry-run упал"
grep -q 'pi-setup patch' "$PKG/index.ts" && fail "--dry-run изменил файл"

# (2) Патч ставит все части и файл остаётся разбираемым TypeScript.
bash "$PATCH" >/dev/null || fail "патч упал"
for needle in 'pi-setup patch: ignored path outside the index' \
	'includeIgnored: Type.Optional(' \
	'function scanIgnoredPath(' \
	'function isGitIgnoredPath(' \
	'isGitIgnoredPath(onDiskPath, activeCwd)' \
	'from "node:child_process"'; do
	grep -qF "$needle" "$PKG/index.ts" || fail "нет в патче: $needle"
done
node --experimental-strip-types --check "$PKG/index.ts" || fail "файл перестал разбираться"

# (3) Идемпотентность: второй прогон говорит «уже пропатчен» и ничего не меняет.
before="$(cksum < "$PKG/index.ts")"
out="$(bash "$PATCH")" || fail "повторный патч упал"
printf '%s\n' "$out" | grep -q 'already patched' || fail "повторный прогон не сказал «already patched»: $out"
[[ "$(cksum < "$PKG/index.ts")" == "$before" ]] || fail "повторный прогон изменил файл"

# (4) `--check` на пропатченной копии проходит.
bash "$PATCH" --check >/dev/null || fail "--check не прошёл на пропатченной копии"

# (5) Незнакомый текст: патч не притворяется успешным.
ODD="$(fixture odd)"
sed -i '/const picker = aux ? aux.finder : await ensureFinder(activeCwd);/d' "$ODD/index.ts"
export PI_CODING_AGENT_DIR="$WORK/odd"
if bash "$PATCH" >/dev/null 2>&1; then
	fail "патч «прошёл» на тексте без якоря"
fi
grep -q 'pi-setup patch' "$ODD/index.ts" && fail "патч изменил файл без якоря"

echo "ok: pi-fff-ignored-path"
