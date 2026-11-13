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

`GITHUB_TOKEN` в окружении этой машины — **ключ разработчика для установки пакетов** (composer),
а не личная учётная запись. `gh` берёт `GITHUB_TOKEN` раньше сохранённого логина, поэтому
`gh pr create` / `gh api …/reviews` / `gh pr comment` без снятия переменной создают артефакты
от служебного аккаунта. Это уже случалось (PR #142 в msb-calculator-api, 13.11.2026).

## Правило

PR, ревью и комментарии, у которых автором должен быть человек, создаются только от личной
учётной записи — `denis-trofimov`. Коммиты отдельно: их автор берётся из `~/.gitconfig`
(`Denis Trofimov <silaradost@yandex.ru>`), `GITHUB_TOKEN` на них не влияет.

## Как

```bash
env -u GITHUB_TOKEN gh auth status          # должно быть: denis-trofimov
env -u GITHUB_TOKEN gh pr create …          # PR от человека
env -u GITHUB_TOKEN gh api repos/<o>/<r>/pulls/<N>/reviews -X POST --input …   # ревью от человека
```

- Перед публикацией любого артефакта в GitHub — проверить логин (`gh auth status` без переменной)
  или автора готового объекта (`gh pr view <N> --json author`).
- Автор PR в GitHub не меняется: ошибочно оформленный PR закрыть с пояснением и пересоздать
  от личной учётки (ветка и коммиты те же).
- Не печатать значения токенов в чат, логи и файлы репозитория.
