# Distribution: one binary, curl | sh — design

## Goal

Someone on macOS or Linux runs one command, then `nobi`, and has the whole system running locally: the console, the MCP and the served apps. There is no Erlang, Elixir, Node or SQLite to install.

```
curl -fsSL https://github.com/<owner>/nobi/releases/latest/download/install.sh | sh
nobi            # migrates, starts, opens the console, prints the MCP line
```

## Decisions (Marce, 2026-10-17)

- **Packaging:** a Burrito single self-extracting binary per target: `macos-arm64`, `macos-x86_64`, `linux-x86_64`, `linux-arm64`. The Linux builds are static (musl).
- **Hosting:** GitHub Releases. Creating the repo and publishing are outward actions, and each needs Marce's explicit go-ahead at the time. Everything up to the publish is built and tested locally first.
- **Landing:** a static site, specified separately.

## The `local` release profile

A release built for distribution runs in a **local mode**. It is the prod config with these overrides:
- **Bind address:** `127.0.0.1`, never `0.0.0.0`. The port comes from `PORT`, default 4000. If the port is taken, `nobi` says so and exits; it does not pick another silently.
- **URL:** `http://localhost:<port>`. `check_origin` allows `localhost` and `*.localhost`.
- **Data directory:** `NOBI_DATA`, defaulting to `~/.nobi`.
  - It holds `nobi.db`, `data/<deployment>.db` and the secret.
  - **Secret:** `SECRET_KEY_BASE` if set; otherwise read from `~/.nobi/secret_key_base`, generated with 64 random bytes and mode 0600 on first run.
- **MCP:** `:mcp_enabled` is on, so the console lives at `/_` and the MCP at `/mcp`. It is a compile-time flag, so the release is built with it set.
- **Server deploys:** the existing prod behaviour is unchanged when `NOBI_MODE=server`: `0.0.0.0`, https url, `/var/lib/nobi`, and a required secret.

## The `nobi` command

The release's entry point is a small CLI. Burrito passes argv to the app.

| Command | Does |
|---|---|
| `nobi` / `nobi start` | Creates and migrates the database, ensures the `main` universe and the `local` deployment (as `mix nobi.start` does), starts the server, prints the banner, and opens the console in the browser, unless `--no-open` is given or there is no display. |
| `nobi mcp` | Prints the lines that connect an agent to the MCP: `claude mcp add --transport http nobi http://localhost:4000/mcp`, plus a JSON config snippet for other clients. |
| `nobi version` | Prints the version and the build commit. |
| `nobi uninstall` | Prints what to delete: the binary path, the Burrito cache and `~/.nobi`. It deletes nothing itself. |

Unknown commands print usage. The banner gets one extra line: `connect an agent: nobi mcp`.

## Build

- **Burrito targets:** one per OS/arch, with a pinned Zig version (whatever the chosen Burrito release requires).
- **NIFs:** exqlite is the only one. Burrito recompiles it per target with Zig. If that fails for a target, use exqlite's precompiled NIF for that target.
- **Assets:** `mix assets.deploy` runs first, so `app.css`, `app.js` and `nobi.js` are digested into the release.
- **Command:** `mix nobi.dist` builds all targets into `dist/` (git-ignored). Each is named `nobi-<os>-<arch>` and has a `.sha256` file.
- **Version:** from `mix.exs`, plus the jj or git commit id.

## install.sh

It is POSIX sh and works on `bash`, `dash` and macOS `/bin/sh`. Steps:
1. Detect the OS and architecture with `uname -s` and `uname -m`, mapping `arm64`/`aarch64` and `x86_64`/`amd64` to the four targets. Anything else gets a clear error.
2. Download `nobi-<target>` and its `.sha256` from the release (`NOBI_VERSION`, default `latest`) and verify the checksum (`shasum -a 256` or `sha256sum`). On a mismatch it stops and deletes the download.
3. Install to `${NOBI_BIN_DIR:-$HOME/.local/bin}/nobi` with mode 0755. It never uses sudo.
4. If that directory is not on `PATH`, print the line to add for the user's shell. It never edits rc files.
5. Print the next step: `nobi`.

It uses `curl` if present, otherwise `wget`. It has no other dependencies. `NOBI_BASE_URL` overrides the download base, so the script can be tested locally against a `python3 -m http.server` serving `dist/`.

## CI (prepared, not pushed)

`.github/workflows/release.yml`:
- **Trigger:** a `v*` tag.
- **Build:** on a macOS arm64 runner (Burrito cross-compiles every target from one host), run `mix nobi.dist`.
- **Smoke test:** run `nobi version` for the host target.
- **Publish:** a GitHub Release with the binaries, the `.sha256` files and `install.sh`.

Nothing is pushed or published until Marce says so.

## Testing

- **Unit:**
  - local-mode config resolution: data directory default, secret generated, read back and kept at mode 0600, bind address, mode switch;
  - CLI argument parsing;
  - `nobi mcp` output;
  - the banner.
- **Build (manual or scripted, recorded in the report):**
  - build the host target;
  - run it against a temp `NOBI_DATA` on port 4123;
  - curl `/_` (200) and `/mcp` initialize;
  - create a deployment through the MCP and curl `<name>.localhost:4123`;
  - stop it;
  - run it again and check the data survived.
- **Linux check:** run the `linux-arm64` binary in a Docker container (`alpine` and `debian:stable-slim`) if Docker is available. If it isn't, record that.
- **install.sh:**
  - run with `shellcheck`;
  - run against a local http server: a clean install into a temp `NOBI_BIN_DIR`, a checksum mismatch refused, an unknown arch refused.
- **Safari:** whether `*.localhost` resolves. If it doesn't, record it; the landing's install section then recommends Chrome or Firefox for served apps. A path-based fallback is out of scope.
  - Result (2026-10-17, macOS 26.7.1, Safari 26.6.2): it resolves. `open -a Safari http://m1probe.localhost:4125/...` reached a probe server on `127.0.0.1:4125`, which logged `Host: m1probe.localhost:4125` and Safari's user agent. The macOS resolver itself maps `*.localhost` to `::1` and `127.0.0.1` (`dscacheutil -q host -a name foo.localhost`).

## Out of scope

- Code signing and notarization.
- Homebrew, apt and Windows.
- Auto-update.
- Telemetry.
