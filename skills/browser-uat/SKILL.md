---
name: browser-uat
description: "Drive a real browser through the Playwright MCP server (`mcp__playwright__*`) to do user acceptance testing, reproduce UI bugs, or verify a web app end to end. Use whenever the user says UAT, smoke test the UI, click through the app, check the page in a browser, take a screenshot of the running app, verify a form/login/flow works, or asks whether something looks or behaves right in a real browser. Also use before declaring a UI change verified."
---

# Browser UAT (Playwright MCP)

Interactive browser work driven by the `playwright` MCP server. This is UAT and
debugging, not test authoring: for CI-style Playwright specs, write a test file
instead.

## Preconditions

Check these once per session; they cause every downstream call to fail.

1. `mcp__playwright__*` tools exist. If they do not, the server is missing or was
   added after the session started — the tool list only refreshes on `/reload`
   (or a new session). Config lives in `~/.pi/agent/mcp.json`.
2. Verify the connection with `pi mcp list` (expect `playwright: connected`).
3. Browser prerequisites: Node/npx, an installed browser, and a display for
   headed runs (`$DISPLAY` or `$WAYLAND_DISPLAY`). No display → pass
   `--headless` in the server args.

Config that this setup ships with:

- `~/.pi/agent/mcp.json` → `@playwright/mcp@0.0.84 --isolated --config ~/.pi/agent/playwright-mcp.json`
- `~/.pi/agent/playwright-mcp.json` → `viewport: null` + `--start-maximized --ozone-platform=x11`,
  so the window opens maximized. `--isolated` keeps the profile in memory and
  never touches the user's real browser profile.

## Workflow

1. **Write the QA inventory before touching the browser.** From the user's
   request, the implemented changes, and the claims you intend to make, list
   every user-visible control and the state change it should cause. Add at least
   two off-happy-path scenarios (empty input, wrong credentials, back button,
   double submit). This list is what you sign off against — not "I clicked
   around".
2. **Navigate**, then **snapshot**. `browser_snapshot` gives the accessibility
   tree with element refs; it is the source of truth for acting. Screenshots are
   for humans and visual checks, never for locating elements.
3. **Act** with `browser_click` / `browser_type` / `browser_fill_form` /
   `browser_select_option` / `browser_press_key`, using refs from the latest
   snapshot. Snapshot again after anything that changes the DOM — stale refs
   fail.
4. **Verify each inventory item** against observable state: URL, visible text,
   network response (`browser_network_requests`), console errors
   (`browser_console_messages`, level `error`). A silent console error fails a
   check even if the UI looks right.
5. **Capture evidence** with `browser_take_screenshot` for anything visual or
   subjective.
6. **Close** with `browser_close` when finished, and report pass/fail per
   inventory item with the evidence.

## Tool map

| Intent | Tool |
| --- | --- |
| Open a URL | `browser_navigate`, `browser_navigate_back` |
| Read the page | `browser_snapshot` (act from this), `browser_find` (text/URL search) |
| Interact | `browser_click`, `browser_type`, `browser_fill_form`, `browser_select_option`, `browser_hover`, `browser_drag`, `browser_press_key`, `browser_drop` |
| Wait for state | `browser_wait_for` (text, selector, or network idle) |
| Inspect behavior | `browser_console_messages`, `browser_network_requests`, `browser_network_request` |
| Assert programmatically | `browser_evaluate` |
| Visual evidence | `browser_take_screenshot` |
| Dialogs / uploads | `browser_handle_dialog`, `browser_file_upload` |
| Viewport / device | `browser_resize`, `browser_emulate_media` |
| Tabs | `browser_tabs` |
| Escape hatch | `browser_run_code_unsafe` (raw Playwright; use sparingly) |

## Gotchas

- **`browser_take_screenshot` requires `scale`** (`"css"` or `"device"`), despite
  its schema annotation saying it defaults to `css`. Omitting it fails validation.
- **Full-screen viewport = heavy screenshots.** The maximized window means
  screenshots are ~1900px wide. Call `browser_resize` (e.g. 1280×800) when
  iterating, or take element screenshots.
- **The window steals focus** when it opens. Wayland compositors do not let an
  app place itself or decline focus, so this is expected, not a bug. To keep it
  out of the way: KDE → *Focus stealing prevention: None* plus *Keep below*, or
  run the server with `--headless`.
- **Artifacts land in `./.playwright-mcp/`** relative to the session cwd
  (`page-*.yml` snapshots, `page-*.png` screenshots). Gitignore it; never commit it.
- **`--isolated` means no persisted login.** Every server restart starts logged
  out. For login-heavy UAT either log in as part of the flow, or switch to a
  dedicated `--user-data-dir` (cookies are secrets — keep it out of git).
- **`hasFocus`/`visibilityState` are real signals** in `browser_evaluate`; use
  them before blaming the app for a lazy-load or autoplay problem.
- **Snapshots go stale** after navigation, form submit, or modal open. Re-snapshot
  rather than retrying a click on a dead ref.

## Do not

- Do not use `browser_run_code_unsafe` to bypass a failing interaction — fix the
  locator or the wait instead.
- Do not declare UAT passed without running the inventory; a single happy-path
  click is not a test.
- Do not leave the browser open across unrelated tasks, and do not leave
  `.playwright-mcp/` artifacts behind in a repo.
