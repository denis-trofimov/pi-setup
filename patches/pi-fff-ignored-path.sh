#!/usr/bin/env bash
# Make pi-fff's `grep` say "outside the index" instead of searching the repository.
#
# `ffgrep` with a `path` that git ignores — `runtime/detached/<id>/log` in msb-lk — answered with
# matches from `AGENTS.md`, `Makefile`, `scripts/ci/…` (#16200). The path is not in the index, so the
# constrained query matched nothing and the tool fell through to its fuzzy fallback, which matched the
# pattern across the whole repository. The output looks like an ordinary result: paths, line numbers,
# no sign that the requested file was never read. One call was lost and the result was read as
# "matches in other files" — the grep itself was wrong about what it answered.
#
# This patch makes the case explicit: a path that exists on disk but is git-ignored is reported as
# `outside the index` with the ways to search it (`includeIgnored: true`, `rg`, `read` with offset),
# and `includeIgnored: true` scans that single path from disk. Idempotent; skips a package that is not
# installed. Pi reinstalls npm packages on `pi install` / `pi update --extensions`, which reverts local
# patches, so install.sh re-applies this automatically.
#
# Usage:
#   ./patches/pi-fff-ignored-path.sh            # patch the installed package
#   ./patches/pi-fff-ignored-path.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-fff-ignored-path.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PKG_DIR="$PI_HOME/npm/node_modules/@ff-labs/pi-fff"

if [[ ! -d "$PKG_DIR" ]]; then
  echo "pi-fff: not installed under $PKG_DIR; nothing to patch."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "pi-fff: python3 is required to patch; skipping." >&2
  exit 1
fi

python3 - "$PKG_DIR" "$DRY_RUN" "$CHECK_ONLY" <<'PY'
import sys
from pathlib import Path

pkg = Path(sys.argv[1])
dry_run = sys.argv[2] == "1"
check_only = sys.argv[3] == "1"

SOURCE = pkg / "src" / "index.ts"

MARKER = "pi-setup patch: ignored path outside the index (#16200)"

IMPORT_FS = (
    'import { execFileSync } from "node:child_process";\n'
    'import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";\n'
)
IMPORT_ANCHOR = 'import nodePath from "node:path";\n'

PATHS_ANCHOR = 'import { isFsRoot, isHomeDir, resolveDbPaths } from "./paths";'
PATHS_PATCHED = 'import { HOME_DIR, isFsRoot, isHomeDir, resolveDbPaths } from "./paths";'

HELPERS_ANCHOR = 'export { SCAN_TIMEOUT_MS } from "./sdk";\n'

HELPERS = '''
// pi-setup patch: ignored path outside the index (#16200)
//
// `grep` with a `path` pointing into a git-ignored directory ("runtime/detached/<id>/log") did not
// say "this path is not in the index": the constrained query matched nothing and the tool fell
// through to its fuzzy fallback, which answered with matches from other files. The result looked
// ordinary — paths, line numbers — so it could not be told apart from a match inside the named file.
//
// Helpers below make that case explicit: an existing path that git ignores is outside the index, the
// tool says so, and `includeIgnored: true` scans that one path from disk.

const IGNORED_SCAN_MAX_FILES = 2000;
const IGNORED_SCAN_MAX_BYTES = 2000000;

function resolveOnDiskPath(raw: string | undefined, cwd: string): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (!trimmed || /[*?[{]/.test(trimmed)) return null;
  let candidate = trimmed;
  if (candidate === "~" || candidate.startsWith("~/")) {
    candidate = nodePath.join(HOME_DIR, candidate.slice(1));
  }
  if (!nodePath.isAbsolute(candidate)) candidate = nodePath.resolve(cwd, candidate);
  try {
    return existsSync(candidate) ? candidate : null;
  } catch {
    return null;
  }
}

function isGitIgnoredPath(target: string, cwd: string): boolean {
  try {
    execFileSync("git", ["-C", cwd, "check-ignore", "-q", "--", target], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function collectFilesOnDisk(target: string, out: string[], depth = 0): void {
  if (out.length >= IGNORED_SCAN_MAX_FILES || depth > 24) return;
  let stat;
  try {
    stat = statSync(target);
  } catch {
    return;
  }
  if (stat.isFile()) {
    if (stat.size <= IGNORED_SCAN_MAX_BYTES) out.push(target);
    return;
  }
  if (!stat.isDirectory()) return;
  let entries: string[] = [];
  try {
    entries = readdirSync(target);
  } catch {
    return;
  }
  entries.sort();
  for (const name of entries) {
    if (name === ".git" || name === "node_modules") continue;
    collectFilesOnDisk(nodePath.join(target, name), out, depth + 1);
    if (out.length >= IGNORED_SCAN_MAX_FILES) return;
  }
}

function scanIgnoredPath(
  target: string,
  cwd: string,
  pattern: string,
  limit: number,
  caseSensitive: boolean,
): { text: string; matches: number; files: number } {
  const files: string[] = [];
  collectFilesOnDisk(target, files);
  const smartCase = !caseSensitive && pattern === pattern.toLowerCase();
  const hasRegexSyntax = pattern !== pattern.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&");
  let regex: RegExp | null = null;
  if (hasRegexSyntax) {
    try {
      regex = new RegExp(pattern, smartCase ? "i" : "");
    } catch {
      regex = null;
    }
  }
  const needle = smartCase ? pattern.toLowerCase() : pattern;
  const shown = nodePath.relative(cwd, target) || target;
  const hits: string[] = [];
  let scanned = 0;
  for (const file of files) {
    let text: string;
    try {
      text = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    scanned += 1;
    const lines = text.split("\\n");
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      const hit =
        regex !== null ? regex.test(line) : (smartCase ? line.toLowerCase() : line).includes(needle);
      if (!hit) continue;
      hits.push(`${nodePath.relative(cwd, file)}:${index + 1}: ${line}`);
      if (hits.length >= limit) {
        hits.push(`[${limit} matches shown: path is outside the index and read directly from disk]`);
        return { text: hits.join("\\n"), matches: limit, files: scanned };
      }
    }
  }
  if (hits.length === 0) {
    return {
      text: `0 matches in ${scanned} file(s) read directly from ${shown} (path is outside the index, so the answer comes from disk and not from the picker).`,
      matches: 0,
      files: scanned,
    };
  }
  return { text: hits.join("\\n"), matches: hits.length, files: scanned };
}
'''

