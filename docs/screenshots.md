# Screenshots on this machine

Desktop session is KDE on Wayland (`WAYLAND_DISPLAY=wayland-0`), with an X11 display
(`:1`) kept for compatibility. That combination breaks the obvious tools:

```text
$ import -window root /tmp/shot.png
import-im6.q16: unable to read X window image `root': Resource temporarily unavailable
```

`import` (ImageMagick) needs an X11 root window. Under KDE/Wayland the root window is not
readable, so the screenshot silently fails.

## Working command

```bash
spectacle -b -n -o /tmp/shot.png     # -b background, -n no notification, -o output
```

`-o` without `-f` captures the **active window**. That matters more than it looks: `-f`
(full screen) pulls every visible window into the image, and the agent then reads other
people's sessions into its context. On 2026-11-19 a full-screen capture of a tmux test
window brought an unrelated `pi` session (8 windows, a work in progress on another
project) into the conversation. Capture the window under test, not the desktop.

Other useful forms:

```bash
spectacle -b -n -f -o /tmp/desktop.png         # full screen — only when the whole desktop IS the subject
spectacle -b -n -r -o /tmp/region.png          # rectangle, opens a selection overlay (needs a human)
```

## Reading the image

The `read` tool accepts a PNG path and returns it as an attachment. That costs context in
proportion to the image, so capture one window at a time and only when the answer is
visual (a gradient that separates truecolor from 256 colours, a layout, a rendered state).
For anything textual, `capture-pane -p`, `grep`, or a log line is cheaper and exact.

## Browser screenshots

Those go through the Playwright MCP server instead; see the `browser-uat` skill and
`~/.pi/agent/skills/browser-uat/scripts/uat.sh`. Playwright captures its own page, so none
of the Wayland caveats above apply.
