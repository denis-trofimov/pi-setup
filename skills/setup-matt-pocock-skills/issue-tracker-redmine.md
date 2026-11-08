# Issue tracker: Redmine

Issues and specs for this repo live in Redmine on `$REDMINE_SERVER` (this machine points at `https://redmine.msb-leasing.ru`), in the project `МСБ-лизинг`. Use the `redmine` CLI for all operations; it wraps the REST API and handles auth.

_Local template: this file is not part of upstream `mattpocock/skills` (see its `.out-of-scope/mainstream-issue-trackers-only.md`). It lives in your own `pi-setup` repo._

## Session setup

Agent shells often skip `~/.bashrc`, so the credentials may be missing. Bootstrap them once per session, then smoke-test:

```bash
eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
redmine my-account get -o json | jq -r '.user.login'
```

Never print, log, or paste `REDMINE_API_KEY`, and redact it as `<REDACTED>` if you quote output. For reads, add the global `--read-only` flag, which refuses every mutating request.

## Conventions

Name flags (`--project`, `--tracker`, `--status`, `--priority`, `--assignee`) resolve by name; numeric IDs also work. Confirm names with `redmine projects list -o json`, `redmine trackers list -o json`, and `redmine statuses list -o json`. Parse everything with `-o json` and `jq`, never with ad-hoc text munging.

- **Create an issue**:

  ```bash
  redmine issues create --project "МСБ-лизинг" --tracker "Разработка" \
    --subject "<one-line title>" \
    --description "$(cat <<'TEXTILE'
h2. What

Textile body, markers at column 0.
TEXTILE
  )" -o json | jq -r '.issue.id'
  ```

  Printed id gets turned into the URL `$REDMINE_SERVER/issues/<id>` for the user.
- **Read an issue**: `redmine issues get <n> --journals --relations --attachments -o json`.
- **List issues**: `redmine issues list --project "МСБ-лизинг" --status open --limit 0 -o json`. `--status` defaults to open (`closed`, a status name, or `*` for everything), the default limit is 100 so pass `--limit 0` for all rows, and `--filter subject='~login'` reaches raw Redmine filters.
- **Child issues**: `--parent <n>` on create makes the new issue a child; `--parent <n>` on list returns a parent's children.
- **Blocking**: native issue relations, declared from the child's side:

  ```bash
  redmine issues relations add <child> --to <blocker> --type blocked
  ```

  Read them with `redmine issues get <n> --relations -o json`, which returns `relations[]` as `{issue_id, issue_to_id, relation_type}`. A ticket is blocked by the issue in `issue_to_id` when its own `relation_type` is `blocked`, and by `issue_id` when the other side recorded `blocks`. A ticket is unblocked when every blocker sits in a closed status (`is_closed` in `redmine statuses list`; here `Закрыта` and `Отклонена`).
- **Comment on an issue**: `redmine issues comment <n> -m "<Textile>"`.
- **Triage tags**: Redmine has no labels. The tags plugin (redmineup_tags) is enabled, so the canonical triage roles live in `tag_list`. The CLI has no `--tag` flag, so write tags over REST with an explicit JSON array (a bare string returns HTTP 500):

  ```bash
  redmine api /issues/<n>.json -X PUT --input - <<'JSON'
  {"issue":{"tag_list":["needs-triage"]}}
  JSON
  ```

  JSON responses omit `tag_list`, so read tags from the HTML page (`Теги:`) or `$REDMINE_SERVER/issues/<n>`.
- **Statuses as triage state**: this server's workflow is `Новая (Бэклог)`, `В работе (спринт)`, `Ожидает дополнения`, `Ожидает тестирование`, `Ожидает размещение на боевом`, `Контроль ПМ`, `Закрыта`, `Отклонена`. Where the workflow already encodes a role, prefer the status (`Ожидает дополнения` for `needs-info`); otherwise apply the tag. `triage-labels.md` records the mapping.
- **Close**: `redmine issues close <n> --note "<Textile>"`. For `wontfix`, use `redmine issues update <n> --status "Отклонена" --note "<Textile>"` so the tracker records the reason it was rejected.
- **Attachments**: `redmine issues get <n> --attachments -o json`, then `redmine attachments download <att-id> -d /tmp/redmine-<n>/`. Download and inspect images before answering anything that depends on them.

## Descriptions and notes are Textile, not Markdown

Redmine here renders `description` and `notes` through Textile. Malformed Textile returns HTTP 500 on the HTML page while the JSON API still answers 200/204, which is the failure mode to guard against:

- Headings `h2.` / `h3.`, lists `*` and `**`, emphasis `*text*` (never Markdown `**text**`), mono `@identifier@`.
- No parentheses inside `@...@` spans (`@Foo::bar@`, not `@Foo::bar()@`), no Markdown bold or italics next to a code span, and never an unpaired `@` on a line.
- Link issues as `#12345`.
- After every write, check the page renders: `curl -sS -o /dev/null -w '%{http_code}\n' -H "X-Redmine-API-Key: ${REDMINE_API_KEY}" "${REDMINE_SERVER}/issues/<n>"` and expect 200. On 500, fix the Textile on the same issue; never create a replacement issue.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Redmine has no pull-request surface on this server, so there is nothing for `/triage` to read here. Leave this off.)_

## When a skill says "publish to the issue tracker"

Create an issue in the `МСБ-лизинг` project, with `--tracker "Разработка"` unless the work is a defect (`Ошибка`) or non-functional (`NFRs/тех. долг`). Put a link to the created issue in your reply.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above. Users normally pass the bare number or the URL.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue; **child** issues are the tickets.

- **Map**: an issue tagged `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: `--parent <map-id>` on create, tagged with its type: `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`.
- **Blocking**: `redmine issues relations add <child> --to <blocker> --type blocked`, as in **Blocking** above.
- **Frontier**: the map's open children that are unassigned and have no open blocker. First in number order wins.

  ```bash
  redmine issues list --parent <map-id> --status open --limit 0 -o json |
    jq '[.[] | select(.assigned_to == null)]'
  ```

  Then drop any child that still has a blocker in an open status, read per issue with `redmine issues get <n> --relations -o json`.
- **Claim**: `redmine issues update <n> --assignee me`, the session's first write.
- **Resolve**: `redmine issues comment <n> -m "<answer>"`, then `redmine issues close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.