SCHEMA_ANCHOR = "  const grepSchema = Type.Object({\n"

SCHEMA_FIELD = (
    "    includeIgnored: Type.Optional(\n"
    "      Type.Boolean({\n"
    "        description:\n"
    '          "Scan a path git ignores (outside the index) directly from disk instead of refusing it. '
    'Without this, grep on such a path answers with an explicit \\"outside the index\\" error: the index '
    'has no files there, and answering from it would return matches from other files.",\n'
    "      }),\n"
    "    ),\n"
)

GUARD_ANCHOR = (
    "      const picker = aux ? aux.finder : await ensureFinder(activeCwd);\n"
    "      const effectiveLimit = Math.max(1, params.limit ?? DEFAULT_GREP_LIMIT);\n"
)

GUARD = '''
      // pi-setup patch: ignored path outside the index (#16200)
      const onDiskPath = resolveOnDiskPath(params.path, activeCwd);
      if (onDiskPath !== null && isGitIgnoredPath(onDiskPath, activeCwd)) {
        const shownPath = nodePath.relative(activeCwd, onDiskPath) || onDiskPath;
        if (params.includeIgnored !== true) {
          return {
            content: [
              {
                type: "text",
                text:
                  `Path '${params.path}' is outside the index: it exists (${shownPath}) but git ignores it, so no indexed file matches it. ` +
                  "Answering from the index here would return matches from OTHER files, not from this path. " +
                  "Use includeIgnored: true to scan the path directly, `rg <pattern> <path>` in bash, or `read` with offset and limit.",
              },
            ],
            details: { totalMatched: 0, totalFiles: 0 },
          };
        }
        const direct = scanIgnoredPath(
          onDiskPath,
          activeCwd,
          pattern,
          effectiveLimit,
          params.caseSensitive === true,
        );
        return {
          content: [{ type: "text", text: direct.text }],
          details: { totalMatched: direct.matches, totalFiles: direct.files },
        };
      }
'''

if not SOURCE.is_file():
  print(
    f"pi-fff: {SOURCE} not found. The upstream release changed; re-derive patches/pi-fff-ignored-path.sh.",
    file=sys.stderr,
  )
  sys.exit(1)

text = SOURCE.read_text()

if MARKER in text:
  print("pi-fff: already patched")
  sys.exit(0)

if check_only:
  print("pi-fff: is NOT patched")
  sys.exit(1)

missing = []
if 'from "node:child_process"' not in text and IMPORT_ANCHOR not in text:
  missing.append("import anchor")
if PATHS_ANCHOR not in text and PATHS_PATCHED not in text:
  missing.append("paths import")
if HELPERS_ANCHOR not in text:
  missing.append("helpers anchor")
if SCHEMA_ANCHOR not in text:
  missing.append("grep schema")
if GUARD_ANCHOR not in text:
  missing.append("grep execute")

if missing:
  print(
    "pi-fff: could not find "
    + ", ".join(missing)
    + f" in {SOURCE}. The upstream release changed; re-derive patches/pi-fff-ignored-path.sh.",
    file=sys.stderr,
  )
  sys.exit(1)

if dry_run:
  print(f"pi-fff: would patch {SOURCE}")
  sys.exit(0)

updated = text
if 'from "node:child_process"' not in updated:
  updated = updated.replace(IMPORT_ANCHOR, IMPORT_ANCHOR + IMPORT_FS, 1)
if PATHS_ANCHOR in updated:
  updated = updated.replace(PATHS_ANCHOR, PATHS_PATCHED, 1)
updated = updated.replace(HELPERS_ANCHOR, HELPERS_ANCHOR + HELPERS, 1)
updated = updated.replace(SCHEMA_ANCHOR, SCHEMA_ANCHOR + SCHEMA_FIELD, 1)
updated = updated.replace(GUARD_ANCHOR, GUARD_ANCHOR + GUARD, 1)

# Proof after the edit: the guard, the helper and the schema field must all be in place, otherwise the
# file is left as it was and the run fails instead of reporting success.
for needle in (MARKER, "includeIgnored", "function scanIgnoredPath(", "isGitIgnoredPath(onDiskPath"):
  if needle not in updated:
    print(f"pi-fff: patch did not apply (missing {needle!r}); {SOURCE} left unchanged.", file=sys.stderr)
    sys.exit(1)

SOURCE.write_text(updated)
print(f"pi-fff: patched {SOURCE}")
PY
