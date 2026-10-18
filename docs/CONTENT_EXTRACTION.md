# Nobi content extraction

**Purpose:** source-grounded starting point for explaining Nobi to people. This is an extraction from the repository, not approved landing copy. Claims below point to implementation, tests, or existing project copy. Recheck them against the source before publishing.

## One-sentence description

Nobi is an agent-oriented programming language with a local runtime for building and serving web apps. Agents use MCP tools to write Nobi declarations; Nobi checks and runs them, serves the app locally, and gives the person a console for its code and data.

**Evidence:** `lib/nobi/lang/`, `lib/nobi_web/mcp/tools.ex`, `lib/nobi_web/mcp/instructions.ex`, `lib/nobi/cli.ex`, `lib/nobi_web/router.ex`, `lib/nobi/data.ex`, `site/src/index.html.eex`.

## What a person gets

- A local web app built by an agent, served by Nobi at a local address.
- A built-in console for inspecting universes, declarations, deployments, code, and data.
- A language with explicit models, messages, app update/view functions, routes, and tests.
- A workflow that can give an agent immediate compiler/type-checker feedback, run declared tests, and exercise a deployed app through MCP.
- Persistent per-deployment data stored in SQLite.

The checked-in recorded forum run in `site/samples/agent-run.jsonl` and its screenshot at `site/src/forum.webp` show one concrete app build. The current public page describes this flow in `site/src/index.html.eex`; `site/COPY.md` maps its sentences to implementation evidence.

## How Nobi works

1. A person runs Nobi locally and connects an MCP client.
2. The agent reads Nobi's `guide`, then uses tools such as `stage_patch`, `read`, `symbols`, `eval`, and `test` to work on a named universe.
3. Nobi parses, formats, and statically checks declarations. A patch promotes atomically when the resulting committed image typechecks; otherwise it stays staged with reasons.
4. A committed `defapp` and `defroutes` can be served as a deployment. Each deployment has its own SQLite-backed app data; the console shows code and data.
5. The agent can use `send` to drive a deployed app and observe effects and resulting state. This executes effects for real and may write the deployment's data.

**Evidence:** MCP tools and semantics in `lib/nobi_web/mcp/tools.ex`; agent workflow and language forms in `lib/nobi_web/mcp/instructions.ex`; promotion behavior in `lib/nobi/lang/universe.ex`; data behavior in `lib/nobi/data.ex`.

## Language shape

Nobi source is Elixir-flavoured and statically typed. Its top-level declarations include `def`, `defmodel`, `deftype`, `deftest`, `defapp`, and `defroutes`. Apps use an Elm-style loop: `init` returns a model and command, `update` returns the next model and command, and `view` returns typed HTML. JSX-like markup uses typed messages and Tailwind class names.

The real counter sample (`site/samples/counter.nobi`) demonstrates a model, message variants, typed functions, an invariant, a view, and an app declaration. `docs/GLOSSARY.md` defines the code store, universes, images, execution, effects, persistence, and deployments.

## Differentiating mechanisms visible in the code

- **Short edit-to-feedback path:** MCP tools expose stage, read, symbols, eval, test, and history directly. Type-check failures return structured reasons. See `lib/nobi_web/mcp/tools.ex`.
- **Atomic checked changes:** staged patches promote only when the whole resulting image typechecks. History records promotions. See `lib/nobi/lang/universe.ex`.
- **Incremental checking:** the language uses Salsa memoization around declarations and dependencies. See `lib/nobi/lang/salsa.ex` and `lib/nobi/lang/universe/db.ex`.
- **Deterministic simulation:** `Nobi.Elm.Sim` can explore interleavings or seeded random walks for Elm-style modules, virtualizing time and async outcomes while checking invariants. It is an Elixir runtime facility; this extraction does not establish that agents can invoke simulation through the Nobi language or MCP today.
- **Managed local persistence:** `Nobi.Data` uses one SQLite file per deployment and type-directed codecs. The current site says local and single-user, with no hosting yet.

## Current availability and limits

The checked-in landing page identifies the project as version 0.1, supports macOS and Linux releases, and describes a local, single-user runtime with no hosting yet (`site/src/index.html.eex`, `install.sh`, `lib/mix/tasks/nobi.dist.ex`). Do not describe managed hosting as available based on this checkout.

The code includes persistence and deployment abstractions, but this extraction does not verify remote managed infrastructure, queues, hosted operation, or a self-hosted-versus-managed product offer. Treat those as roadmap or positioning claims until a concrete implementation and supported user path are identified.

## Messaging evidence and guardrails

- Lead with the agent's concrete workflow and the running app a person can open. “A language for agents” describes the category but does not, by itself, explain the human outcome.
- Prefer a real Nobi program and a real recorded run over generic AI imagery or broad claims.
- Describe feedback as specific capabilities: type-check feedback, declared `deftest` execution, and the Elixir-side deterministic simulator. Do not imply one automatic end-to-end simulation feature unless its agent-facing path is confirmed.
- Distinguish Nobi's internal language/runtime from the surrounding Phoenix web application and its Elixir facilities.
- Label alpha/development status plainly if used. Do not present ambition (for example, “best in the world”) as measured fact.

## Existing content that needs attention

- `README.md` now introduces Nobi, explains the local MCP workflow and source setup, and points to the content extraction and glossary. Keep installation details aligned with the checked-in commands and release path.
- `site/COPY.md` is much more useful and maps the landing page's sentences to evidence. However, its recorded agent run describes tool names with the former `kinoko` prefix; check the captured run and generated tool names before reusing that detail as current copy.
- `docs/GLOSSARY.md` is a substantial technical glossary. It can support documentation and content work, but it is not a short newcomer introduction.

## Useful source map

| Topic | Start here |
|---|---|
| Agent-facing guide and syntax | `lib/nobi_web/mcp/instructions.ex` |
| Agent-facing tool set | `lib/nobi_web/mcp/tools.ex` |
| Language pipeline | `lib/nobi/lang/lexer.ex`, `lib/nobi/lang/ast.ex`, `lib/nobi/lang/types/`, `lib/nobi/lang/codegen.ex` |
| Universe and patch semantics | `lib/nobi/universe.ex`, `lib/nobi/lang/universe.ex` |
| Elm-style runtime and simulation | `lib/nobi/elm/`, `lib/nobi/elm/sim.ex` |
| Per-deployment data | `lib/nobi/data.ex` |
| Local installation and runtime | `install.sh`, `lib/nobi/cli.ex`, `lib/nobi/deployment/` |
| Landing page and evidence | `site/src/index.html.eex`, `site/samples/`, `site/COPY.md`, `test/site/` |
