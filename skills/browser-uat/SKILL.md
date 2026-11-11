---
name: browser-uat
description: "Drive a real browser through the Playwright MCP server (`mcp__playwright__*`) to do user acceptance testing, reproduce UI bugs, or verify a web app end to end. Use whenever the user says UAT, smoke test the UI, click through the app, check the page in a browser, take a screenshot of the running app, verify a form/login/flow works, or asks whether something looks or behaves right in a real browser. Also use before declaring a UI change verified."
---

# Browser UAT (Playwright MCP)

Interactive browser work driven by the `playwright` MCP server. This is UAT and
debugging, not test authoring: for CI-style Playwright specs, write a test file
instead.

The browser runs on a **private Xvfb display**, so it never appears on the
user's desktop and never steals window focus. Screenshots are the only way to
see it. Environment management lives in a script; do not hand-edit MCP config or
launch Xvfb yourself.

## Start here

```bash
~/.pi/agent/skills/browser-uat/scripts/uat.sh doctor
```

`doctor` checks npx, a browser, Xvfb, the MCP entry, and the artifact directory,
and prints the exact fix for anything missing. Run it once per session before
blaming a tool call. `uat.sh help` lists the other subcommands.

If `mcp__playwright__*` tools are absent, the server is not connected: run
`pi mcp list`, then `/reload` (the tool list only refreshes on reload or a new
session).

## Workflow

1. **Write the QA inventory before touching the browser.** From the user's
   request, the implemented changes, and the claims you intend to make, list
   every user-visible control and the state change it should cause. Add at least
   two off-happy-path scenarios (empty input, wrong credentials, back button,
   double submit). This list is what you sign off against — not "I clicked
   around". `uat.sh report` prints a matching template.
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
- **Omit `filename` on screenshots.** Auto-named files land in the artifact
  directory (`$TMPDIR/browser-uat`, absolute paths in the tool result). An
  explicit filename resolves against the session cwd and litters the repo.
- **The display is 1920×1080**, so full-page screenshots are wide. Call
  `browser_resize` (e.g. 1280×800) when iterating, or take element screenshots.
- **`--isolated` means no persisted login.** Every server restart starts logged
  out. For login-heavy UAT, log in as part of the flow.
- **The browser self-closes after 15 minutes idle.** The next tool call relaunches
  it, which loses tabs and session state — re-navigate rather than assuming the
  page is still there.
- **`hasFocus`/`visibilityState` are real signals** in `browser_evaluate`; use
  them before blaming the app for a lazy-load or autoplay problem.
- **Snapshots go stale** after navigation, form submit, or modal open. Re-snapshot
  rather than retrying a click on a dead ref.
- **Nothing is visible on the user's screen.** If the user asks to watch, they
  need a screenshot; there is no window to look at.

## Do not

- Do not use `browser_run_code_unsafe` to bypass a failing interaction — fix the
  locator or the wait instead.
- Do not declare UAT passed without running the inventory; a single happy-path
  click is not a test.
- Do not hand-edit the playwright entry to change the display or launch it by
  hand — use `uat.sh config install` for the entry and `uat.sh display start` for
  a manual display; never run Xvfb directly.
- Do not leave the browser open across unrelated tasks, and do not leave
  artifacts in a repo.
