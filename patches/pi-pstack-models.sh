#!/usr/bin/env bash
# Strip the Cursor model slugs out of the pstack skill bodies.
#
# Upstream pstack was written for Cursor, so its bodies fall back to concrete
# Cursor slugs when no `~/.cursor/rules/pstack-models.mdc` rule exists:
# `claude-opus-5-5-xhigh`, `grok-4.7-xhigh-fast`, `composer-*`, `cursor-grok-*`.
# None of those ids exist in this Pi installation, and Pi never has the rule, so
# the fallback always fires. This patch rewrites every such body, at generation
# time, to a `pstack:<role>` reference: the adapter then picks the role's model
# and thinking, so no skill names a model.
#
# The rewrite table lives in this script and is the single source of truth. The
# script regenerates the table inside `src/generate.ts` and verifies the result
# against the upstream checkout: if a future upstream release adds a slug this
# table does not cover, the run fails and prints the leftovers.
#
# It also replaces the Cursor model ids in the adapter's own `setup.md` examples
# with `<provider>/<model>` placeholders, so nothing teaches a blocked family.
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, so re-run
# this after either (install.sh calls it automatically).
#
# Usage:
#   ./patches/pi-pstack-models.sh            # patch the installed package
#   ./patches/pi-pstack-models.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-pstack-models.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PKG_DIR="$PI_HOME/npm/node_modules/pi-pstack-adapter"
CACHE_DIR="$PI_HOME/cache/pi-pstack-adapter"

if [[ ! -d "$PKG_DIR" ]]; then
  echo "pi-pstack-models: pi-pstack-adapter is not installed under $PKG_DIR; nothing to patch."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "pi-pstack-models: python3 is required to patch; skipping." >&2
  exit 1
fi

status=0
python3 - "$PKG_DIR" "$CACHE_DIR" "$DRY_RUN" "$CHECK_ONLY" <<'PY' || status=$?
import json
import re
import shutil
import sys
from pathlib import Path

pkg = Path(sys.argv[1])
cache = Path(sys.argv[2])
dry_run = sys.argv[3] == "1"
check_only = sys.argv[4] == "1"

