# Delegation model policy

Pi knows more model ids than this machine can reach. A listing from `subagent({ action: "list" })`
or any model catalog is **not** proof that the provider serves a model.
An OpenRouter workspace guardrail ("model cap") serves exactly 14 model ids, and a fan-out that
picks anything else loses the run with `404 ... 0 endpoints out of 14 ... guardrail restrictions`.

## Allowed

**Before delegating, read `~/.pi/agent/docs/delegation-models.md`:**
the 14 allowed ids, their prices, the cache-read ranking and the provider-routing note. Only ids
from that table are policy — a model in the local catalog is not evidence the cap serves it.

## Blocked

- Everything else, including `deepseek/deepseek-v4-pro` and `-pro-0813`. The pro tier sits outside
  the cap: it returns 404 from the guardrail, not from the model. This is what broke the project
  reviewer once already.
- `google/*`, any `gemini-*` id; `openai/*`, any `gpt-*`, `o3`, `o4` id; `anthropic/*`.
- Every `routerai/...` id that has no allowed counterpart. Each `routerai/…` id is a separate entry
  in `modelScope.allow` for the same bare slug — an `openrouter/` entry does not authorise it, and
  vice versa — see "Mirror on a machine without OpenRouter" below. An id that answers `curl` is
  still outside the policy unless the table in `~/.pi/agent/docs/delegation-models.md` carries its
  bare slug.

Never delegate to a blocked model, never retry one after it fails, and never offer one as an
option. Anything outside the table needs the user's explicit approval first.

## Mirror on a machine without OpenRouter

The gate compares the full `provider/id`, so an id is allowed only under the provider written in
`modelScope.allow`. A machine whose registry has no `openrouter` provider at all — no
`OPENROUTER_API_KEY`, empty `auth.json`, catalog under `providers.routerai` — reaches 7 of the 14
ids through RouterAI under the same bare slug, and nothing else; naming `openrouter/…` there fails
with `Unknown subagent model` before a request goes out, and `pi-models-check` reports
`no API key for provider openrouter` for all 14.

On such a machine the allow list carries the 14 `openrouter/` ids **plus** a `routerai/` mirror of
every id the local catalog serves (21 entries), `subagents.defaultModel` and every
`agentOverrides.<name>.model` name the `routerai/` form, and `strict: true` stays on. The mirror is
an id form, not a wider policy: a `routerai/` id without an allowed counterpart stays blocked, and
the check that keeps the two repo copies of the list in step (`sync.sh` → `validate_models`)
compares bare slugs, so both prefixes match the same table row. Prices are not the OpenRouter ones:
the routerai rates sit in `providers.routerai.models[].cost` of the live `models.json`.

The startup model `~deepseek/deepseek-v4-flash-latest` is not in the allow list and is not a
delegation target, so `inherit` is rejected there under `strict: true`: a workflow on such a machine
has to name a model or rely on `agentOverrides`.

## Enforcement

One hard gate, in user config; do not weaken it without the user asking.

- `~/.pi/agent/settings.json` — `subagents.modelScope` is `enforce: true, strict: true` with the
  allowed ids as the allow list — 14 `openrouter/` entries plus the `routerai/` mirror wherever the
  local provider serves the same bare slug (21 on an OpenRouter-less machine, see above) — so any
  launch naming a model outside the cap is rejected before the child starts, whoever started it
  (workflow or a bare `subagent` call). The repo example ships the same list with `strict: false`,
  so a machine whose cap differs still launches instead of refusing every call.
- `subagents.defaultModel` is `routerai/z-ai/glm-5.3-flash` on an OpenRouter-less machine and
  `openrouter/z-ai/glm-5.3-flash` where OpenRouter is configured — the same upstream model — and
  every bundled agent has an explicit `agentOverrides.<name>.model`, so a call that names no model
  lands on a capped model instead of the parent's. `inherit` passes only while the parent session
  model is itself inside the cap, which is the intended behaviour, not an exemption. For `reviewer`
  the override is `deepseek-v4.1-flash-1017`, and it is the only deepseek variant its allow list
  accepts: naming `deepseek/deepseek-v4.1-flash` (no `-1017`) passes the cap and fails the gate,
  under either provider prefix.
