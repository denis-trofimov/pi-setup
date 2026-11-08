#!/usr/bin/env bash
# Create a Redmine issue at most once, or recover the issue a previous attempt
# already created. See "Duplicate issues" in SKILL.md for why this exists.
#
# usage: create-issue.sh <payload.json> [--allow-existing] [--dry-run]
#
# <payload.json> is a Redmine create body: {"issue": {"project_id": ..., "subject": ..., ...}}
#
# Exit codes:
#   0  created, or recovered the id of the issue an earlier attempt created
#   2  refused: an issue with this exact subject already exists (no POST made)
#   3  ambiguous: the POST returned no id and the lookup found several candidates
#   4  failed: the POST returned no id and the lookup found nothing
set -euo pipefail

PAYLOAD=""
ALLOW_EXISTING=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --allow-existing) ALLOW_EXISTING=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 64 ;;
    *) PAYLOAD="$arg" ;;
  esac
done
[ -n "$PAYLOAD" ] || { echo "usage: create-issue.sh <payload.json> [--allow-existing] [--dry-run]" >&2; exit 64; }
[ -f "$PAYLOAD" ] || { echo "no such payload file: $PAYLOAD" >&2; exit 66; }

# Credentials: agent shells usually skip ~/.bashrc. Never echo these.
# An already-set environment wins, which is what keeps this script testable
# against a stub server. Getting that backwards once wrote to a live tracker.
if [ -z "${REDMINE_API_KEY:-}" ]; then
  eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
fi
echo "target: ${REDMINE_SERVER:-<unset>}" >&2

SUBJECT="$(jq -r '.issue.subject // empty' "$PAYLOAD")"
[ -n "$SUBJECT" ] || { echo "payload has no .issue.subject" >&2; exit 64; }
PROJECT="$(jq -r '.issue.project_id // empty' "$PAYLOAD")"

# Redmine's subject filter escapes these; keep the needle boring.
NEEDLE="$(printf '%s' "$SUBJECT" | sed 's/[][\\.*?^$()+{}|]/ /g' | cut -c1-40)"

lookup() {
  # Prints "id<TAB>created_on<TAB>subject" for issues with exactly this subject.
  local args=(issues list --status "*" --limit 25 -o json --filter "subject=~${NEEDLE}")
  [ -n "$PROJECT" ] && case "$PROJECT" in ''|*[!0-9]*) ;; *) args+=(--project "$PROJECT") ;; esac
  redmine "${args[@]}" 2>/dev/null |
    jq -r --arg s "$SUBJECT" '.[] | select(.subject == $s) | "\(.id)\t\(.created_on)\t\(.subject)"' || true
}

before="$(lookup)"
if [ -n "$before" ] && [ "$ALLOW_EXISTING" -eq 0 ]; then
  echo "refusing to create: an issue with this exact subject already exists:" >&2
  printf '%s\n' "$before" >&2
  echo "re-use that issue, change the subject, or pass --allow-existing" >&2
  exit 2
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: would POST $PAYLOAD" >&2
  exit 0
fi

set +e
RAW="$(redmine api /issues.json -X POST --input "$PAYLOAD")"
RC=$?
set -e

# The response body is {"issue": {...}}; a bare "id" only shows up in odd cases.
ID="$(printf '%s' "$RAW" | jq -r '.issue.id // .id // empty' 2>/dev/null || true)"

if [ "$RC" -ne 0 ]; then
  echo "POST failed (redmine api exit $RC), body:" >&2
  printf '%s\n' "$RAW" >&2
  # A non-2xx may still have committed server-side. Say so; do not retry here.
  echo "check for the issue before retrying: run the lookup below" >&2
  lookup >&2
  exit 4
fi

if [ -n "$ID" ] && [ "$ID" != "null" ]; then
  echo "$ID"
  echo "issue: ${REDMINE_SERVER}/issues/${ID}" >&2
  exit 0
fi

# No id: UNKNOWN, not failure. An earlier attempt may have created it.
echo "POST returned no id; response was:" >&2
printf '%s\n' "$RAW" >&2
after="$(lookup)"
matches="$(printf '%s\n' "$after" | grep -c . || true)"
if [ "$matches" -eq 1 ]; then
  printf '%s\n' "$after" | cut -f1
  echo "recovered: the issue exists (see lookup above); do not POST again" >&2
  exit 0
fi
if [ "$matches" -gt 1 ]; then
  echo "ambiguous: several issues match, pick one by hand:" >&2
  printf '%s\n' "$after" >&2
  exit 3
fi
echo "no issue with this subject exists; the create genuinely did not land" >&2
exit 4