# --- the rewrite table ------------------------------------------------------
# (upstream text, Pi text). Applied to every generated body and every copied
# Markdown support file. Ordered: the specific sentences first, then the generic
# phrase cleanup.
REWRITES = [
    # pistack-arena
    (
        "If the rule or that line is missing, default to one each on `claude-opus-5-5-xhigh` and `grok-4.7-xhigh-fast`. An `auto` or `inherit-parent` entry in this line means the parent model, so omit `model` for it.",
        "If the rule or that line is missing, run one seat on `pstack:judgment` and one on `pstack:general`. A role that inherits the parent model runs with no `model`, so omit it for that seat.",
    ),
    (
        "If the Task tool rejects a configured entry, run that seat on its family's default and say so. Families go by prefix: `claude-*`, and `grok-*` with `cursor-grok-*` and `composer-*`. A refused `composer-*` entry runs on `grok-4.7-xhigh-fast`. If the family has no default, or the Task tool rejects that default, use the closest valid slug of the same family from its error message, or drop the seat and say so when there is none.",
        "If the delegation rejects a configured entry, say so and run that seat on `pstack:general` instead. If that is rejected too, drop the seat and say so.",
    ),
    (
        "Run each added runner on a remaining runner's model, or omit `model` so it runs on the parent model when none remain, and say so.",
        "Run each added runner on a remaining runner's role, or omit `model` so it runs on the parent model when none remain, and say so.",
    ),
    (
        "Use the same model N times when the work is generation-bound rather than judgment-sensitive.",
        "Use the same role N times when the work is generation-bound rather than judgment-sensitive.",
    ),
    (
        "After all Phase B candidates complete, choose one model from the `arena cross-judge pool` line in `~/.cursor/rules/pstack-models.mdc`. If the rule or that line is missing, choose from `claude-opus-5-5-xhigh` and `grok-4.7-xhigh-fast`. Spawn one readonly judge subagent. The judge is never from the parent's family, as Phase A step 3 defines families. Try only the entries from another family, in pool order. An `auto` or `inherit-parent` entry is the parent model, so it never judges. With the default pool, a Claude parent gets `grok-4.7-xhigh-fast`. A parent from any other family gets `claude-opus-5-5-xhigh` first. If the Task tool rejects an entry, use a valid slug of the same model at the closest level or speed from the error message, or move to the next entry when there is none. If no entry from another family runs, try the default pool's entries from another family the same way. If none of those runs, skip the judge, pick the base alone in Phase D, and say so. If you do not know the parent's model, try the pool's real slugs in pool order and say that the family check did not run.",
        "After all Phase B candidates complete, use the `arena cross-judge pool` seats. If the pool is unset, its seats are `pstack:judgment` and `pstack:general`. Spawn one readonly judge subagent. The judge must not run on the parent's own model, so skip a seat that resolves to it. With the default seats, try `pstack:general` first when the parent runs on `judgment`, and `pstack:judgment` first otherwise. If a seat is rejected, move to the next seat. If no seat from another model runs, skip the judge, pick the base alone in Phase D, and say so. If you do not know the parent's model, try the seats in order and say that the diversity check did not run.",
    ),
    # pistack-architect
    (
        "If the rule or that line is missing, use `claude-opus-5-5-xhigh` and `grok-4.7-xhigh-fast`. Alias and rejected entries follow the runner rules in the **arena** skill's Phase A.",
        "If the rule or that line is missing, run one seat on `pstack:judgment` and one on `pstack:general`. Inherited and rejected seats follow the runner rules in the **arena** skill's Phase A.",
    ),
    # pistack-how
    (
        "Explorers use the `how explorer` line in the `pstack-models.mdc` rule (default `grok-4.7-xhigh-fast`), and every explainer uses the `how explainer` line (default `claude-opus-5-5-xhigh`). Set `model` to that line's value, or to the default if the rule or the line is missing. Leave `model` unset when the value is `auto` or `inherit-parent`. If the Task tool rejects a slug, use the default and say so. If it rejects the default, use the closest valid slug of the same family from its error message.",
        "Explorers run as `pstack:general`, and every explainer runs as `pstack:judgment`. The adapter picks each role's model and thinking, so omit `model` only when the role inherits. If a delegation rejects the role, report it instead of trying another model.",
    ),
    # pistack-why
    (
        "`model`: the `why investigators` line, default `grok-4.7-xhigh-fast`.",
        "`model`: `pstack:general`.",
    ),
    (
        "`model`: the `why synthesizer` line, default `claude-opus-5-5-xhigh`.",
        "`model`: `pstack:judgment`.",
    ),
    # pistack-swarm
    (
        "3. Pick the worker model from the `swarm workers` line in `~/.cursor/rules/pstack-models.mdc`. If the rule or that line is missing, use `grok-4.7-xhigh-fast`. For `auto` or `inherit-parent`, omit `model` so the workers run on the parent model. If the Task tool rejects a slug, use the default and say so. If it rejects the default, use the closest valid slug of the same family from its error message.",
        "3. Run the workers as `pstack:general`, or omit `model` when that role inherits so they run on the parent model. If a delegation rejects the role, report it instead of trying another model.",
    ),
    # pistack-reflect
    (
        "Each reviewer and the synthesizer name a role line in the `pstack-models.mdc` rule and a default. Set `model` to that line's value, or to the default if the rule or the line is missing. Leave `model` unset when the value is `auto` or `inherit-parent`. If the Task tool rejects a slug, use the default and say so. If it rejects the default, use the closest valid slug of the same family from its error message.",
        "Each reviewer and the synthesizer name a role, passed as `pstack:<role>`, and the adapter picks its model and thinking. Omit `model` when the role inherits. If a delegation rejects the role, report it instead of trying another model.",
    ),
    (
        "| Lens | Role line | Default `model` | Prompt template |\n"
        "|---|---|---|---|\n"
        "| Judgment | `reflect judgment, divergent, synthesizer` | `claude-opus-5-5-xhigh` | `references/judgment-reviewer.md` |\n"
        "| Tooling | `reflect tooling` | `grok-4.7-xhigh-fast` | `references/tooling-reviewer.md` |\n"
        "| Divergent | `reflect judgment, divergent, synthesizer` | `claude-opus-5-5-xhigh` | `references/divergent-reviewer.md` |",
        "| Lens | `model` | Prompt template |\n"
        "|---|---|---|\n"
        "| Judgment | `pstack:judgment` | `references/judgment-reviewer.md` |\n"
        "| Tooling | `pstack:general` | `references/tooling-reviewer.md` |\n"
        "| Divergent | `pstack:judgment` | `references/divergent-reviewer.md` |",
    ),
    (
        "`model` from the `reflect judgment, divergent, synthesizer` line (default `claude-opus-5-5-xhigh`)",
        "`model` set to `pstack:judgment`",
    ),
    (
        '- "we renamed `gpt-4` to `gpt-4o` in `encodingForModel`"',
        '- "we renamed `model-v1` to `model-v2` in `encodingForModel`"',
    ),
    # pistack-poteto-mode
    (
        "explicit model per role (configurable via `/setup-pstack`. Defaults `grok-4.7-xhigh-fast` for code, `claude-opus-5-5-xhigh` for prose and judgment)",
        "an explicit role for every spawn, passed as `pstack:<role>` (configure the roles with `/skill:pistack-setup`; code roles default to `pstack:feature`, prose and judgment to `pstack:judgment`)",
    ),
    (
        "go to your strongest judgment model (`claude-opus-5-5-xhigh`)",
        "go to `pstack:strongest-judgment`",
    ),
    (
        "Per-role lines in the `/setup-pstack` rule override these defaults and the model choices in the routed skills",
        "The role table configured by `/skill:pistack-setup` overrides these defaults and the role choices in the routed skills",
    ),
    (
        "A role with no line keeps its default, and a role line of `inherit-parent` or `auto` runs that role on the parent chat model (omit Task `model`).",
        "A role with no entry inherits the parent session's model and thinking.",
    ),
    (
        "Each code playbook's configured model comes from its line (`feature, refactoring`, `bug-fix`, `perf-issue`, or `hillclimb`), and the hardest changes read `hardest tasks`. Prose and judgment read `judgment and prose`.",
        "Each code playbook names its own role (`feature` or `refactoring`, `bug-fix`, `perf-issue`, `hillclimb`), the hardest changes use `strongest-judgment`, and prose and judgment use `judgment`.",
    ),
    (
        "**Match the model to the job.** Before each spawn, start from the role's line or default and pick the reasoning level and speed the job needs. The `/setup-pstack` budget sets each role's starting level, xhigh by default. Raise it one step, up to max, for the hardest or subtlest work. Lower it one step for judgment and two or more steps for routine work. Use fast mode only when the job is urgent, meaning CI or trunk is red or a person is blocked on the result right now. Otherwise use standard speed, the same slug without `-fast`. Verification is the exception and stays on the `swarm workers` model and speed (`grok-4.7-xhigh-fast` by default). Change only the effort level and whether the slug is fast, and keep the family the role names, so a diverse panel stays diverse. If the family has no slug at that level and speed, use its nearest slug. A role on `auto` or `inherit-parent` stays on the parent model. If the Task tool rejects the adjusted slug, do not try another adjusted slug. Use the role's line or default and say so. If the Task tool rejects that too, continue with the calling skill's fallback. A slug counts as rejected once a Task error says that the model is not valid, or leaves the slug out of its list of valid slugs. Never pass a rejected slug, and skip any fallback whose slug is already rejected. When the calling skill has no fallback, use the closest valid slug of the role's family from the error's list of valid slugs, or omit `model` so the subagent runs on the parent model when the list has none. When the calling skill's fallback runs out of slugs without saying what to do next, omit `model` too. Say so in both cases.",
        "**Match the thinking level to the job.** Before each spawn, start from the role's configured thinking level and move it along `max`, `xhigh`, `high`, `medium`, `low`, `minimal`, `off`. Raise it one step for the hardest or subtlest work, and lower it for routine work. Keep the role's model family, so a diverse panel stays diverse. A role that inherits stays on the parent model and thinking. Verification is the exception: keep it on `pstack:general`. If a delegation is rejected, do not try another model; report the failure and name the role that was rejected.",
    ),
    # pistack-poteto-mode playbooks
    ("using your configured bug-fix model (default `grok-4.7-xhigh-fast`)", "using `pstack:bug-fix`"),
    ("using your configured feature model (default `grok-4.7-xhigh-fast`)", "using `pstack:feature`"),
    ("using your configured hillclimb model (default `grok-4.7-xhigh-fast`)", "using `pstack:hillclimb`"),
    ("using your configured perf-issue model (default `grok-4.7-xhigh-fast`)", "using `pstack:perf-issue`"),
    ("using your configured refactoring model (default `grok-4.7-xhigh-fast`)", "using `pstack:refactoring`"),
    ("on the `swarm workers` model (default `grok-4.7-xhigh-fast`)", "on `pstack:general`"),
    # generic cleanup, last
    (
        "Pick each subagent's reasoning level and fast or standard speed for the job",
        "Pick each subagent's thinking level for the job",
    ),
]

