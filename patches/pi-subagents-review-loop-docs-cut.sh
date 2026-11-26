#!/usr/bin/env bash
# Put the docs-cut review form into `pi-subagents`' `/review-loop` prompt.
#
# `pi-subagents` 0.89.2 rewrote `prompts/review-loop.md` and the patches that carried local
# rules were dropped (README, «`pi-subagents`: the local prompt patches are gone»). The rule
# this patch carries is the one that started costing a round again: on a documentation-only
# cut the three review angles overlap — in #16129 a 229-line docs diff went through three
# rounds and six reviewers, two of them found the same thing, and all three re-checked the
# same eight anchors a second time. The repo canon (msb-lk `.claude/commands/review-inline.md`)
# now says two reviewers and no `bash` on that cut; the loop prompt is what the parent
# actually reads, so the rule has to live here too, or the parent keeps spawning three.
#
# The insertion anchor is the paragraph that picks the review angles. Upstream will reword it
# eventually: then the patch fails loudly and prints what it could not find — re-derive the
# anchor from the fixture (`tests/pi-subagents-review-loop-docs-cut.sh`), never loosen it.
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, which reverts this
# patch; `install.sh` re-applies every `patches/*.sh` on each run.
#
# Usage:
#   ./patches/pi-subagents-review-loop-docs-cut.sh            # patch the installed package
#   ./patches/pi-subagents-review-loop-docs-cut.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-subagents-review-loop-docs-cut.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PROMPT="$PI_HOME/npm/node_modules/pi-subagents/prompts/review-loop.md"

if [[ ! -f "$PROMPT" ]]; then
  echo "pi-subagents-review-loop-docs-cut: $PROMPT is missing; nothing to patch."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "pi-subagents-review-loop-docs-cut: python3 is required to patch; skipping." >&2
  exit 1
fi

status=0
python3 - "$PROMPT" "$DRY_RUN" "$CHECK_ONLY" <<'PY' || status=$?
import sys
from pathlib import Path

prompt = Path(sys.argv[1])
dry_run = sys.argv[2] == "1"
check_only = sys.argv[3] == "1"

# The upstream paragraph this patch hangs off. It is the one that chooses the angles, so the
# docs variant belongs right after it.
ANCHOR = (
    "Choose review angles from the actual change. Common angles are correctness/regressions, "
    "tests/validation, and simplicity/maintainability. Add security, performance, docs/API "
    "contracts, or user-flow validation when the work calls for it. Prefer three strong "
    "reviewers over many vague reviewers."
)

# First line is the marker: it is what `--check` looks for, so keep it stable.
ADDITION = """The cut type decides the shape of the round. Name it with the repository's own check before round 1 (in msb-lk: `bash scripts/ci/handoff-cut-type.sh origin/<base>` from the fix worktree) and put the verdict in every reviewer's task. On a documentation-only cut (`тип: docs`) use two reviewers, not three: one checks facts against data (every number, path and `file:line` anchor against the measurement quoted in the task, the tables of the same file and the code), the other checks standards and links (fragment format, markup traps such as a version link that points at itself, copies of the same canon in sibling skills). Reviewers on that cut do not run `bash` at all: the diff, the numbers, the file list and the plan arrive in the task from the parent, and a missing number is a question to the parent, not a re-measurement. A second docs round is one targeted reviewer on the lines the first round changed. On code and tooling cuts keep the three angles above. Acceptance for a docs review: a number in prose matches the number in the same file's table, and a measurement is quoted from the task instead of being recomputed."""

text = prompt.read_text(encoding="utf-8")

if "The cut type decides the shape of the round." in text:
    if check_only:
        print("pi-subagents-review-loop-docs-cut: patch is applied")
        sys.exit(0)
    print("pi-subagents-review-loop-docs-cut: prompt is already patched")
    sys.exit(0)

if check_only:
    print("pi-subagents-review-loop-docs-cut: prompt is NOT patched", file=sys.stderr)
    print(
        "  run ./patches/pi-subagents-review-loop-docs-cut.sh",
        file=sys.stderr,
    )
    sys.exit(1)

if ANCHOR not in text:
    print(
        "pi-subagents-review-loop-docs-cut: the anchor paragraph is gone — upstream reworded "
        "the angles sentence. Re-derive the anchor from tests/pi-subagents-review-loop-docs-cut.sh, "
        "do not loosen the check.",
        file=sys.stderr,
    )
    sys.exit(1)

patched = text.replace(ANCHOR, ANCHOR + "\n\n" + ADDITION, 1)

if dry_run:
    print("pi-subagents-review-loop-docs-cut: would insert the docs-cut paragraph after the angles paragraph")
    sys.exit(0)

prompt.write_text(patched, encoding="utf-8")
print("pi-subagents-review-loop-docs-cut: inserted the docs-cut paragraph into prompts/review-loop.md")
PY

exit $status
