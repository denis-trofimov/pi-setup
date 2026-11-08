---
name: sonar
description: Local semantic code search via the sonar MCP server (`search`, `find_related`). Use when locating code by intent ("where do we persist calculation runs"), naming a concept rather than an exact identifier, hunting sibling or duplicated implementations, or searching docs/ and config. Prefer over `ffgrep`/`grep` for exploratory questions; use `ffgrep` for literal or regex sweeps.
---

# sonar — semantic code search

Local MCP server (Rust, BM25 + static embeddings). No cloud, no API key. Tools:
`mcp__sonar__search`, `mcp__sonar__find_related` (or the `mcp` proxy / codemode).

Always pass `repo` — the absolute path of the project you are working in. Indexes are
built lazily on first query and cached per repo, then invalidated when files change.
First query in a large repo is the slow one (msb-lk cold ≈ 20 s, warm ≈ 40 ms).

Ignore rules: `.sonarignore` (gitignore syntax) plus nested `.gitignore`.

## Pick the right search tool

| Question | Tool |
|---|---|
| "Where is X handled / how does this flow work?" (no exact name) | `search` |
| Symbol or identifier you already know | `search` (or `ffgrep` if you want every occurrence) |
| "What else looks like this / is there a copy of this?" | `find_related` |
| Every literal occurrence (rename, all callers, config key) | `ffgrep` / `grep` |
| Filename or path | `fffind` |
| Public open-source examples | `grep` MCP (grep.app) |

Never re-`ffgrep` for content `search` already returned — navigate to the `file:line`
and read it.

## search

```
query: "CalculationRunPersistenceService persist calculation run"
repo: /absolute/path/to/project
top_k: 5
```

Returns ranked chunks with `file_path`, `start_line`–`end_line`, `score`. Results are
snippets, not whole files: go read the reported range when you need full context.

Server is started with `--content code docs`, so `docs/` prose is searchable in the
same call. The MCP tool exposes only `query`, `repo`, `top_k` — no `content` or
`max_snippet_lines` arguments. Unknown arguments are ignored silently, so a call that
passes them looks successful and changes nothing.

Canonical surface, generated from the installed binary:
`~/p/agent-skills/design/notes/sonar-mcp-surface.md`
(refresh with `make sonar-surface` in that repo; `make check` fails on drift).

## find_related

```
file_path: internal/services/CalculationRunService.php
line: 142
repo: /absolute/path/to/project
top_k: 5
```

`file_path` must be **relative to `repo`**, exactly as the index stores it. An
absolute path fails: `No chunk found at /abs/path/file.py:1`.

Use a hit from `search` (or a file you just read) to find semantically similar
chunks. This is the main advantage over grep: it finds *similar*, not *identical* —
copied controllers, forked services, parallel implementations.

## CLI fallback

When MCP is unavailable:

```bash
sonar search "authentication flow" -p /path/to/project -k 5
sonar search "deployment guide" -p /path/to/project --content docs
sonar search "database host port" -p /path/to/project --content config
```

`--content` (`code`, `docs`, `config`, `all`) and `-m/--mode` (`hybrid`, `semantic`,
`bm25`) exist on the CLI only.

## Caveats

- The MCP server needs at least one **code** file to build an index. A docs-only
  repo fails with `Failed to index <repo>: No supported files found`, even though
  the CLI finds those files with `--content docs`. `.html`, `.css` and `.md` all
  count as docs, not code.
- Omitting `repo` does not mean "use the cwd": the server's default path is
  literally `docs`, so you get `Failed to index docs: cannot resolve absolute
  path for docs`. Always pass an absolute `repo`.
- Results have no score floor. An irrelevant query still returns `top_k` chunks
  with scores around 0.01 — check `score` before trusting a hit. A genuine
  `No results found for: "..."` is plain text, not JSON (same for `top_k: 0` or
  an empty query), so do not assume every call returns JSON.
- Remote `https://` repos only partly work: `git/git` and `sindresorhus/slugify`
  indexed fine, `octocat/Spoon-Knife` cloned to an empty checkout
  (`No supported files found`). The MCP server instructions advertise remote
  URLs; don't rely on them. Clone locally and pass the path instead.
- Stale index risk while editing: if a search returns a file that no longer matches
  what you just wrote, trust `read`, and treat the index as lagging.
- One server serves many repos: switching `repo` per call is fine, each repo gets its
  own cached index.