# The adapter's own Pi-native skill bodies. Its examples must not teach a model id.
ADAPTER_REWRITES = [
    (
        "`PISTACK_MODELS=feature=anthropic/claude-sonnet-4-5:medium,bug-fix=openai/gpt-5:high`. The",
        "`PISTACK_MODELS=feature=<provider>/<model-a>:medium,bug-fix=<provider>/<model-b>:high`. The",
    ),
    (
        "`feature=anthropic/claude-sonnet-4-5:high|openai/gpt-5:high`. A panel's entries are separated by spaces, as",
        "`feature=<provider>/<model-a>:high|<provider>/<model-b>:high`. A panel's entries are separated by spaces, as",
    ),
    (
        "in `PISTACK_MODELS='arena-runners=anthropic/claude-sonnet-4-5:high openai/gpt-5:high'`. The environment wins",
        "in `PISTACK_MODELS='arena-runners=<provider>/<model-a>:high <provider>/<model-b>:high'`. The environment wins",
    ),
    (
        '- `include`, a list of patterns a model must match, such as `["gpt-*"]` for GPT only.',
        '- `include`, a list of patterns a model must match, such as `["glm-*"]` for one model family only.',
    ),
    (
        '- `exclude`, a list of patterns no model may match, such as `["*claude*"]` for no Claude, including Bedrock-style ids.',
        '- `exclude`, a list of patterns no model may match, such as `["*gemini*"]` for no Gemini, including provider-prefixed ids.',
    ),
]

