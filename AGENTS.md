# Nobi repository guide

Nobi is an Elixir/Phoenix project and an agent-oriented language/runtime. The main parts are `lib/nobi/lang/` (parser, formatter, type checker and code generation), `lib/nobi/universe.ex` and `lib/nobi/lang/universe/` (versioned code state), `lib/nobi/elm/` (Elm-style runtime), `lib/nobi_web/` (console, app hosting and MCP), `site/` (project site and real samples), and `test/`.

<important if="you need to install dependencies, run the app, build the site, or check changes">
- `mix setup` installs dependencies, initializes SQLite and builds assets.
- `mix phx.server` starts the Phoenix app; `mix nobi.start` starts Nobi's local runtime.
- `mix test` runs the test suite. `mix test test/site` checks the site samples and is the Pages workflow gate.
- `mix site.build` builds the static site into `site/dist`.
- `mix precommit` compiles with warnings as errors, unlocks unused dependencies, formats, and runs tests.
- `cd spec/lean && lake build && lake test` builds and checks the Lean spec of the core language (needs elan; see `spec/README.md`).
- SQLite is the only database. Tests use `.nobi/test.db`; don't mark database-writing tests `async: true`.
</important>

<important if="you are changing Nobi syntax, type checking, code generation, or language semantics">
- Treat `lib/nobi/lang/` and `lib/nobi_web/mcp/instructions.ex` as the language contract. Keep parser, formatter, checker, code generator and agent guide aligned.
- Add or update focused tests and golden/oracle fixtures for language behavior. Check existing patterns in `test/nobi/lang_test.exs`, `test/nobi/nobi_golden_test.exs`, and `test/fixtures/nobi/`.
- A universe promotes a set of staged declarations only when the complete committed image typechecks. Preserve that atomicity and append-only history.
</important>

<important if="you are changing Elm apps, effects, persistence, deployments, or simulation">
- `Nobi.Universe` is the public language interface. `Nobi.Data` stores each deployment's app data in SQLite; effects run when the deployed app runs.
- Keep app updates pure and represent side effects as `Cmd` values. The deterministic simulator is `Nobi.Elm.Sim`; keep tests independent of real network and process effects where possible.
</important>

<important if="you are changing the console, Phoenix UI, assets, or site">
- Follow the existing module and template patterns in `lib/nobi_web/` and `site/src/`; avoid introducing new frontend dependencies without need.
- Site copy and claims are tracked in `site/COPY.md`. Keep it aligned with `site/src/index.html.eex`, backed by source or tests, and use real checked-in samples rather than invented syntax.
- `test/site/` covers rendered site content and samples; update it when changing site behavior or examples.
</important>
