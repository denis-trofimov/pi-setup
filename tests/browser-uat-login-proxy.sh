#!/usr/bin/env bash
# uat.sh login: the proxy comes from the same base config the MCP browser reads, and the loopback
# host is rewritten to localhost (#15799 п.1).
#
# Why: a bare chromium.launch() goes direct while the MCP browser uses
# ~/.pi/agent/playwright-mcp.json, so with HTTP_PROXY exported in the session the login timed out
# on 127.0.0.1 — three runs out of three. And the saved storage state is domain-scoped, so a login
# made on 127.0.0.1 is a guest in a browser that opens localhost.
#
# Everything here runs with --dry-run: no browser, no network, no credentials.
# Exit 0 — all checks passed; 1 — a check failed.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/browser-uat/scripts" && pwd)"
UAT="$SCRIPTS/uat.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x "$UAT" ]] || fail "нет $UAT"

export PI_HOME="$WORK/pi-home"
mkdir -p "$PI_HOME"
cat > "$PI_HOME/playwright-mcp.json" <<'EOF'
{
  "browser": {
    "contextOptions": {
      "viewport": null,
      "proxy": {
        "server": "http://127.0.0.1:10808",
        "bypass": "localhost,127.0.0.1"
      }
    }
  }
}
EOF

env_file="$WORK/.env"
printf 'ADMIN_PHONE_NUMBER=+79990000000\nADMIN_PHONE_CODE=1234\n' > "$env_file"

# `login` on a loopback URL: host rewritten, proxy taken from the base config.
run() { env -u UAT_LOGIN_URL -u UAT_LOGIN_ENV "$@" 2>&1; }
out="$(run bash "$UAT" login --url http://127.0.0.1/admin/login/sign-in --env "$env_file" --profile local --dry-run)" \
    || fail "dry run упал: $out"
grep -q 'host 127.0.0.1 → localhost' <<<"$out" || fail "хост не переписан: $out"
grep -q 'url http://localhost/admin/login/sign-in' <<<"$out" || fail "URL не переписан на localhost: $out"
grep -q 'proxy http://127.0.0.1:10808 (bypass: localhost,127.0.0.1)' <<<"$out" \
    || fail "прокси не взят из base config: $out"

# The port survives the rewrite: only the host is replaced.
out="$(run bash "$UAT" login --url http://127.0.0.1:8080/admin/login/sign-in --env "$env_file" --dry-run)" \
    || fail "dry run с портом упал: $out"
grep -q 'url http://localhost:8080/admin/login/sign-in' <<<"$out" || fail "порт потерян при подмене хоста: $out"

# --keep-host leaves the URL alone and says nothing about a rewrite.
out="$(run bash "$UAT" login --url http://127.0.0.1/admin/login/sign-in --env "$env_file" --keep-host --dry-run)" \
    || fail "dry run с --keep-host упал: $out"
grep -q 'url http://127.0.0.1/admin/login/sign-in' <<<"$out" || fail "--keep-host переписал хост: $out"
grep -q 'host 127.0.0.1 → localhost' <<<"$out" && fail "--keep-host не должен печатать подмену: $out"

# --proxy-server overrides the server, the bypass list still comes from the config.
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" \
    --proxy-server http://proxy.example:3128 --dry-run)" || fail "dry run с --proxy-server упал: $out"
grep -q 'proxy http://proxy.example:3128 (bypass: localhost,127.0.0.1)' <<<"$out" \
    || fail "--proxy-server не переопределил прокси: $out"

# --no-proxy goes direct even though the config names one.
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" --no-proxy --dry-run)" \
    || fail "dry run с --no-proxy упал: $out"
grep -q 'proxy none' <<<"$out" || fail "--no-proxy не выключил прокси: $out"

# No base config at all: direct connection, no failure.
mv "$PI_HOME/playwright-mcp.json" "$WORK/playwright-mcp.json"
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" --dry-run)" \
    || fail "dry run без base config упал: $out"
grep -q 'proxy none' <<<"$out" || fail "без base config прокси обязан быть пустым: $out"
mv "$WORK/playwright-mcp.json" "$PI_HOME/playwright-mcp.json"

# A missing credentials file is a usage error, not a browser run.
set +e
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$WORK/absent.env" --dry-run)"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "отсутствующий .env обязан падать"
grep -q 'no credentials file' <<<"$out" || fail "сообщение про .env не напечатано: $out"

echo "OK: прокси берётся из base config (с переопределением), хост 127.0.0.1 → localhost, --keep-host и --no-proxy работают"
