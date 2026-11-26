#!/usr/bin/env bash
# Make pi-subagents reject a one-child launch that has no task.
#
# `subagent({ agent, cwd, output })` — agent without task — passes validation and
# starts a child with an empty task: the child gets nothing to do, the parent has
# to stop it, and the run costs tokens for no result. `src/extension/public-execution.js`
# checks only that `agent` is a non-empty string (and that a provided `task` is a
# string), then launches; a whitespace-only task passes the same way. The error
# message next to it even advertises `{ agent, task? }`, so the shape reads as
# supported.
#
# This patch adds the missing check: a one-child launch requires `task` to be a
# non-empty string, and the message names the call shape. It is idempotent
# (second run reports "already patched") and skips packages that are not
# installed. Pi reinstalls npm packages on `pi install` / `pi update --extensions`,
# which reverts local patches, so install.sh re-applies this automatically.
#
# Usage:
#   ./patches/pi-subagents-task-required.sh            # patch the installed package
#   ./patches/pi-subagents-task-required.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-subagents-task-required.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PKG_DIR="$PI_HOME/npm/node_modules/pi-subagents"

if [[ ! -d "$PKG_DIR" ]]; then
  echo "pi-subagents: not installed under $PKG_DIR; nothing to patch."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "pi-subagents: python3 is required to patch; skipping." >&2
  exit 1
fi

python3 - "$PKG_DIR" "$DRY_RUN" "$CHECK_ONLY" <<'PY'
import re
import sys
from pathlib import Path

pkg = Path(sys.argv[1])
dry_run = sys.argv[2] == "1"
check_only = sys.argv[3] == "1"

# The one-child branch always carries this sentence; a file that has it is the file
# to patch, and a file without it is left alone. Anchoring on the sentence instead
# of on the whole block is what keeps the bundle in scope: it is generated code and
# spells the same guard differently (`void 0`, four spaces of indent, `=== void 0`
# comparisons), which is how the first version of this patch silently skipped it.
BRANCH_MARKER = '"Structured single-child task must be a string when provided."'

# The guard we insert, right after the "task must be a string" check. Indentation is
# taken from the file: the source uses eight spaces, the bundle four.
TASK_GUARD_ANCHOR = re.compile(
    r"(?P<indent>[ \t]*)if \(params\.task !== (?:undefined|void 0) && typeof params\.task !== \"string\"\) \{\n"
    r"(?P<inner_indent>[ \t]*)return [^\n]*\n"
    r"(?P=indent)\}\n"
)

# The inserted block reuses the file's own indentation (four spaces in the source,
# two in the bundle), so the result looks native and a formatter has nothing to undo.
NEW_GUARD = (
    '{indent}if (typeof params.task !== "string" || !params.task.trim()) {{\n'
    '{inner_indent}return {{ ok: false, error: "Structured single-child execution requires task to be a non-empty string: call subagent({{ agent, task }}).", mode: "workflow" }};\n'
    "{indent}}}\n"
)

GUARD_MARKER = "requires task to be a non-empty string"

# The shape advertised when nothing was passed: `{ agent, task? }` reads as "task
# optional", which is exactly how an agent-only call happens.
OLD_SHAPE = "Execution requires either { agent, task? } for one child or workflow"
NEW_SHAPE = "Execution requires either { agent, task } for one child or workflow"

# The runtime file plus its bundled copy (the bundle carries the same function;
# which one loads depends on the entry point).
candidates = [pkg / "src" / "extension" / "public-execution.js"]
candidates += sorted((pkg / "bundle").glob("*.js"))

changed = False
patched_any = False
missing = []
for path in candidates:
    if not path.is_file():
        continue
    text = path.read_text()
    if BRANCH_MARKER not in text:
        continue
    needs_guard = GUARD_MARKER not in text
    needs_shape = OLD_SHAPE in text
    if not needs_guard and not needs_shape:
        print(f"pi-subagents: {path.name} already patched")
        patched_any = True
        continue
    if check_only:
        print(f"pi-subagents: {path.name} is NOT patched")
        changed = True
        continue
    if dry_run:
        print(f"pi-subagents: would patch {path}")
        changed = True
        continue
    updated = text
    if needs_guard:
        match = TASK_GUARD_ANCHOR.search(updated)
        if match is None:
            missing.append(path.name)
            continue
        insert_at = match.end()
        updated = (
            updated[:insert_at]
            + NEW_GUARD.format(indent=match.group("indent"), inner_indent=match.group("inner_indent"))
            + updated[insert_at:]
        )
    if needs_shape:
        updated = updated.replace(OLD_SHAPE, NEW_SHAPE, 1)
    # Proof after the edit: both halves must be in place, otherwise the file is left
    # as it was and the run fails instead of reporting success.
    if GUARD_MARKER not in updated or OLD_SHAPE in updated:
        missing.append(path.name)
        continue
    path.write_text(updated)
    print(f"pi-subagents: patched {path}")
    changed = True
    patched_any = True

if missing:
    print(
        "pi-subagents: found the one-child validation in "
        + ", ".join(missing)
        + " but could not rewrite it. The upstream release changed; re-derive patches/pi-subagents-task-required.sh.",
        file=sys.stderr,
    )
    sys.exit(1)

if not patched_any and not changed:
    print(
        "pi-subagents: could not find the one-child validation in "
        f"{pkg}. The upstream release changed; re-derive patches/pi-subagents-task-required.sh.",
        file=sys.stderr,
    )
    sys.exit(1)

if check_only:
    sys.exit(1 if changed else 0)

sys.exit(0)
PY
