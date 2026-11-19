# tests

Run these from the repo root. Nothing here needs Docker except `docker-e2e.sh`, and nothing
needs network except `browser-uat-login-proxy.sh`.

```bash
./tests/home-dotfiles.sh          # install/uninstall/revert of home/ dotfiles
bash tests/ru-spellcheck-repo-dict.sh
node --test tests/*.test.mjs
```

`.github/workflows/ci.yml` runs the `bash -n` pass, `node --test`, and every `tests/*.sh`
except `docker-e2e.sh`, which brings up a container and runs a full install (minutes +
Docker, deliberately outside CI).

## Testing a script that writes to `$HOME`

`install.sh`, `sync.sh`, and `uninstall.sh` all write outside the repo, so a test points
`HOME` and `BIN_DIR` at a throwaway directory and runs the real script against it. Two
rules, both learned the hard way:

**Never `cp -a` a worktree into `/tmp` to get a disposable copy.** A worktree's `.git` is a
*file* holding an absolute path to the real gitdir, so a commit made in the copy lands on
the branch in the worktree — author and all. On 2026-11-19 a `git commit -m wip` in
`/tmp/sync-test` did exactly that. Use `git clone`:

```bash
clone="$(mktemp -d)/clone"
git clone -q "$ROOT" "$clone"     # a real .git directory, isolated branch
```

**Seed a fake Pi home with the installer itself** instead of hand-writing `settings.json`:
`sync.sh` validates the JSON and themes it finds, and dies on a home that only half
exists (`FileNotFoundError: … ~/.pi/agent/settings.json`).

```bash
home="$(mktemp -d)"
env HOME="$home" BIN_DIR="$home/.local/bin" ./install.sh --restore --copy-config
env HOME="$home" ./sync.sh --no-skills --no-push "test capture"
```

Assert on files and `git` state, not on log text: `cmp -s`, `git show --name-only`,
`test -f`. `tests/home-dotfiles.sh` is the worked example.
