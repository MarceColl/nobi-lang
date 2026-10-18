# Nobi

Nobi is an agent-oriented programming language and local runtime for web apps. Connect an MCP client, ask an agent to build an app in Nobi, and run it locally with per-deployment SQLite data and a console for inspecting the code and data.

Nobi source defines typed models, messages, functions, tests, apps, and routes. The checker reports errors to the agent; a patch becomes live only when the resulting code typechecks as a whole. See the [content extraction](docs/CONTENT_EXTRACTION.md) for a source-backed overview and the [glossary](docs/GLOSSARY.md) for system terminology.

## Run from source

Requires Elixir and Erlang/OTP. Install project dependencies and assets, then start Nobi:

```sh
mix setup
mix nobi.start
```

Nobi starts on `http://localhost:4000` by default. The console is at `http://localhost:4000/_`; MCP is at `http://localhost:4000/mcp`. Run `nobi mcp` for client configuration when using a release binary.

## Check changes

```sh
mix test
mix precommit
```

The site is built with `mix site.build`. Real language examples live in `site/samples/` and `test/fixtures/nobi/`.

## Project status

Nobi is under active development. The checked-in site describes the current release as local and single-user; hosted operation is not available yet. See [GitHub releases](https://github.com/MarceColl/nobi-lang/releases) for packaged binaries.
