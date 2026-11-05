---
name: redmine-cli
description: >-
  Drive Redmine via the `redmine` CLI (aarondpn/redmine-cli) against
  https://redmine.msb-leasing.ru for msb-lk work. Use when the user mentions Redmine,
  redmine-cli, ticket, issue, задача, тикет, time entry, wiki, tags/теги
  (redmineup_tags / tag_list), Textile/описание, Internal error / 500 на
  странице issue, or asks to list/create/update/close/search issues, log time,
  or fetch attachments from Redmine (including #11301 / schedule form QA).
---

# Redmine CLI (msb-lk → redmine.msb-leasing.ru)

Project skill for **msb-lk**. Binary: `~/.local/bin/redmine` (v2.x). Server: `https://redmine.msb-leasing.ru`.

Do **not** invent subcommands or flags — run `redmine <cmd> --help`. Upstream patterns: [aarondpn/redmine-cli SKILL](https://github.com/aarondpn/redmine-cli/blob/main/skills/redmine-cli/SKILL.md).

## Auth (local)

Credentials live in env (not `~/.redmine-cli.yaml`):

- `REDMINE_SERVER`, `REDMINE_API_KEY`, `REDMINE_AUTH_METHOD=apikey`
- Defined in `~/.profile` and `~/.bashrc`

**Non-interactive agent shells** do not load `~/.bashrc` (early `return`). Before any `redmine` call:

```bash
eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
# fallback if only in bashrc:
# eval "$(grep -E '^export REDMINE_' "$HOME/.bashrc")"
```

Smoke check: `redmine my-account get -o json` (expect 200 / user object).

**Never** print, log, or paste `REDMINE_API_KEY` or `api_key` from JSON responses. Redact if quoting output.

If `redmine` is missing:

```bash
VER=v2.11.0   # pin a release tag — do not use main
curl -fsSL "https://raw.githubusercontent.com/aarondpn/redmine-cli/${VER}/install.sh" \
  -o /tmp/redmine-install.sh
# skim the script, then:
bash /tmp/redmine-install.sh
```

## Critical rules

- Parse programmatically with **`-o json`** (stdout only); use `jq`, not ad-hoc regex/Python.
- Default list limit is 100; use **`--limit 0`** for all rows.
- Name flags (`--project`, `--tracker`, `--status`, `--priority`, `--assignee`, …) resolve by name; **`--assignee me`** = current user.
- `issues list` defaults to **open**; use `--status closed`, `--status "*"`, or a status name.
- `issues update` sends **only** flags you pass.
- Dates: `--due-date`, `--from`, `--to` accept literal `today`.
- Versions: prefer `redmine versions list --open` before assigning.
- On failure twice: stop, run `--help`, ask the user — do not invent flags.
- **Описания и notes — только Textile** (не Markdown). Нарушение → HTML **500** при живой странице, API при этом часто **200** (см. ниже).

## Description / notes (Textile) — частая причина HTML 500

Сервер Redmine (`redmine.msb-leasing.ru`) рендерит `description` и `notes` через **Textile (RedCloth)**. API `GET/PUT /issues/<id>.json` может быть **200/204**, а `GET /issues/<id>` (HTML) — **500 Internal error**. Уже ловили многократно (#13954 и раньше).

### Перед create / update description или comment

1. Пиши **Textile**, не Markdown.
2. После записи **обязательно** проверь HTML:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
  "${REDMINE_SERVER}/issues/<id>"
# ожидай 200; если 500 — чини Textile, не создавай новую задачу
```

### Запрещено в `@code@` spans (ломает RedCloth → 500)

- Скобки: `@Foo::bar()@` → пиши `@Foo::bar@` или `@Foo::bar@()` вне span.
- Вложенный Markdown: `**жирный**`, `*(курсив)*` рядом с `@...@`.
- Непарные `@` (нечётное число на строке / в тексте).

```text
Плохо:  @DiscountFactorChainBasePaymentStrategy::balance()@
Хорошо: @DiscountFactorChainBasePaymentStrategy::balance@

Плохо:  **Эта задача** / *(отвергнуто)* рядом с @code@
Хорошо: *Эта задача* / (отвергнуто) — Textile emphasis без Markdown
```

### Разрешённый Textile (кратко)

- Заголовки: `h2.`, `h3.`
- Списки: `*`, вложенные `**`
- Код/моно: `@identifier@` (без `()` внутри)
- Акцент: `*текст*` (не `**текст**` из Markdown)
- Ссылки на задачи: `#12345`

### Диагностика «Internal error» на issue

1. `curl` HTML → 500, JSON API → 200 ⇒ почти наверняка Textile или `tag_list`.
2. Сначала проверь `tag_list` (массив строк — см. ниже).
3. Затем описание: убери `()` из `@...@`, замени Markdown `**`/`*(...)*` на Textile, выровняй пары `@`.
4. `PUT` description → снова проверь HTML **200**. Новых задач не создавать.

## Common workflows

### Read issue (with context)

```bash
redmine issues get <id> --journals --attachments --relations -o json
```

URL for user: `https://redmine.msb-leasing.ru/issues/<id>` or `redmine issues open <id>`.

### List / search

```bash
redmine issues list --project <id-or-name> --assignee me -o json
redmine issues list --status "*" --limit 0 -o json
redmine search "<query>" -o json
```

### Create / update / comment

```bash
redmine issues create --project <p> --subject "..." --tracker <t> -o json
redmine issues update <id> --status "<name>"   # only changed fields
redmine issues comment <id> --notes "..."
redmine issues close <id>
```

After create: give the user the issue URL.

### Ambiguous tracker/status/priority

1. `redmine trackers list -o json` / `statuses list` / etc.
2. Confirm with the user if several matches.
3. Then run the mutating command.

### Users without admin

Resolving users **by name** needs admin. Prefer `--assignee me`, or take IDs from `issues list` / `memberships list --project … -o json`.

For yourself: `--assignee me`.

### Tags (redmineup_tags)

Plugin: **redmineup_tags** (`issue[tag_list]`). CLI has **no** `--tag` flag — set tags via REST API.

**Critical:** `tag_list` must be a **JSON array of strings**. A plain string (or `redmine api -F 'issue[tag_list]=…'`) often yields **500**. Correct:

```json
{"issue": {"tag_list": ["Калькулятор-API"]}}
```

Create with tag (and optional parent/assignee) in one request:

```bash
eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
curl -sS -X POST -H "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"issue":{
    "project_id":5,"tracker_id":2,"subject":"…",
    "parent_issue_id":11301,"assigned_to_id":127,"priority_id":3,
    "tag_list":["Калькулятор-API"],
    "description":"…"
  }}' \
  "${REDMINE_SERVER}/issues.json"
```

Update tags on an existing issue (HTTP **204** on success):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X PUT \
  -H "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"issue":{"tag_list":["Калькулятор-API"]}}' \
  "${REDMINE_SERVER}/issues/<id>.json"
```

Notes:

- JSON `GET /issues/<id>.json` usually **omits** `tag_list` / `tags` — verify tags in HTML (`Теги:`) or the issue page.
- Common calculator tag: **`Калькулятор-API`**.
- Multiple tags: `"tag_list": ["Калькулятор-API", "UI"]`.

### Attachments (required when present)

If an issue has attachments (esp. images), **download and inspect** before answering:

```bash
redmine issues get <id> --attachments -o json
redmine attachments download <att-id> -d /tmp/redmine-<id>/
# or all:
redmine issues get <id> --download-attachments /tmp/redmine-<id>/
```

Then `Read` image/files. Do not guess from description alone.

### Time

```bash
redmine time list --issue <id> -o json
redmine time log --issue <id> --hours 1 --activity "<name>" --date today
```

## Top-level commands

`issues`, `attachments`, `queries`, `projects`, `time`, `versions`, `files`, `memberships`, `users`, `my-account`, `groups`, `roles`, `categories`, `trackers`, `statuses`, `custom-fields`, `search`, `auth`, `wiki`, `api`, `config`, `mcp`.

## Communication

- Respond to the user in **Russian** unless they write in English.
- Prefer issue links `https://redmine.msb-leasing.ru/issues/<id>`.
- Do not commit secrets; do not write API keys into repo files or plans.
