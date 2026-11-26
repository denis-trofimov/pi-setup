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
import sys
from pathlib import Path

pkg = Path(sys.argv[1])
dry_run = sys.argv[2] == "1"
check_only = sys.argv[3] == "1"

# The check sits right after the "task must be a string" guard in the one-child
# branch; keeping the anchor small makes the patch survive unrelated upstream
# edits around it.
OLD_TASK_GUARD = '''        if (params.task !== undefined && typeof params.task !== "string") {
            return { ok: false, error: "Structured single-child task must be a string when provided.", mode: "workflow" };
        }
'''
NEW_TASK_GUARD = '''        if (params.task !== undefined && typeof params.task !== "string") {
            return { ok: false, error: "Structured single-child task must be a string when provided.", mode: "workflow" };
        }
        if (typeof params.task !== "string" || !params.task.trim()) {
            return { ok: false, error: "Structured single-child execution requires task to be a non-empty string: call subagent({ agent, task }).", mode: "workflow" };
        }
'''

# The shape advertised when nothing was passed: `{ agent, task? }` reads as "task
# optional", which is exactly how an agent-only call happens.
OLD_SHAPE = "Execution requires either { agent, task? } for one child or workflow"
NEW_SHAPE = "Execution requires either { agent, task } for one child or workflow"

MARKER = "requires task to be a non-empty string"

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
    has_marker = MARKER in text
    has_anchor = OLD_TASK_GUARD in text or OLD_SHAPE in text
    if not has_marker and not has_anchor:
        continue
    if has_marker:
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
    if OLD_TASK_GUARD in updated:
        updated = updated.replace(OLD_TASK_GUARD, NEW_TASK_GUARD, 1)
    if OLD_SHAPE in updated:
        updated = updated.replace(OLD_SHAPE, NEW_SHAPE, 1)
    if updated == text:
        missing.append(path.name)
        continue
    path.write_text(updated)
    print(f"pi-subagents: patched {path}")
    changed = True
    patched_any = True

if missing:
    print(
        "pi-subagents: found the task guard in "
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
