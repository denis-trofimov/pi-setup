#!/usr/bin/env bash
# uat.sh login: a stand that sends a logged-in session to "/" is not a failed login (#16027 п.2).
#
# Why: on the farm the browser lands on "/" after a successful submit, while the script judged the
# login by the URL alone and printed «вход не прошёл — страница /, ожидался путь /admin» with three
# cookies already written. The state file is written only on success, so the MCP browser then came
# up as a guest — two login runs and an MCP restart in that session.
#
# Three layers here, all with a stub `playwright` (no network at all):
#   * farm: landed on "/", the probe of --success answers 200 → login passes;
#   * landed: the browser itself lands under --success → passes without a probe;
#   * probe-guest: landed on "/", the probe is redirected into /login → the real failure is named.
#
# Removing the probe keeps the first layer red, so the test measures the fix and not the log line.
#
# Exit 0 — all checks passed; 1 — a check failed.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/browser-uat/scripts" && pwd)"
LOGIN="$SCRIPTS/uat-login.mjs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$LOGIN" ]] || fail "нет $LOGIN"
command -v node >/dev/null || fail "нужен node"

# HOME is faked: `npm root -g` writes a log into $HOME/.npm on every launch.
mkdir -p "$WORK/home"

# The stub Playwright package: a login form that ends where the scenario says, and an API request
# context that answers like the stand. Everything the script touches is recorded, so the assertions
# can tell "the probe decided" from "the URL decided".
mkdir -p "$WORK/fake-pw/playwright"
cat > "$WORK/fake-pw/playwright/index.js" <<'EOF'
const fs = require('node:fs');

const scenario = process.env.STUB_SCENARIO || 'farm';
const callsFile = process.env.STUB_CALLS;
const record = (entry) => {
  if (callsFile) fs.appendFileSync(callsFile, JSON.stringify(entry) + '\n');
};

const SIGN_IN = 'http://localhost/admin/login/sign-in';
const LANDING = {
  farm: 'http://localhost/',
  landed: 'http://localhost/admin/schedule/update?id=24568',
  'probe-guest': 'http://localhost/',
};

module.exports = {
  chromium: {
    launch: async () => {
      let current = SIGN_IN;
      const page = {
        setDefaultTimeout() {},
        async goto(url) { current = url; },
        async fill(selector, value) { record({ fill: selector, value }); },
        async click(selector) {
          record({ click: selector });
          current = LANDING[scenario] || LANDING.farm;
        },
        // The script passes its own predicate: the stub only answers "did we land there".
        async waitForURL(predicate) {
          if (predicate(new URL(current))) return;
          throw new Error('stub: timeout waiting for the URL');
        },
        url() { return current; },
        async title() { return 'Вход в кабинет'; },
      };
      const context = {
        newPage: async () => page,
        storageState: async () => ({
          cookies: [{ name: 'PHPSESSID' }, { name: 'csrf' }, { name: 'hint' }],
        }),
        request: {
          async get(url, options) {
            record({ get: url, options });
            if (scenario === 'probe-guest') {
              return { status: () => 302, headers: () => ({ location: 'http://localhost/admin/login/index' }) };
            }
            return { status: () => 200, headers: () => ({}) };
          },
        },
        close: async () => {},
      };
      return { newContext: async () => context, close: async () => {} };
    },
  },
};
EOF

# run <scenario> — one full login against the stub; sets OUT, RC, STATE, CALLS for the assertions.
run() {
  local scenario="$1" rc=0
  STATE="$WORK/state-$scenario.json"
  CALLS="$WORK/calls-$scenario.log"
  : > "$CALLS"
  rm -f "$STATE"
  OUT="$(env HOME="$WORK/home" UAT_PLAYWRIGHT_ROOT="$WORK/fake-pw" STUB_SCENARIO="$scenario" \
    STUB_CALLS="$CALLS" UAT_LOGIN_URL='http://localhost/admin/login/sign-in' \
    UAT_LOGIN_PHONE='+79990000000' UAT_LOGIN_CODE='1234' UAT_LOGIN_STATE="$STATE" \
    node "$LOGIN" 2>&1)" || rc=$?
  RC="$rc"
}

# --- farm: landed on "/", the probe of --success says the session is alive -------------------
run farm
[[ "$RC" == "0" ]] || fail "ферма: вход не засчитан при живой сессии (код $RC): $OUT"
[[ -s "$STATE" ]] || fail "ферма: файл состояния не записан при успешном входе: $OUT"
grep -q 'подтверждён запросом /admin' <<<"$OUT" || fail "ферма: подтверждение запросом не названо: $OUT"
grep -q '"get":"http://localhost/admin"' "$CALLS" || fail "ферма: запрос к /admin не сделан: $(cat "$CALLS")"
# No redirect following: a guest is told apart by the 302 itself, and following it would land on
# the login page with a 200 and look like a live session.
grep -q '"maxRedirects":0' "$CALLS" || fail "ферма: запрос пошёл по редиректам: $(cat "$CALLS")"
grep -q 'вход не прошёл' <<<"$OUT" && fail "ферма: живая сессия названа отказом: $OUT"

# --- landed: the browser itself lands under --success, no probe needed ----------------------
run landed
[[ "$RC" == "0" ]] || fail "адрес под --success: вход не засчитан (код $RC): $OUT"
[[ -s "$STATE" ]] || fail "адрес под --success: файл состояния не записан: $OUT"
grep -q '"get"' "$CALLS" && fail "адрес под --success: лишний запрос-проверка: $(cat "$CALLS")"

# --- probe-guest: landed on "/", the probe is redirected into /login ------------------------
run probe-guest
[[ "$RC" == "1" ]] || fail "гость: отказ не назван (код $RC): $OUT"
[[ -e "$STATE" ]] && fail "гость: файл состояния записан без сессии: $OUT"
grep -q 'вход не прошёл' <<<"$OUT" || fail "гость: отказ не назван словами: $OUT"
grep -q '— 302' <<<"$OUT" || fail "гость: ответ проверки не назван: $OUT"

echo "OK: uat-login считает вход по состоянию сессии, а не по адресу (#16027 п.2)"
