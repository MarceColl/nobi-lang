# Homepage copy

Every sentence on the page (`site/src/index.html.eex`), with the feature that backs it. Claude drafted it on 2026-10-17 from the current build; Marce edits it. Code samples, verdicts, CIDs and the terminal session are not listed: the page reads them from `site/samples/`, and `test/site/` checks them.

| Section | Sentence | Backing feature (file or test) |
|---|---|---|
| Hero | Every change typechecks, or it stays staged. | `KinokoWeb.Mcp.Tools` `stage_patch` (promotes only when the committed image typechecks); `test/site/samples_test.exs` |
| Hero | Kinoko is a code database and runtime for Yabu, a small typed language for web apps: Elm's architecture, Elixir's syntax, running on the BEAM. | `docs/GLOSSARY.md` (Kinoko, Yabu); `lib/kinoko/universe.ex`; `lib/kinoko_web/live/deployment_live.ex` |
| Hero | You or your agent stage a patch. | `stage_patch` in `lib/kinoko_web/mcp/tools.ex`; the console (`lib/kinoko_web/live/console/universe_live.ex`) |
| Hero | It is promoted only when the whole program still typechecks; otherwise you get the exact reasons. | `stage_patch` description and `staged_text/2` in `lib/kinoko_web/mcp/tools.ex`; `site/samples/verdicts/mistake.txt` |
| Hero | arm64 and x86_64. | `dist/kinoko-{macos,linux}-{arm64,x86_64}`; platform detection in `install.sh` |
| Hero | If `~/.local/bin` is not on your PATH, the installer prints the line to add. | `install.sh` (`install_dir` default `$HOME/.local/bin`; the PATH hint after "Installed kinoko") |
| Hero | `kinoko` creates its database, serves on localhost:4000 and opens the console. | `Kinoko.CLI` usage (`start`: create and migrate, start, open the console) and `port/1` (default 4000), `lib/kinoko/cli.ex` |
| Hero | Install line: `curl -fsSL https://github.com/<repo>/releases/latest/download/install.sh \| sh`. | `Mix.Tasks.Site.Build.install_url/0` (`@repo`); `.github/workflows/release.yml` stamps the repository into the release's `install.sh` (main's copy keeps `OWNER/kinoko` and refuses to run); `test/site/site_build_test.exs` |
| Hero | Badges: version, macOS · Linux. | `mix.exs` `@version`; `install.sh` supported OSes |
| See it run | One session with the release binary, from install to a first patch over MCP. | `site/samples/session.txt`, recorded from `dist/kinoko-macos-arm64` (see the task 2 report) |
| See it run | The patch is the counter from the next section, sent to the MCP endpoint as a `tools/call`. | `stage.json` in the recording: `site/samples/counter.yabu` as `tools/call stage_patch` |
| See it run | Kinoko answers in one line, and an `eval` shows the decrement stopping at zero. | `session.txt` last two commands (`promoted: counter`; `Counter.update(Counter.Msg.Decrement, %Counter.Model{count: 0})` gives `count: 0`) |
| See it run | Recorded from `kinoko-macos-arm64`. | the recording |
| See it run | There is no public release yet, so the installer was served from a local web server. | `install.sh` (`KINOKO_REPO=OWNER/kinoko`, `KINOKO_BASE_URL`) |
| See it run | Environment setup and server logs are trimmed; nothing is added. | the recording (raw pieces in `.superpowers/sdd/2026-10-17-landing/capture-raw/`) |
| Elm architecture | A Yabu app is one loop. | `KinokoWeb.Mcp.Instructions` (`@head`: "An app is one Elm-style loop") |
| Elm architecture | `init` gives the first model. `update` turns a message and a model into the next model. `view` draws the model as HTML, styled with Tailwind classes. | `KinokoWeb.Mcp.Instructions`; `site/samples/counter.yabu` |
| Elm architecture | `defapp` wires the three together. | `KinokoWeb.Mcp.Instructions` ("defapp Counter wires Counter.init / Counter.update / Counter.view") |
| Elm architecture | A model is plain data. Construction lists every field: `%Counter.Model{count: 0}`. | `KinokoWeb.Mcp.Instructions` ("Construction has NO defaults ... `missing-field`"); task 1 RED (`store.yabu` without `replies` was `missing-field`) |
| Elm architecture | Messages are a sum type, and a `case` must cover every variant. | `KinokoWeb.Mcp.Instructions` ("case arms ... must cover every variant") |
| Elm architecture | An invariant, checked whenever it runs: in an `eval` or a test. | `KinokoWeb.Mcp.Instructions` ("always(...) is checked when it runs: an `eval` that reaches it, or a `test`") |
| Elm architecture | Every name is fully qualified, so `Counter.update` means the same thing wherever it appears. | `KinokoWeb.Mcp.Instructions` ("Every name is fully qualified everywhere"); `docs/GLOSSARY.md` (Symbol) |
| Elm architecture | Yabu has no comments; the notes on this page are ours. | `Kinoko.Lang.Parser.program("# hi ...")` is `{:error, %{code: "parse", message: "unexpected character '#'"}}` (probe, 2026-10-17); `lib/kinoko/lang/lexer.ex` |
| Elm architecture | A product is several small apps over shared stores, not one app with a router inside. | `KinokoWeb.Mcp.Instructions`; `test/fixtures/yabu/forum.yabu` (Threads, Post, Settings apps) |
| Elm architecture | `defroutes` maps URL paths to apps, and `Cmd.navigate` moves between them. | `KinokoWeb.Mcp.Instructions` (defroutes, Cmd.navigate); `forum.yabu` |
| Elm architecture | Recreated on this page with the classes from `Counter.view`. | the figure's markup copies the classes of `counter.yabu` lines 31-38 |
| Code is a database | Kinoko stores each declaration on its own, addressed by its content. | `docs/GLOSSARY.md` (Declaration, CID); `Kinoko.Universe.symbols/1` returns a CID per symbol |
| Code is a database | A declaration's CID is the sha256 of its versioned canonical text, so reformatting it changes nothing, and the same declaration always has the same CID. | `docs/GLOSSARY.md` (Canonical text: "whitespace never changes it"; CID); `lib/kinoko/lang/cid.ex` (`sha256("yabu/1\n" <> canonical text)`) |
| Code is a database | You change code by staging a patch. | `stage_patch`, `lib/kinoko_web/mcp/tools.ex` |
| Code is a database | If the whole committed program still typechecks, the patch is promoted. | `stage_patch` description |
| Code is a database | If it does not, the patch stays staged, changes nothing, and carries one reason per problem. | `stage_patch` ("stays staged (inert)"); `reason_lines/1` |
| Code is a database | Committed / typechecks / staged / Blocked labels. | the console's code header and `reasons_callout` (`universe_live.ex`) |
| Code is a database | The CIDs and the reason come from a fresh universe; the test suite checks them against a live run. | `test/site/samples_test.exs` ("content addresses", "printed verdicts") |
| Compiler | A common slip: joining a string and an `Int`. | `site/samples/mistake.yabu` |
| Compiler | The verdict names the declaration, the kind of error and the expression at fault, in plain text that a person or an agent can act on. | `site/samples/verdicts/mistake.txt` (`Counter.label`, `[mismatch]`, `` in `count` ``) |
| Compiler | The fix is `String.from_int(count)`. Restage the same patch id and it promotes. | `test/site/samples_test.exs` "mistake.yabu promotes once its Int goes through String.from_int" |
| Persists | The model is session state. | `KinokoWeb.Mcp.Instructions` (STORED DATA: "the Model is session state and is gone on reload") |
| Persists | Durable data goes through `Cmd.store`. | `KinokoWeb.Mcp.Instructions`; `site/samples/store.yabu` |
| Persists | A model that declares `id : Uuid` is stored, and the store mints the id, so you never write it. | `KinokoWeb.Mcp.Instructions` ("A STORED model is a defmodel with `id : Uuid` ... Never write `id`"); `Kinoko.Data.insert/4` mints a v4 Uuid |
| Persists | `update` returns effects as data. The runtime runs them and sends the result back as a message. | `KinokoWeb.Mcp.Instructions` ("Cmd values (effects) are data ... A deployment serving the app runs them"); `lib/kinoko_web/live/deployment_live.ex` ("Steps" moduledoc) |
| Persists | Models grow by adding fields. | `KinokoWeb.Mcp.Instructions` (evolution); `samples_test.exs` (store over store_v1 promotes) |
| Persists | A new field needs a default (or is an `Option`), which rows stored before it read back as; a new field without one is refused. | `test/kinoko/data_test.exs` "rows written under v1 read under v2 with defaults", "Option round-trips; NULL is None for an Option"; `KinokoWeb.Mcp.Instructions` ("An Option<T> field takes no default (absent reads as Option.None)"); `samples_test.exs` "a new field without a default is refused" (`model-evolution`) |
| Persists | Construction still lists every field. | `KinokoWeb.Mcp.Instructions`; `store.yabu` writes `replies: 0` |
| Persists | Each open page runs its app's loop in its own Erlang process, served by Phoenix LiveView. | `KinokoWeb.DeploymentLive` (one LiveView process per connection, "one model per connection") |
| Persists | The code and every app's rows are SQLite files in one data directory. | `AGENTS.md` (Database); `Kinoko.Data` ("one SQLite file per deployment at `<data dir>/data/<deployment>.db`") |
| Persists | There is no database server to set up. | `ecto_sqlite3`; `Kinoko.Release.start/0` creates and migrates the file |
| Persists | Staged on top of a `Board.Topic` without `replies`, it promotes as an evolution of the stored model. | `samples_test.exs` (store_v1 then store: `promoted: store`) |
| Agents | Kinoko serves MCP at `/mcp`. | `lib/kinoko_web/endpoint.ex` / router `/mcp`; the banner in `session.txt` |
| Agents | When an agent connects, the server's instructions give it the syntax, the loop and the whole standard library. | `KinokoWeb.Mcp.Instructions` (the stdlib list generated from `Kinoko.Lang.Types.Stdlib`) |
| Agents | Then it works the loop you would. | THE LOOP in `KinokoWeb.Mcp.Instructions` |
| Agents | `create_universe` gives an agent its own code database to try things in, away from `main`. | `create_universe` in `lib/kinoko_web/mcp/tools.ex` |
| Agents | Look: `symbols` lists every committed signature, `read` shows one declaration's source, and `history` shows what was promoted. | `symbols`, `read`, `history` in `tools.ex` |
| Agents | Stage: `stage_patch` sends Yabu source under a patch id. | `stage_patch` in `tools.ex` |
| Agents | Read the verdict: `promoted: id`, or `staged: id` with one reason per line. | `stage_patch` output in `tools.ex` |
| Agents | Fix it and restage the same id; `list_staged` shows what is waiting. | `stage_patch` ("Restage the SAME id"), `list_staged` in `tools.ex` |
| Agents | Prove it: `eval` runs an expression against the committed code, and `test` runs a `deftest`. | `eval`, `test` in `tools.ex` |
| Agents | `claude mcp add --transport http kinoko http://localhost:4000/mcp` | `Kinoko.CLI.mcp_text/1` with the default port |
| Agents | `kinoko mcp` prints this line for your port, and a JSON config for other clients. | `Kinoko.CLI.mcp_text/1`; `session.txt` |
| Get started | One binary for macOS and Linux. | `dist/`; `mix kinoko.dist` (Burrito) |
| Get started | The installer checks the download's sha256, never uses sudo and never edits your shell files. | `install.sh` header and checksum step |
| Get started | Read the source / Releases / Glossary. | links built from `@repo` in `lib/mix/tasks/site.build.ex`; `docs/GLOSSARY.md` |
| Footer | Kinoko {version}. | `mix.exs` |
| Footer | Set in Newsreader, Chivo and IBM Plex Mono, under the SIL Open Font License. | `priv/static/fonts/OFL-*.txt` |