- `reviewer`, `oracle`, and `evidence-auditor` all default to `deepseek-v4.1-flash-1017`, and
  additionally carry a per-agent allow list, so a review cannot escalate to `glm-5.2`. Thinking:
  `reviewer` and `oracle` at `high`, `evidence-auditor` at `off` (matching a claim against a fetched
  excerpt is lookup, not dialogue, and `off` is a level deepseek-1017 actually has). `reviewer` may
  name only `glm-5.3-flash` and `deepseek-v4.1-flash-1017`: no full-strength escalation on a review
  seat. `oracle` and `evidence-auditor` also allow `glm-5.3` for a review that has to be argued at
  full strength.
- **`medium` does not exist on most allowed models, and Pi clamps it UP first, never down.**
  Under `openrouter/` the per-model levels are: `deepseek-v4.1-flash-1017` and
  `deepseek-v4-flash-vision-exp` expose `off/low/high/max`; `glm-5.3` and `glm-5.3-flash` expose
  only `low/high/max` (no `off` — there the floor is 2048 tokens, not zero); `z-ai/glm-5.2`
  exposes only `off/high/xhigh`, so even `low` becomes `high`. `clampThinkingLevel` (pi-ai
  `dist/models.js`) scans upward from the requested level and falls back down only when nothing
  above it exists, so a `medium` override on those ids silently buys the 16384-token `high` budget
  instead of 8192, and nothing surfaces it. Levels per seat must be levels the model actually has:
  `medium` is real only on `minimax-m3`, `minimax-m3.1-flash`, `ling-3.*`, `glm-4.7-flash`,
  `glm-5`, and `glm-5.1`. Under `routerai/` no mirror row carries a `thinkingLevelMap`
  (`providers.routerai.models[]` in the live `models.json`), so nothing clamps and the catalog
  proves only that the raw level is forwarded: `off` stays `off`, `medium` stays `medium`. An `off`
  pin therefore holds only while the seat stays on a model that maps it — on the `openrouter/`
  form, `evidence-auditor` may also name `glm-5.3-flash`, where `off` becomes `low`. Verify by
  running the configured pairs through `clampThinkingLevel`, not by reading the number you wrote.
- The table in `~/.pi/agent/docs/delegation-models.md` is a dated observation, not a standing
  fact. Re-verify it with `pi-models-check` (one `max_tokens: 1` request per id, exit 1 on 404)
  before trusting it after a provider or guardrail change. A 404 there is the cap, not local config.

## Rules

- Never pass a Cursor model slug: `claude-opus-5-5-xhigh`, `grok-4.7-xhigh-fast`, `composer-*`,
  `cursor-grok-*`. They do not exist in this installation.
- An ad-hoc fan-out that wants model diversity picks from the allowed list only. Do not reach into
  a provider catalog for a "different family". The families available here are `glm`, `deepseek`,
  `minimax`, and `ling`.
- **One expensive seat per workflow, and it sits at the decision, not in the fan-out.** A panel
  spends money per seat per run; the judge spends it once. Keep `glm-5.3` on the judge and run the
  seats on `glm-5.3-flash` plus a second family. Adding a third runner seat to "keep diversity"
  raises the bill — it never lowers it.
- **A one-off fan-out can cost more than a week of normal work.** On 2026-11-13, 76 calls to
  `claude-opus-5` / `claude-sonnet-5` / `gpt-5.6-sol` inside 16 minutes were $6.08 — 27% of the
  week's $22.73, at $0.05-0.16 per call. Those ids are blocked now; the replacement for such a
  comparison is `glm-5.3` + `minimax-m3`, not a search for a stronger family.
- A model that answers `curl` may still be outside the cap; only the table in
  `~/.pi/agent/docs/delegation-models.md` is policy.
- When a delegation fails on its model, report the failure and name the model or role. Do not
  silently substitute another model.

# Глобальные скиллы и агенты: источник — pi-setup

Глобальные скиллы, агенты и этот файл версионируются в `~/p/pi-setup` (`skills/`, `config/AGENTS.md`,
`extensions/`, `themes/`), доставка — PR в `denis-trofimov/pi-setup` (`main` защищён, мерж только
через PR). `~/.pi/agent` — рабочая копия: `./sync.sh` снимает её изменения в репозиторий,
`./install.sh --restore` раскладывает репозиторий обратно. Правка, сделанная только в `~/.pi/agent`,
на другой машине не появится, пока не попадёт в pi-setup.

