# Delegation model policy

Pi knows more model ids than this machine can reach. A listing from `pstack_adapter models`,
`subagent({ action: "list" })`, or any catalog is **not** proof that the provider serves a model.
Two families are blocked here, and a fan-out that picks one loses the run.

## Allowed

- `deepseek/*` and `z-ai/glm-*`, on any configured provider (`openrouter/...`, `routerai/...`).

## Blocked

- `google/*`, and any `gemini-*` id.
- `openai/*`, and any `gpt-*`, `o3`, or `o4` id.

Never delegate to a blocked family, never retry one after it fails, and never offer one as an
option. Anything outside the allowed list, `anthropic/*` included, needs the user's explicit
approval first.

## Rules

- Never pass a Cursor model slug: `claude-opus-5-5-xhigh`, `grok-4.7-xhigh-fast`, `composer-*`,
  `cursor-grok-*`. They do not exist in this installation. Upstream pstack bodies named them; the
  local `patches/pi-pstack-models.sh` rewrites them to role references.
- In pstack skills, pass `pstack:<role>` and let the adapter resolve the model and thinking. Never
  pass a panel role (`arena-runners`, `arena-cross-judge-pool`, `architect-runners`,
  `interrogate-reviewers`) as a model; expand the panel into its seats.
- An ad-hoc fan-out that wants model diversity picks from the allowed list only. Do not reach into
  a provider catalog for a "different family".
- When a delegation fails on its model, report the failure and name the model or role. Do not
  silently substitute another model.

# GitHub: авторство артефактов

`GITHUB_TOKEN` в окружении — ключ разработчика для composer, не личная учётная запись. `gh` на
этой машине обёрнут: `~/.local/bin/gh` (в `PATH` раньше `/usr/bin/gh`) снимает переменную и
работает от `denis-trofimov`, поэтому обычный `gh …` безопасен. Служебный аккаунт — только
осознанно: `GH_AS_DEV=1 gh …`. Обёртка обойдена (`/usr/bin/gh`, чужой PATH) — снимать явно:
`env -u GITHUB_TOKEN gh …`.

- Авторство не угадывается: не ясно, от чьего имени публикуется артефакт, — спросить. Дефолт —
  `denis-trofimov`.
- `gh pr` / `gh issue` / `gh api` — только с явным репозиторием: `cd` в него или `-R owner/repo`,
  иначе `gh` молча работает с тем репозиторием, где оказался `cwd`.
- `author` / `mergedBy` / `mergedAt` подтверждают учётную запись, а не человека: кто именно
  смержил — из истории сессии. Автор PR не меняется: ошибочный PR закрыть с пояснением и
  пересоздать от личной учётки (ветка и коммиты те же).
- Перед публикацией — `gh auth status` → `denis-trofimov`; токены не печатать в чат, логи и файлы.

# Прокси и внутренние хосты

В сессии выставлены `HTTP_PROXY`/`HTTPS_PROXY` (xray, `127.0.0.1:10808`), а внутренние хосты
(`*.msb-leasing.ru`, `192.168.*`, `10.*`, `msb-stream-*`) должны идти напрямую. Сначала — прямой
вызов; упал с TLS/таймаутом — `msb-net <команда>` (снимает прокси и ставит `NO_PROXY`).
`export NO_PROXY=… && unset HTTP_PROXY …` руками перед каждым вызовом не повторять.

# Мерж и релиз

Репозитории с `.github/workflows/release-please.yml` (`msb-calculator-api`) — перед мержем PR
скилл `release-please`: один мерж — один релиз.