# Upstream skills the adapter replaces wholesale, so their bodies never generate.
REPLACED_SKILLS = {"setup-pstack", "status"}

# A Cursor model slug left behind after the rewrite table.
SLUG = re.compile(r"\b(?:claude|grok|gpt|gemini|composer|cursor-grok)-[0-9]")

BLOCK_START = "// pi-pstack-models: start"
BLOCK_END = "// pi-pstack-models: end"

GENERATE = pkg / "src" / "generate.ts"
SETUP = pkg / "adapter-skills" / "setup.md"


def table_block() -> str:
    rows = ",\n".join(
        "  [" + json.dumps(old) + ", " + json.dumps(new) + "]" for old, new in REWRITES
    )
    head = """// pi-pstack-models: start
/**
 * Cursor model slugs in the upstream pstack bodies, replaced with Pi role references.
 * Upstream falls back to `claude-opus-5-5-xhigh` and `grok-4.7-xhigh-fast` when no Cursor rule
 * exists, and Pi never has that rule. A pstack role is passed as `pstack:<role>`, and the adapter
 * resolves it to the role's model and thinking, so no body names a model.
 * Generated by patches/pi-pstack-models.sh; edit that script, not this table.
 */
const PI_MODEL_REWRITES: ReadonlyArray<readonly [string, string]> = [
"""
    tail = """
];

/** Replaces Cursor model slugs and effort words with Pi role references. */
function piNeutralizeModels(text: string): string {
  let result = text;
  for (const [from, to] of PI_MODEL_REWRITES) result = result.split(from).join(to);
  return result;
}
// pi-pstack-models: end"""
    return head + rows + tail


