# Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** a single `nobi` binary per macOS and Linux target, installed by `curl … | sh`, that runs the whole system locally with one command.

**Spec:** `docs/superpowers/specs/2026-10-17-distribution-design.md` (binding).

## Global Constraints

- **Never publish.**
  - Don't create GitHub repos, push, tag, upload or publish anything.
  - The CI workflow file is written, not run remotely.
- **Server hygiene.**
  - Never touch :4000.
  - Scratch servers run on PORT=4123 with a temp `NOBI_DATA`. Record the OS PID and kill only that PID. Never use `pkill` or `killall`.
- **Toolchain downloads.**
  - Downloading toolchain pieces is allowed: the Zig version Burrito pins, Burrito via hex, and Docker images (`alpine`, `debian:stable-slim`).
  - Put them in their own scratch dirs, or use the normal hex/mix caches.
  - Don't install global system packages without saying so in the report.
- **Prod server mode keeps working.** The existing prod config (0.0.0.0, https, `/var/lib/nobi`, required secret) stays reachable through `NOBI_MODE=server`.
- **Repo rules.**
  - `Nobi.Universe` is the only interface to universes.
  - Never create or edit README files.
  - VCS is jj (`jj commit -m`). Never use `git commit` or `git stash`.
  - `mix precommit` is green after every task.
  - DB-writing tests are not async.

## Review Focus

1. **Local mode.** It binds 127.0.0.1 only. The secret is created once with mode 0600 and reused. Nothing writes outside `NOBI_DATA`. *Task 1.*
2. **The binary.** It runs on a clean macOS shell with no Elixir on PATH. Data survives a restart. Served apps resolve at `*.localhost`. *Task 2.*
3. **install.sh is safe.** It checks the checksum, never uses sudo and never edits rc files. A failure leaves nothing half-installed. *Task 3.*

---

### Task 1: Local mode + `nobi` CLI

**Files:**
- `config/runtime.exs`: local/server mode.
- `lib/nobi/local.ex` (or similar): data directory, secret, and opening the browser.
- `lib/nobi/cli.ex`: argv dispatch for `start | mcp | version | uninstall`.
- `lib/nobi/release.ex`: a `start` entry that migrates, then ensures `main` and `local`.
- Reuse `Mix.Tasks.Nobi.Start.banner/1` by moving the banner to a non-Mix module, which the task then calls.
- `mix.exs`: `releases:` config with `:mcp_enabled` set for the release build. Choose a mechanism (config env or a `MIX_ENV=prod` compile flag) and document it.

**Behaviour:** as in the spec sections "The `local` release profile" and "The `nobi` command". Without Burrito, the release must work as `_build/prod/rel/nobi/bin/nobi start`, or as an equivalent `eval`/`start` wrapper. Burrito comes in Task 2.

- [ ] **Failing tests first:**
  - the data directory defaults to `~/.nobi` (`HOME` is overridden in the test) and `NOBI_DATA` wins;
  - the secret is generated once, with mode 0600, and is stable across calls;
  - the bind address is 127.0.0.1 in local mode and 0.0.0.0 in server mode;
  - CLI parsing for each command, including an unknown command;
  - the `nobi mcp` output;
  - the banner includes `nobi mcp`.
- [ ] **Manual check:** run `MIX_ENV=prod mix release`, then start the release with a temp `NOBI_DATA` on 4123. Then:
  - `/_` returns 200 and `/mcp` initialize works;
  - stop it, restart it, and confirm the state persisted.

  Record the commands and their output.
- [ ] **Commit:** run `mix precommit`, then `jj commit -m "feat: local release mode and nobi CLI"`.

### Task 2: Burrito single binary

**Files:** `mix.exs` (the burrito dep and release steps), `lib/mix/tasks/nobi.dist.ex`, `.gitignore` (`dist/`), and the Zig version pin documented in the task's moduledoc.

**Build:**
- Burrito targets: `macos-arm64`, `macos-x86_64`, `linux-x86_64` and `linux-arm64` (musl).
- `mix nobi.dist` runs `assets.deploy`, then the Burrito release, and writes `dist/nobi-<os>-<arch>` plus `.sha256` files.
- **exqlite:** if Burrito's NIF recompile fails for a target, fall back to exqlite's precompiled artifact. Document which path each target takes.
- **Version:** `nobi version` prints the mix version and the commit id baked in at build time.

**Verify:**
- **Host binary:**
  1. Start it from `env -i HOME=$TMP PATH=/usr/bin:/bin` so no Elixir or Erlang is on the PATH.
  2. Use `NOBI_DATA` set to a temp dir and PORT=4123.
  3. `/_` returns 200, and `/mcp` initialize works.
  4. Through the MCP, stage a tiny app with a route and create a deployment for it.
  5. `curl -H 'Host: <name>.localhost:4123'` returns the app.
  6. Restart and check persistence.
- **Linux:** if Docker is available, run `dist/nobi-linux-arm64 version` and a start + curl inside `alpine` and `debian:stable-slim`. Record the results; if Docker is unavailable, say so.
- **Sizes:** record each binary's size.

- [ ] **Run** `mix precommit` (the dist build is not part of it), then `jj commit -m "build: Burrito single-binary dist"`.

### Task 3: install.sh + release workflow

**Files:** `install.sh` at the repo root, `.github/workflows/release.yml`, and `test/install_sh_test.exs` (or a shell test script under `test/`) that runs install.sh against a local http server.

**Behaviour:** as in the spec section "install.sh". Specifically:
- It is POSIX sh, and `shellcheck` passes. If shellcheck isn't installed, say so; installing it with brew is allowed.
- It detects curl or wget.
- `NOBI_BASE_URL`, `NOBI_VERSION` and `NOBI_INSTALL_DIR` are honoured.
- Downloads go to a temp file, which is moved into place only after the checksum verifies.
- If the install dir is not on PATH, it prints a hint.
- **Workflow:** on a `v*` tag, run on macos-14:
  1. Set up Erlang and Elixir at the versions in `.tool-versions` or `mix.exs`.
  2. Set up Zig at the pinned version.
  3. Run `mix nobi.dist`.
  4. Smoke-test `nobi version`.
  5. Create a GitHub release with `dist/*` and `install.sh`.

  The base URL in install.sh defaults to `https://github.com/OWNER/nobi-lang/releases`, using `latest/download/` or `download/<version>/`. `OWNER` is a placeholder until Marce names the repo; read it from one variable at the top of the script.

- [ ] **Tests:**
  - a clean install into a temp dir from a local `python3 -m http.server` over a fake `dist/` (tiny fake binaries with correct checksums), after which the installed file is executable;
  - a checksum mismatch is refused and nothing is installed;
  - an unknown arch is refused (stub `uname` via PATH);
  - the PATH hint is printed;
  - the `NOBI_VERSION` URL is formed correctly.
- [ ] **Run** `mix precommit`, then `jj commit -m "build: install.sh and release workflow"`.
