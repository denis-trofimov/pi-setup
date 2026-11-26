#!/usr/bin/env bash
# patches/pi-subagents-task-required.sh: `subagent({ agent })` без task больше не запускает ребёнка
# с пустым заданием. До правки валидация проверяла только, что `agent` — непустая строка (и что
# переданный `task` — строка), а рядом стояло сообщение с формой `{ agent, task? }`, то есть пустой
# task читался как поддерживаемый. Стоимость замера (#16149): вызов пришлось останавливать вручную,
# задание ребёнку так и не появилось.
#
# Проверяется: (1) --check до правки — код 1, после правки — 0; (2) правка ставит проверку и в
# рабочий файл пакета, и в упакованную копию; (3) повторный прогон ничего не меняет и печатает «already
# patched»; (4) чужой upstream (нет якоря) — код 1 с просьбой переписать скрипт правки;
# (5) неустановленный пакет — 0;
# (6) если пакет установлен на этой машине, поведение проверяется вызовом самой валидации.
#
# Работает на временном PI_CODING_AGENT_DIR: установленный пакет не правится (кроме шага 6, который
# ничего не пишет).
# Exit 0 — всё сошлось; 1 — проверка упала.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/patches/pi-subagents-task-required.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

OLD_GUARD='        if (params.task !== undefined && typeof params.task !== "string") {
            return { ok: false, error: "Structured single-child task must be a string when provided.", mode: "workflow" };
        }
        return {
            ok: true,
            params: {
                ...params,
                agent: params.agent.trim(),
                output: params.output === undefined ? true : params.output,
            },
        };'
OLD_SHAPE='return { ok: false, error: "Execution requires either { agent, task? } for one child or workflow (true, a script path, or a named workflow resource) for orchestration.", mode: "workflow" };'

# Пакет-фикстура: рабочий файл и «упакованная» копия с тем же кодом.
make_fixture() {
  local home="$1" body="$2"
  mkdir -p "$home/npm/node_modules/pi-subagents/src/extension" "$home/npm/node_modules/pi-subagents/bundle"
  printf '%s\n' "$body" > "$home/npm/node_modules/pi-subagents/src/extension/public-execution.js"
  printf '%s\n' "$body" > "$home/npm/node_modules/pi-subagents/bundle/chunk-FIXTURE.js"
}

fixture_body() {
  printf '%s\n%s\n' "$OLD_GUARD" "$OLD_SHAPE"
}

# --- (1) и (2): фикстура с настоящим якорем -----------------------------------
home="$WORK/home"
make_fixture "$home" "$(fixture_body)"

set +e
PI_CODING_AGENT_DIR="$home" "$PATCH" --check >/dev/null 2>&1
rv=$?
set -e
[[ "$rv" == 1 ]] || fail "--check до правки должен отдавать код 1, отдал $rv"

PI_CODING_AGENT_DIR="$home" "$PATCH" > "$WORK/apply.log" 2>&1 || {
  cat "$WORK/apply.log" >&2
  fail "правка на фикстуре не встала"
}
grep -q 'requires task to be a non-empty string' "$home/npm/node_modules/pi-subagents/src/extension/public-execution.js" \
  || fail "в рабочем файле пакета нет новой проверки"
grep -q 'requires task to be a non-empty string' "$home/npm/node_modules/pi-subagents/bundle/chunk-FIXTURE.js" \
  || fail "в упакованной копии нет новой проверки"
grep -q 'Execution requires either { agent, task } for one child' "$home/npm/node_modules/pi-subagents/src/extension/public-execution.js" \
  || fail "сообщение о форме вызова всё ещё обещает необязательный task"
grep -q 'task? }' "$home/npm/node_modules/pi-subagents/src/extension/public-execution.js" \
  && fail "в рабочем файле пакета остался '{ agent, task? }'"

PI_CODING_AGENT_DIR="$home" "$PATCH" --check >/dev/null 2>&1 \
  || fail "--check после правки должен отдавать код 0"

# --- (3): повторный прогон ничего не меняет -----------------------------------
before="$(cksum "$home/npm/node_modules/pi-subagents/src/extension/public-execution.js")"
second="$(PI_CODING_AGENT_DIR="$home" "$PATCH" 2>&1)" || fail "повторный прогон упал: $second"
grep -q 'already patched' <<<"$second" || fail "повторный прогон не сообщил «already patched»: $second"
after="$(cksum "$home/npm/node_modules/pi-subagents/src/extension/public-execution.js")"
[[ "$before" == "$after" ]] || fail "повторный прогон изменил уже исправленный файл"
[[ "$(grep -c 'requires task to be a non-empty string' "$home/npm/node_modules/pi-subagents/src/extension/public-execution.js")" == 1 ]] \
  || fail "проверка вставлена дважды"

# --- (4): чужой upstream без якоря ---------------------------------------------
other="$WORK/other"
mkdir -p "$other/npm/node_modules/pi-subagents/src/extension"
printf 'export function normalizePublicSubagentExecution() { return { ok: true, params: {} }; }\n' \
  > "$other/npm/node_modules/pi-subagents/src/extension/public-execution.js"
set +e
PI_CODING_AGENT_DIR="$other" "$PATCH" > "$WORK/other.log" 2>&1
rv=$?
set -e
[[ "$rv" == 1 ]] || fail "на чужом upstream скрипт правки должен отдавать код 1, отдал $rv"
grep -q 're-derive patches/pi-subagents-task-required.sh' "$WORK/other.log" \
  || fail "на чужом upstream нет просьбы переписать скрипт правки: $(cat "$WORK/other.log")"

# --- (5): пакет не установлен --------------------------------------------------
mkdir -p "$WORK/empty-home"
out="$(PI_CODING_AGENT_DIR="$WORK/empty-home" "$PATCH" 2>&1)" || fail "на неустановленном пакете скрипт правки упал: $out"
grep -q 'nothing to patch' <<<"$out" || fail "на неустановленном пакете нет сообщения «nothing to patch»: $out"

# --- (6): поведение установленного пакета ---------------------------------------
installed="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/npm/node_modules/pi-subagents/src/extension/public-execution.js"
if [[ -f "$installed" ]] && command -v node >/dev/null 2>&1; then
  "$PATCH" --check >/dev/null 2>&1 \
    || fail "правка в установленном pi-subagents не применена: запустите patches/pi-subagents-task-required.sh"

  behavior="$(node --input-type=module -e '
    const m = await import(process.argv[1]);
    const f = m.normalizePublicSubagentExecution;
    const agentOnly = f({ agent: "reviewer" });
    const blank = f({ agent: "reviewer", task: "   " });
    const ok = f({ agent: "reviewer", task: "do x" });
    console.log(JSON.stringify({
      agentOnly: agentOnly.ok,
      blank: blank.ok,
      ok: ok.ok,
      message: agentOnly.error ?? "",
    }));
  ' "file://$installed")" || fail "не удалось вызвать валидацию установленного пакета"

  grep -q '"agentOnly":false' <<<"$behavior" || fail "agent без task всё ещё запускается: $behavior"
  grep -q '"blank":false' <<<"$behavior" || fail "task из одних пробелов всё ещё запускается: $behavior"
  grep -q '"ok":true' <<<"$behavior" || fail "нормальный вызов {agent, task} перестал проходить: $behavior"
  grep -q 'requires task to be a non-empty string' <<<"$behavior" \
    || fail "сообщение об отказе не называет причину: $behavior"
else
  echo "pi-subagents: пакет не установлен на этой машине — поведение не проверялось (шаг 6 пропущен)"
fi

echo "OK: сторож task в pi-subagents проверен"