def apply(path: Path, old: str, new: str, label: str) -> str:
    """Returns 'already', 'patched', 'dry', or 'missing'."""
    text = path.read_text()
    # `new` may contain `old` (the copy hook wraps the original two lines), so check
    # the post-patch marker first.
    if new in text:
        return "already"
    if old not in text:
        return "missing"
    if check_only:
        return "missing"
    if dry_run:
        return "dry"
    path.write_text(text.replace(old, new, 1))
    return "patched"


problems = []
changed = False

# 1. The rewrite table inside generate.ts, so every generated body and every copied
#    Markdown file goes through it.
if not GENERATE.is_file():
    print(f"pi-pstack-models: {GENERATE} is missing; the package layout changed.", file=sys.stderr)
    sys.exit(1)

text = GENERATE.read_text()
block = table_block()
if BLOCK_START in text and BLOCK_END in text:
    updated = re.sub(
        re.escape(BLOCK_START) + r".*?" + re.escape(BLOCK_END), lambda _m: block, text, count=1, flags=re.S
    )
    if updated == text:
        print("pi-pstack-models: generate.ts rewrite table already patched")
    elif check_only:
        print("pi-pstack-models: generate.ts rewrite table is NOT patched", file=sys.stderr)
        sys.exit(1)
    elif dry_run:
        print("pi-pstack-models: would update the rewrite table in generate.ts")
        changed = True
    else:
        GENERATE.write_text(updated)
        print("pi-pstack-models: updated the rewrite table in generate.ts")
        changed = True
else:
    anchor = "interface WrapperInput {"
    if anchor not in text:
        print("pi-pstack-models: could not find the WrapperInput anchor in generate.ts.", file=sys.stderr)
        sys.exit(1)
    if check_only:
        print("pi-pstack-models: generate.ts is NOT patched", file=sys.stderr)
        sys.exit(1)
    if dry_run:
        print("pi-pstack-models: would insert the rewrite table into generate.ts")
    else:
        GENERATE.write_text(text.replace(anchor, block + "\n\n" + anchor, 1))
        print("pi-pstack-models: inserted the rewrite table into generate.ts")
    changed = True

# 2. Route the body through it, and rewrite copied Markdown support files.
BODY_OLD = (
    '  return `${lines.join("\\n")}${BODY_START}\\n${input.body}'
    '${input.body.endsWith("\\n") ? "" : "\\n"}${footer(input)}`;'
)
BODY_NEW = (
    "  const body = piNeutralizeModels(input.body);\n"
    '  return `${lines.join("\\n")}${BODY_START}\\n${body}'
    '${body.endsWith("\\n") ? "" : "\\n"}${footer(input)}`;'
)
COPY_OLD = """      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(from, to);"""
COPY_NEW = """      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(from, to);
      if (to.endsWith(".md")) {
        const original = readFileSync(to, "utf8");
        const rewritten = piNeutralizeModels(original);
        if (rewritten !== original) writeFileSync(to, rewritten, "utf8");
      }"""
HEADER_COMMENT_OLD = "<!-- Generated by pi-pstack-adapter. Everything after this block is the upstream pstack body, unchanged. -->"
HEADER_COMMENT_NEW = "<!-- Generated by pi-pstack-adapter. Everything after this block is the upstream pstack body, with Cursor model slugs replaced by role references. -->"
HEADER_NOTE_OLD = "The body names Cursor tools, model slugs, and paths. Read [host mapping](../../adapter/host-mapping.md) for the Pi equivalent, and [skill names](../../adapter/skill-names.md) for the Pi name of any pstack skill it references."
HEADER_NOTE_NEW = (
    "The body names Cursor tools and paths, and Cursor effort and speed rules that Pi has no "
    "equivalent for. Its Cursor model slugs were replaced with \\`pstack:<role>\\` references, so "
    "pass the role and never a model slug. Read [host mapping](../../adapter/host-mapping.md) for "
    "the Pi equivalent of everything else, and [skill names](../../adapter/skill-names.md) for the "
    "Pi name of any pstack skill it references."
)

