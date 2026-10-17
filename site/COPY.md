# Homepage copy

Every sentence on the page (`site/src/index.html.eex`), with the feature that backs it. Marce approved the copy on 2026-10-17; it is used verbatim. The counter sample and the agent-run block are not prose: the page reads them from `site/samples/`, and `test/site/` checks them.

| Section | Sentence | Backing feature (file or test) |
|---|---|---|
| Header | kinoko (wordmark, with the mushroom glyph) | `mix.exs` (app `:kinoko`) |
| Header | v{version} | `mix.exs` `@version` |
| Header | macOS · Linux | `dist/kinoko-{macos,linux}-{arm64,x86_64}`; `install.sh` supported OSes |
| Title | Kinoko | `mix.exs` (app `:kinoko`) |
| Title | A local runtime for web apps built by coding agents. | `Kinoko.CLI` `start` serves on localhost; apps are served by `KinokoWeb.DeploymentLive`; the run in `site/samples/agent-run.jsonl` |
| Title | Connect Claude Code (or any MCP client) to Kinoko and ask it to build an app. | MCP at `/mcp` (`lib/kinoko_web/router.ex`, `lib/kinoko_web/mcp/tools.ex`); `Kinoko.CLI.mcp_text/1` |
| Title | The agent writes it; Kinoko runs it on your machine with its own database and an admin console. | `create_deployment` in `tools.ex`; `Kinoko.Data` (one SQLite file per deployment under the data directory); the console at `/_` (`KinokoWeb.Console`) |
| Getting started 1 | Install: `curl -fsSL <install_url> \| sh` | `Mix.Tasks.Site.Build.install_url/0` (`@repo`, `KINOKO_REPO`); `.github/workflows/release.yml` stamps the repository into the release's `install.sh` (main's copy keeps `OWNER/kinoko` and refuses to run); `test/site/site_build_test.exs` |
| Getting started 2 | Start Kinoko. It opens the console in your browser. `kinoko` | `Kinoko.CLI.parse([])` is `start`; `announce/1` opens `<base>/_` unless `--no-open` (`lib/kinoko/cli.ex`) |
| Getting started 3 | Connect your agent: `claude mcp add --transport http kinoko http://localhost:4000/mcp` | `Kinoko.CLI.mcp_text/1` with the default port (`port/1`, 4000) |
| Getting started 3 | Other clients: `kinoko mcp` prints the config. | `Kinoko.CLI.mcp_text/1` ("Other clients (JSON config)") |
| Getting started 4 | Ask for an app: "Build me a forum with threads and replies, served at forum.localhost." | the prompt of the recorded run below |
| Getting started 4 | What the agent did / Kinoko tool calls, from a recorded run (the table's caption; columns Tool, Argument, Result). The rows under it. | `Mix.Tasks.Site.Build.agent_run/1` reads `site/samples/agent-run.jsonl`: each `mcp__kinoko__*` call in order, its key argument, and its result's first line (or its `URL:` line), clipped. `test/site/site_build_test.exs` checks the table has one row per call of the capture, in order. |
| Getting started 4 | The agent's summary: "The forum is live at http://forum.localhost:4123/ in Kinoko's main universe." | the first sentence of the capture's `result` event, Markdown removed (`agent_run/1`) |
| Getting started 4 | Recorded with Kinoko on port 4123. | the run below; 4000 was left to the developer's own Kinoko |
| Getting started 5 | Open it. The app is at `forum.localhost:4000`. | `create_deployment` answers `URL: http://forum.localhost:<port>/`; `KinokoWeb.DeploymentStatus` resolves the deployment a request's host reaches, and `KinokoWeb.DeploymentLive` serves it; the run served it at `forum.localhost:4123` |
| Getting started 5 | The console at `localhost:4000/_` shows its code and data. | `scope "/_", KinokoWeb.Console` (`router.ex`); the console's code and data views |
| Getting started 5 | Screenshot (`site/src/forum.webp`) | the forum from the run, at `http://forum.localhost:4123/`, after one thread and one reply were posted through its own form (headless Chrome, 2026-10-17); cropped, nothing edited |
| Getting started 5 | Caption: The forum from the recorded run, at `forum.localhost:4123`, after one thread and one reply. Unedited. | the screenshot's provenance, above |
| An example app | `counter.yabu` | `site/samples/counter.yabu`; `test/site/samples_test.exs` "counter.yabu promotes" |
| Status | v0.1. | `mix.exs` `@version` (major.minor; `test/site/site_build_test.exs`) |
| Status | macOS and Linux. | `dist/kinoko-{macos,linux}-{arm64,x86_64}`; `install.sh` supported OSes |
| Status | Local and single-user, no hosting yet. | `Kinoko.CLI` serves on localhost; no accounts; no hosted offering |
| Links | Source · Releases | links built from `@repo` in `lib/mix/tasks/site.build.ex` |
| Footer | The mushroom glyph (labelled "Kinoko") | |
| Footer | Set in Geist and Geist Mono, under the SIL Open Font License. | `site/fonts/OFL-geist.txt` (Geist 1.3.1 from npm `geist`, variable woff2) |

## Copy changes in the restyle (2026-10-17)

The restyle (Geist, monochrome, light and dark) kept the approved copy. The approved copy had no em dashes, so none were rewritten. What changed:

- The header now carries the version and "macOS · Linux" (it had the Source and Releases links, which stay in Links).
- The version moved from the footer ("Kinoko {version}.") to the header; the footer is the glyph and the font line.
- The font line names Geist and Geist Mono instead of Newsreader, Chivo and IBM Plex Mono.
- The screenshot has a caption saying what it is.
- The run block is a table; its caption joins the old title and subtitle, and its columns are Tool, Argument and Result. The `→` between a call and its result is gone.
- The prompt in step 4 is set in quotation marks (CSS), its text unchanged.

## The recorded run (2026-10-17)

- Binary: `mix kinoko.dist macos_arm64`, built from the parent of this change.
- Kinoko: `PORT=4123`, a fresh temporary `KINOKO_DATA` and `HOME`, `kinoko start --no-open`. Port 4123, not 4000, so a developer's own Kinoko was left alone.
- Agent: `claude -p "Build me a forum with threads and replies, served at forum.localhost." --mcp-config <kinoko at http://localhost:4123/mcp> --strict-mcp-config --allowedTools "mcp__kinoko__*" --disallowedTools "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit" --output-format stream-json --verbose`, from an empty directory.
- Result: 10 turns, $0.54, 82 s, no refused tool calls; `curl -H 'Host: forum.localhost:4123' http://127.0.0.1:4123/` rendered "The Forum".
- `site/samples/agent-run.jsonl` keeps the run's `tool_use`, `tool_result`, assistant text and `result` events, each line verbatim. The `system` events (the client's tool list and hooks) and the thinking blocks are left out.
