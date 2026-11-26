#!/usr/bin/env bash
# Put the "waiting is not the controller's work" rule into `pi-subagents`' `/review-loop` prompt.
#
# The loop prompt already tells the parent to launch reviewers async, and the async reply itself says
# "return control now". Neither stops the parent from standing in a wait loop, and the repo canon that
# says it (`msb-lk` `.claude/commands/review-inline.md` § «Ожидание субагента — не дело родителя`) is
# not what the parent reads at that moment. In msb-lk #15812 the wait for two reviewers cost 17 `sleep`
# calls and 74 minutes of wall time while both reports were already written (#15865 п.1); the same rule
# came back as a finding twice more (#16149, #16163). The prompt is the one text the parent reads in
# every session, so the rule lives here too.
#
# The insertion anchor is the paragraph that launches the parallel reviewers. Upstream will reword it
# eventually: then the patch fails loudly and prints what it could not find — re-derive the anchor from
# the fixture (`tests/pi-subagents-review-loop-wait.sh`), never loosen it.
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, which reverts this patch;
# `install.sh` re-applies every `patches/*.sh` on each run.
#
# Usage:
#   ./patches/pi-subagents-review-loop-wait.sh            # patch the installed package
#   ./patches/pi-subagents-review-loop-wait.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-subagents-review-loop-wait.sh --dry-run  # show what would change

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
PROMPT="$PI_HOME/npm/node_modules/pi-subagents/prompts/review-loop.md"

if [[ ! -f "$PROMPT" ]]; then
  echo "pi-subagents-review-loop-wait: $PROMPT is missing; nothing to patch."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "pi-subagents-review-loop-wait: python3 is required to patch; skipping." >&2
  exit 1
fi

status=0
python3 - "$PROMPT" "$DRY_RUN" "$CHECK_ONLY" <<'PY' || status=$?
import sys
from pathlib import Path

prompt = Path(sys.argv[1])
dry_run = sys.argv[2] == "1"
check_only = sys.argv[3] == "1"

# The upstream paragraph that launches the round. The wait rule belongs right after it: that is the
# sentence the parent acts on before it starts waiting.
ANCHOR = (
    "For each review round, launch fresh-context `reviewer` agents in parallel. Reviewers must inspect "
    "the repository, relevant instructions, and current diff directly from files and commands. They "
    "must not rely on the main conversation history and must not edit files."
)

# First line is the marker: it is what `--check` looks for, so keep it stable.
ADDITION = """Waiting is not the controller's work. An async run wakes the session on its own, so after launching return control: do not `sleep`, do not poll `subagent({ action: "status" })` in a loop, and do not call `bg_wait` for an ordinary async child. A parent standing in a wait loop does nothing while the reviewers finish — in msb-lk #15812 the wait for two reviewers cost 17 `sleep` calls and 74 minutes with both reports already written. The one exception is a same-turn result you genuinely need: then wait once with `bg_wait`, not in a polling loop. A long local command is the other case, and it is waited with the repository's own wrapper (`scripts/ci/run-detached.sh wait <id>` in msb-lk), not with `sleep`."""

text = prompt.read_text(encoding="utf-8")

if "Waiting is not the controller's work." in text:
    if check_only:
        print("pi-subagents-review-loop-wait: patch is applied")
        sys.exit(0)
    print("pi-subagents-review-loop-wait: prompt is already patched")
    sys.exit(0)

if check_only:
    print("pi-subagents-review-loop-wait: prompt is NOT patched", file=sys.stderr)
    print(
        "  run ./patches/pi-subagents-review-loop-wait.sh",
        file=sys.stderr,
    )
    sys.exit(1)

if ANCHOR not in text:
    print(
        "pi-subagents-review-loop-wait: the anchor paragraph is gone — upstream reworded the "
        "paragraph that launches the round. Re-derive the anchor from "
        "tests/pi-subagents-review-loop-wait.sh, do not loosen the check.",
        file=sys.stderr,
    )
    sys.exit(1)

patched = text.replace(ANCHOR, ANCHOR + "\n\n" + ADDITION, 1)

if dry_run:
    print("pi-subagents-review-loop-wait: would insert the wait paragraph after the launch paragraph")
    sys.exit(0)

prompt.write_text(patched, encoding="utf-8")
print("pi-subagents-review-loop-wait: inserted the wait paragraph into prompts/review-loop.md")
PY

exit $status
