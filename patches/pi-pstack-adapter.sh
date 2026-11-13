#!/usr/bin/env bash
# Teach pi-pstack-adapter that the structured-question provider is
# @juicesharp/rpiv-ask-user-question, not pi-ask-user.
#
# The adapter probes for a tool literally named `ask_user` that accepts
# `question` + `options`, and its generated host mapping tells the agent to call
# `ask_user`. rpiv registers `ask_user_question` with a `questions` array, so the
# probe always reports `structured-question` as unavailable and the wrappers point
# the agent at a tool that does not exist.
#
# This patch rewrites the probe and the host-mapping row. It is idempotent: it
# reports "already patched" and changes nothing on a second run. Pi reinstalls
# npm packages on `pi install` / `pi update --extensions`, so re-run this after
# either (install.sh calls it automatically).
#
# Usage:
#   ./patches/pi-pstack-adapter.sh            # patch the installed package
#   ./patches/pi-pstack-adapter.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-pstack-adapter.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PKG_DIR="$PI_HOME/npm/node_modules/pi-pstack-adapter"
CACHE_DIR="$PI_HOME/cache/pi-pstack-adapter"

if [[ ! -d "$PKG_DIR" ]]; then
  echo "pi-pstack-adapter: not installed under $PKG_DIR; nothing to patch."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "pi-pstack-adapter: python3 is required to patch; skipping." >&2
  exit 1
fi

status=0
python3 - "$PKG_DIR" "$DRY_RUN" "$CHECK_ONLY" <<'PY' || status=$?
import sys
from pathlib import Path

pkg = Path(sys.argv[1])
dry_run = sys.argv[2] == "1"
check_only = sys.argv[3] == "1"

OLD_PROBE = '''    toolName: "ask_user",
    requiredParameters: ["question", "options"],
    recommendation: "Install a structured question provider, for example `pi install npm:pi-ask-user`.",'''

NEW_PROBE = '''    toolName: "ask_user_question",
    requiredParameters: ["questions"],
    recommendation: "Install a structured question provider, for example `pi install npm:@juicesharp/rpiv-ask-user-question`.",'''

OLD_ROW = "| \\`AskUserQuestion\\`, \\`AskQuestion\\` | the \\`ask_user\\` tool. |"
NEW_ROW = "| \\`AskUserQuestion\\`, \\`AskQuestion\\` | the \\`ask_user_question\\` tool. |"

PATCHES = [
    (pkg / "src" / "capabilities.ts", OLD_PROBE, NEW_PROBE, 'toolName: "ask_user_question"'),
    (pkg / "src" / "generate.ts", OLD_ROW, NEW_ROW, "the \\`ask_user_question\\` tool"),
]

changed = False
missing = []
for path, old, new, marker in PATCHES:
    text = path.read_text()
    if marker in text:
        print(f"pi-pstack-adapter: {path.name} already patched")
        continue
    if old not in text:
        missing.append(path.name)
        continue
    if check_only:
        print(f"pi-pstack-adapter: {path.name} is NOT patched")
        changed = True
        continue
    if dry_run:
        print(f"pi-pstack-adapter: would patch {path}")
    else:
        path.write_text(text.replace(old, new, 1))
        print(f"pi-pstack-adapter: patched {path.name}")
    changed = True

if missing:
    print(
        "pi-pstack-adapter: could not find the expected text in "
        + ", ".join(missing)
        + ". The upstream release changed; re-derive patches/pi-pstack-adapter.sh.",
        file=sys.stderr,
    )
    sys.exit(1)

if check_only:
    sys.exit(1 if changed else 0)

sys.exit(0)
PY

if [[ $status -ne 0 ]]; then
  exit $status
fi

# The generated wrappers are content-addressed, and the host mapping is part of
# that digest, so a patched generate.ts produces a fresh directory on its own.
# Drop the stale ones so nothing keeps pointing at the old `ask_user` text.
if [[ "$CHECK_ONLY" == "0" && "$DRY_RUN" == "0" && -d "$CACHE_DIR/generated" ]]; then
  if [[ -n "$(ls -A "$CACHE_DIR/generated" 2>/dev/null)" ]]; then
    rm -rf "${CACHE_DIR:?}/generated"/*
    echo "pi-pstack-adapter: cleared generated wrappers; they regenerate on the next Pi start."
  fi
fi