**Правку pi-setup делают в отдельном воркдереве.** `~/p/pi-setup` — общий чекаут: ветку в нём не
переключают, потому что вторая сессия переключит её под работающей первой. Работа — воркдерево от
`origin/main`, `main` защищён и мержится только через PR:

```bash
cd ~/p/pi-setup && git fetch -q origin
git worktree add -q ../pi-setup-wt/<задача>-<слаг> -b <тип>/<задача>-<слаг> origin/main
```

Ветка — от `origin/main`, а не от текущей в общем чекауте: иначе в PR уезжает чужой коммит, если
общий чекаут стоял на чужой ветке (#15742 п.2). После мержа воркдерево убирают
(`git worktree remove ../pi-setup-wt/<имя>`), общий чекаут остаётся там, где стоял.

Воркдерево, ветку которого уже влили в базу, от живого по `git worktree list` не отличить.
`--restore` такие называет сам (`note: воркдерево … — можно убрать`); вручную —
`git merge-base --is-ancestor <tip> origin/main` для обычного слияния и `git cherry -v origin/main
<ветка>` для squash: у второго предка нет, и без `-` в первой колонке («изменение уже в базе»)
дерево выглядит не влитым.

**Issues в `pi-setup` включены** — репозиторий публичный, и замечание, дефект, задача по окружению
заводятся выпуском (`gh issue create -R denis-trofimov/pi-setup`), а не PR-ом задним числом: так видно,
что ещё не сделано, а номер выпуска стоит и в теле PR, и в сообщении коммита. Если предмет относится к
проекту, задача идёт в трекер проекта (Redmine в msb-lk), а не в репозиторий оснастки. Состояние
настройки — факт на дату, а не общее правило: `gh repo view denis-trofimov/pi-setup --json
hasIssuesEnabled`.

`./install.sh --restore` из воркдерева раскладывает на живую машину контент ветки (скиллы, агенты,
расширения); симлинки `~/.local/bin/*` при этом ведут в основное дерево, а не в воркдерево
(`bin_link_root()`). Осознанный просмотр ветки на живой машине — так и задумано; после него вернуть
состояние: `./install.sh --restore` из `~/p/pi-setup`.

Файлы политики restore обрабатывает по-разному: `docs/delegation-models.md` и `docs/session-logs.md`
перезаписываются всегда (устаревшая таблица моделей теряет запуски делегирования), а `AGENTS.md`
остаётся живой копии — она несёт собственные правки машины. Пропуск виден строкой `AGENTS.md differs
from the repo copy … leaving it` и повторяется в конце прогона блоком «Не восстановлено из
репозитория»; сам код возврата о содержимом `AGENTS.md` не говорит ничего. Забирает правку
`--copy-config`, он же перезаписывает dotfiles из `home/` и словарь ru-spellcheck, поэтому когда
разошёлся только `AGENTS.md` — дешевле его `diff` с `config/` и копия одного файла.

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
- **`-R` есть не у каждой команды.** У `pr`, `issue`, `api`, `release`, `run` — есть; у `repo view`
  репозиторий позиционный (`gh repo view owner/repo --json …`), и `-R` там даёт
  `unknown shorthand flag: 'R' in -R`. Правило «ставить `-R` везде» стоило вызова (#88 п.2).
- `author` / `mergedBy` / `mergedAt` подтверждают учётную запись, а не человека: кто именно
  смержил — из истории сессии. Автор PR не меняется: ошибочный PR закрыть с пояснением и
  пересоздать от личной учётки (ветка и коммиты те же).
- **Тело PR — через `gh api`, а не `gh pr edit`.** На этом сервере `gh pr edit <n> --body-file …` падает на
  `GraphQL: Projects (classic) is being deprecated in favor of the new Projects experience` с кодом 1, и
  тело не меняется; повторная разведка того же обхода стоила двух лишних вызовов (#15834 п.4). Рабочий
  путь — REST:

  ```bash
  python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read()}))' body.md > /tmp/body.json
  gh api -X PATCH repos/<owner>/<repo>/pulls/<n> --input /tmp/body.json --jq '.html_url'
  ```

  `--jq '.html_url'` — не украшение: без него вызов печатает весь объект PR (19 989 байт одной строкой в
  журнале #16027 — 5 % вывода инструментов сессии на подтверждение «ok»). Ссылка одной строкой — то, что
  всё равно нужно в чате (#16046 п.3).

  `--add-label` / `--remove-label` в `gh pr edit` работают — падает именно правка тела.

  Так же и создание PR: вывод в файл, в чат ссылка:

  ```bash
  rm -f /tmp/pr-create.txt
  gh pr create --base <base> --title '<title>' --body-file body.md > /tmp/pr-create.txt 2>&1
  tail -1 /tmp/pr-create.txt   # URL; остальное — ход выполнения, в контексте он не нужен
  ```

  Номер PR в имени файла не ставится: номер и есть то, что вернёт создание, поэтому
  `/tmp/pr-create-<n>.txt` может остаться от прошлого прогона, а `tail -1` по старому файлу читается
  как успех. `rm -f` перед вызовом делает само существование файла доказательством, что вызов был.
- **Ожидание CI — `gh pr checks <n> --watch`.** Одна команда вместо ручного цикла
  `for i in $(seq 1 40); do … sleep 10; done`: цикл стоит вызова на каждую итерацию, теряет код
  возврата в конвейере и не говорит, какая проверка упала. `--watch --fail-fast` выходит на первом
  падении, код возврата — состояние проверок (2026-11-21: два таких цикла подряд, по 50 секунд
  ожидания в каждом).
- Перед публикацией — `gh auth status` → `denis-trofimov`; токены не печатать в чат, логи и файлы.

# Прокси и внутренние хосты

В сессии выставлены `HTTP_PROXY`/`HTTPS_PROXY` (xray, `127.0.0.1:10808`), а внутренние хосты
(`*.msb-leasing.ru`, `192.168.*`, `10.*`, `msb-stream-*`) должны идти напрямую. Сначала — прямой
вызов; упал с TLS/таймаутом — `msb-net <команда>` (снимает прокси и ставит `NO_PROXY`).
`export NO_PROXY=… && unset HTTP_PROXY …` руками перед каждым вызовом не повторять.

Внутренний хост молчит и по TLS-рукопожатию, и по `i/o timeout` — это сначала признак того, что VPN не поднят, а
не недоступного хоста: `msb-net` снимает прокси, VPN он не поднимает. Нужный профиль — `msb-ikev2`.
Проверка одной командой — `nmcli -t -f NAME connection show --active | grep msb-ikev2`: пусто — попросить
человека поднять VPN (`nmcli connection up msb-ikev2` требует прав), а не повторять вызов. Цена обратного
порядка: в сессии #16095 три подряд `redmine` упали на `TLS handshake timeout` и `dial tcp … i/o timeout`
через `msb-net`, и ответ дала только реплика человека про VPN.

# Логи сессий

Вопросы «какая сессия взяла задачу», «что она успела» и «сколько это стоило» отвечаются готовыми
однострочниками из `~/.pi/agent/docs/session-logs.md`. Не писать под каждый из них новый скрипт: в ретро
по #15716 четыре python-скрипта писались заново, и соседние ретро (#15742, #15749) повторяли те же.

# Чтение файлов и поиск: инструмент выбирается по задаче

Порядок один и тот же во всех проектах, потому что его держит сторож `call-guard`
(`extensions/call-guard-core.mjs`), а не абзац в инструкции:

- **файл — `read`** с `offset`/`limit`: нумерация строк, обрезка вывода, дифф;
- **поиск по содержимому — `ffgrep`**, по пути — `fffind`: `ffgrep` учитывает `.gitignore` и держит
  вывод в `limit`;
- **`bash`** — когда нужен конвейер, код возврата или нестандартный `regex`;
- **`path` с именем файла без расширения не находит ничего** (#16137): `Makefile`, `Dockerfile`,
  `Vagrantfile` и даже полный путь `docker/apache/Dockerfile` дают `No matches found` на файле, где
  совпадения есть. Замер 26.11.2026: `pattern='lint-staged', path='Makefile'` — `No matches found`,
  тот же запрос с `path='**/Makefile'` — четыре совпадения, `rg -c` — пять; у `Dockerfile` так же
  (`path='docker/apache/Dockerfile'` — ноль, `path='docker/*/Dockerfile'` — есть). Работают шаблон с `*`
  (`**/Makefile`, `Make*`, `docker/*/Dockerfile`) и префикс каталога (`docker/apache`, `src/`) — и
  размер тут ни при чём: 94 КБ `Makefile` ищется и с пустым `path`. Отсюда ловушка: файл с расширением
  (`AGENTS.md`, `prek.toml`) ищется, файл без — нет, и вывод «большой файл пропущен» ложен;
- **«No matches found» и «0 exact matches. Maybe you meant this?» — не одно и то же** (#16137):
  второе — догадка по другим файлам, первое — пустота даже для догадки. Вывод «такого кода
  нет» без якоря не делается: перепроверь `rg` по тому же файлу, особенно когда вышел ноль;
- **код возврата не читают после конвейера в `head`/`tail`** (#16096 п.1): `cmd | tail -5; echo $?`
  читает код `tail`, а не команды — сторож отклоняет такой вызов и называет `PIPESTATUS`. Правило дважды
  стояло текстом и нарушалось 22 раза за одну сессию (#16087), одно такое нарушение ушло в трекер;
  с `set -o pipefail` в той же команде `$?` верен и вызов проходит;
- **`sed -n 'A,Bp'`, `cat <файл>`, `grep -n <файл>` — только для файла больше 50 КБ**: `read` такого
  файла возвращает первые 50 КБ, и хвост теряется молча. На файле до 50 КБ сторож отклоняет вызов,
  и это потерянный ход с повтором другим инструментом — 9 отказов из 10 в ретро #15970 ровно этот
  случай. Оговорка «только больше 50 КБ» должна стоять в самом правиле: без неё «постранично через
  `sed -n`» читается как общий приём чтения.
- **Отказ сторожа приходит вместе с запрошенным содержимым** (#16110): у `cat`, `sed -n 'A,Bp'`,
  `grep -n` по файлу до 50 КБ в тексте отказа уже стоят строки с номерами — повторять вызов другим
  инструментом не нужно, ответ получен. Отдаётся только первая область и только один файл;
  остальное — `read` с `offset` из той же строки отказа.

# Гейты и прогоны: один прогон на раунд правок

- **Правки по ревью собираются в один коммит до прогона гейта.** Раунд ревью даёт несколько находок,
  и отдельный прогон под каждую — это несколько прогонов вместо одного. Замер #16159 п.4: 12 запусков
  `unit-tests.sh` (5 на хосте, из них два красных ложных, 7 в контейнере) и 6 `make lint-ci` на три
  коммита одной сессии; полный `--changed` в msb-lk стоит 6–7 минут, то есть три прогона вместо одного
  — это 12–14 минут простоя. Порядок: правки раунда → один коммит → один прогон гейта; повторный прогон —
  только если после него менялись файлы.
- **Прогон, который идёт дольше пары минут, запускается обёрткой и забирается одним вызовом**
  (`scripts/ci/run-detached.sh start -- …` / `wait <id>` в msb-lk), а не циклом `sleep`. Ожидание
  субагента устроено так же: асинхронный ребёнок сам будит родителя, поэтому `sleep`, опрос
  `subagent({ action: "status" })` в цикле и `bg_wait` для обычного асинхронного ребёнка — это
  бездействие родителя. В msb-lk #15812 ожидание двух ревьюеров стоило 17 вызовов `sleep` и 74 минут
  при уже готовых отчётах (#15865 п.1).

# Исходник пакета: `vendor`, а не соседний чекаут

Код, который **реально считается**, у PHP-пакета — установленный `vendor/<vendor>/<пакет>/` в
репозитории-потребителе, либо `git show <тег>:<путь>` (тег — из `vendor/composer/installed.json`).
Соседний чекаут пакета — рабочая копия, часто чужая задача на своей ветке: 19.11.2026 чекаут
`msb-calculator-api` стоял на `fix/15676-insurance-year-reset`, на 17 коммитов позади `origin/main`, и
поиск по нему дал вывод «правило окна в пакете не реализовано вовсе» — при том что в `vendor`
`isFullReleaseWindow()` есть (#15830 п.1).

- читаешь `src/` чекаута как «текущий код» — сначала `git -C <чекаут> status -sb` и `git log --oneline -1`:
  ветка не та — правда всё равно в `vendor`;
- чекаут годится как «что будет в следующем релизе», и только на актуальном `origin/main`;
- разница между чекаутом и `vendor` видна по `composer.lock` и `installed.json`, а не по номеру
  версии в `composer.json` чекаута.

# Русский текст: проверка перед публикацией

Русская проза у flash-тиров сыпется двумя классами ошибок: латинские гомоглифы внутри
кириллицы (`лоkalной`, `восстанóвленное`, `обéих`, `преflight`) и редукция гласных (`нузен`,
`открито`, `которий`, `напровление`). Модель этого не замечает, поэтому перед публикацией
русского текста — детерминированная вычитка. Публикация — любой текст, который прочтёт человек:

- **итог сессии в чат — тоже публикация.** Сводка «что сделано» в конце задачи читается первым делом и
  правится потом дорого (её цитируют в трекер и в сдачу), поэтому она пишется в `/tmp/<id>-summary.md`,
  проверяется `ru-spellcheck --homoglyph-only` по файлу и только потом уходит в ответ. Написанная
  прямо в ответе сводка проверку пропускает — именно так в #16105 в чат ушла сводка с двумя ошибками
  редукции гласных: правило называло «TL;DR в чат» в перечислении примеров, и оно читалось как про
  заметку в трекере (#16149);
  **полный прогон по такому файлу идёт через stdin из корня репозитория, чей текст проверяется.**
  Файловый режим ищет словарь от самого файла вверх, а у `/tmp` предка-репозитория нет — проектные
  слова из `.ru-spellcheck-allow` красятся как ошибки. Замер 26.11.2026 на одинаковом тексте:
  `ru-spellcheck /tmp/sp-word.md` даёт находку SPELLING на проектном слове из
  `.ru-spellcheck-allow:91`, а тот же текст в `runtime/` репозитория или `cd <репо> && ru-spellcheck -`
  проходит чисто. Цена обратного порядка — шесть циклов переписывания двух сводок в сессии #16153 и
  синоним, придуманный вместо слова, которым говорит весь репозиторий;
- заметка в Redmine, ТК/ОР, отчёт UAT — тот же гейт: файл → `ru-spellcheck --homoglyph-only` → отправка;
- короткий текст (заметка, сообщение — примерно до 40 строк):
  `ru-spellcheck --homoglyph-only файл.md` (или `… | ru-spellcheck --homoglyph-only -`) — гейт,
  ноль ложных срабатываний, exit 1 при находке;
- **тело коммита — не «короткий текст»: оно обычно длиннее 40 строк** (#15906 п.6). Тело на 41 строку
  уже получило от `--homoglyph-only` код 3 и просьбу о полном прогоне. Тело лежит в `/tmp`, вне
  репозитория, поэтому `--added` для него не годится (там он отказывает кодом 2), а гейт — через stdin:
  `cd <репо> && ru-spellcheck - < /tmp/msg.txt` либо
  `cd <репо> && ru-spellcheck --allow-long --homoglyph-only - < /tmp/msg.txt`;
  `--added <база> файл` остаётся для отслеживаемых файлов и только по ним;
- **гейт через stdin запускается из каталога того репозитория, чей текст проверяется** (#16004 п.2).
  Словарь проекта ищется от cwd, поэтому проверка из чужого каталога помечает снова слова, которые
  этот репозиторий уже узаконил: тело коммита в `msb-calculator-api` проверяли из `msb-lk`, и
  `пересобирать`, `пересборка`, `пересобран` шли в находки три цикла подряд;
- длинный текст (документ передачи, README, описание задачи): полный `ru-spellcheck файл.md` — словарь
  `ru_RU` плюс личный и проектный, находки разбирать руками. Гейт на длинном входе сам выходит с кодом
  3 и просит полный прогон: редукция гласных (`сесии`, `велечину`, `скрыпт`) без словаря не видна, и
  зелёный `--homoglyph-only` на 57-строчном документе с 55 ошибками — это не «чисто», а «не смотрели»
  (#15799 п.2). `--allow-long` — осознанный обход, а не привычка;
- полный прогон шумит на проектном жаргоне и на пробелах словаря (множественное число твёрдых основ:
  `сервисы`, `сервисам`); жаргон узаконивается в `.ru-spellcheck-allow`, пробелы словаря — нет;
- **термин продукта — исключение из этого правила, а не пробел словаря.** Подпись, которую цитирует
  интерфейс или документация (`лизингополучатель`, `лизингодатель` на экране графика), переписать в
  заметке нельзя, поэтому она идёт в проектный `.ru-spellcheck-allow` через `--add` — в отличие от
  придуманной агентом лексики (`воркtree`, `резолв`), которая остаётся в deny-списке и узакониванию
  не подлежит (#16009 п.3);
- **верная словоформа — не повод для `--add`.** Инструмент сам принимает словоформу, у которой
  основа есть в словаре (`маржой` -> `маржа`), а класс редукции гласных (`нузен`, `деньгы`) остаётся
  находкой; если такое срабатывание всё же пришло — правят текст, а не список (#15877 п.4).
- **Обычное русское слово, которого нет в словаре, — `--add-personal`**, а не правка текста:
  `подцел`, `подкоманд` узаконены личным списком, потому что это пробел словаря `ru_RU`, а не ошибка.
  В проектный `.ru-spellcheck-allow` такое не идёт (он про лексику проекта), в deny-список — тем более:
  там только то, что запретил человек. Если слово уже добавлено, а находка осталась, сработала другая
  словоформа — смотрите, какая именно, а не добавляйте стем ещё раз.
- находки править в тексте, а не пересказывать моделью: повторный прогон той же модели даёт те же
  ошибки. Новое узаконенное слово — `ru-spellcheck --add СЛОВО` (стем-совпадение, `скилл`
  покрывает `скиллов/скиллу`). Из репозитория `--add` пишет в его собственный словарь
  `.ru-spellcheck-allow` в корне — тот едет в коммит вместе с правкой и работает у всех агентов и в
  CI; личный `~/.config/ru-spellcheck/allow.txt` — только `--add-personal`. Словарь проекта читается
  поверх личного, искать его больше нигде не нужно: инструмент сам идёт от проверяемого файла вверх
  до корня репозитория (#15717 п.4).
- **Deny-список — не твой.** `~/.config/ru-spellcheck/deny.txt` (и проектный `.ru-spellcheck-deny`)
  называет лексику, которую агент придумал и не должен узаконивать: `воркtree`, `инлайн`, `харнесс`,
  `резолв`. Слово оттуда — находка **всегда**, даже если оно написано верно, лежит в allow или в
  baseline, и `--add` на нём отказывает: правят текст, а не список. Файл принадлежит человеку, и
  `path-guard` не даёт агенту его записать (`PI_PATH_GUARD_ALLOW_DENY_LIST=1` — осознанный обход), а
  коммит с этой правкой в самом pi-setup блокирует prek-хук `deny-list-guard` (`SKIP=deny-list-guard` —
  осознанный обход, причина — в сообщении коммита): `path-guard` видит только `write`/`edit`, а `bash`
  его не пересекает.
  Правило пришло из #15820: `ассерты`, `апрувы` и `резолвы` попадали в allow как «верные слова» именно
  потому, что список рос изнутри сессии.
- **Замена для deny-слова — отдельный файл.** `~/.config/ru-spellcheck/deny-rewrites.txt` (и проектный
  `.ru-spellcheck-deny-rewrites`) — строка `<слово> -> <замена>`; находка DENY печатает
  «замените на: …». Запрет остаётся в deny-списке и остаётся человеческим, а подсказка — агентская:
  поэтому файл отдельный, а не третья колонка списка. Строка без `->` значит «замены нет». Правило
  пришло из #90: восемь разных слов и шесть итераций правки на четыре заметки, потому что отказ говорил
  «нельзя» и молчал о том, «пиши так».
- Проверять **до** публикации: после отправки в Redmine правка уже не бесплатна.

# Мерж и релиз

Репозитории с `.github/workflows/release-please.yml` (`msb-calculator-api`) — перед мержем PR
скилл `release-please`: один мерж — один релиз.