for label, old, new in (
    ("body rewrite hook", BODY_OLD, BODY_NEW),
    ("support-file rewrite hook", COPY_OLD, COPY_NEW),
    ("header comment", HEADER_COMMENT_OLD, HEADER_COMMENT_NEW),
    ("header note", HEADER_NOTE_OLD, HEADER_NOTE_NEW),
):
    state = apply(GENERATE, old, new, label)
    if state == "missing":
        problems.append(label)
    elif state in ("patched", "dry"):
        changed = True
        print(f"pi-pstack-models: {label} {state}")
    else:
        print(f"pi-pstack-models: {label} already patched")

# 3. The adapter's own setup examples.
for old, new in ADAPTER_REWRITES:
    state = apply(SETUP, old, new, "setup.md example")
    if state == "missing":
        problems.append("setup.md example: " + old[:48])
    elif state in ("patched", "dry"):
        changed = True
        print(f"pi-pstack-models: setup.md example {state}")
    else:
        print("pi-pstack-models: setup.md example already patched")

if problems:
    print(
        "pi-pstack-models: could not find the expected text for "
        + "; ".join(problems)
        + ". The upstream release or the adapter changed; re-derive patches/pi-pstack-models.sh.",
        file=sys.stderr,
    )
    sys.exit(1)

# 4. Verify the table against the content that will actually be generated: a slug the
#    table does not cover would ship as a concrete Cursor model id.
checkouts = sorted(cache.glob("checkouts/*/pstack/skills")) if cache.is_dir() else []
leftovers = []
stale = []
if checkouts:
    skills_root = checkouts[-1]
    scanned = []
    for path in sorted(skills_root.rglob("*.md")):
        if path.relative_to(skills_root).parts[0] in REPLACED_SKILLS:
            continue
        scanned.append(path.read_text())
    adapter_dir = pkg / "adapter-skills"
    if adapter_dir.is_dir():
        for path in sorted(adapter_dir.glob("*.md")):
            scanned.append(path.read_text())
    joined = "\n".join(scanned)
    for old, new in REWRITES:
        if old not in joined:
            stale.append(old[:64])
    for text in scanned:
        result = text
        for old, new in REWRITES + ADAPTER_REWRITES:
            result = result.replace(old, new)
        for match in SLUG.finditer(result):
            line_start = result.rfind("\n", 0, match.start()) + 1
            line_end = result.find("\n", match.end())
            line = result[line_start : line_end if line_end >= 0 else len(result)]
            leftovers.append(f"{match.group(0)}: {line.strip()[:140]}")
if leftovers:
    print("pi-pstack-models: these model slugs survive the rewrite table:", file=sys.stderr)
    for item in sorted(set(leftovers)):
        print("  " + item, file=sys.stderr)
    print(
        "pi-pstack-models: add a rewrite entry for each before trusting the generated skills.",
        file=sys.stderr,
    )
    sys.exit(1)
if stale:
    print(
        "pi-pstack-models: warning: "
        + str(len(stale))
        + " rewrite entries matched nothing (upstream rewording); no slug is left, so this is informational",
        file=sys.stderr,
    )

if check_only:
    print("pi-pstack-models: patch is applied")
    sys.exit(0)

if dry_run:
    print("pi-pstack-models: dry run, nothing written")
    sys.exit(0)

# The generated wrappers are content-addressed over the package source, so a patched
# generate.ts makes a fresh directory on the next Pi start. Drop the stale ones.
if changed and cache.is_dir() and (cache / "generated").is_dir():
    for entry in (cache / "generated").iterdir():
        if entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()
    print("pi-pstack-models: cleared generated wrappers; they regenerate on the next Pi start.")
PY

if [[ $status -ne 0 ]]; then
  exit $status
fi
