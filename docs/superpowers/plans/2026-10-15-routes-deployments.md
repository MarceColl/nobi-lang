> Storage moved to SQLite on 2026-10-16; see docs/superpowers/specs/2026-10-16-sqlite-design.md.

# Routes, Deployments and Serving Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Products made of many `defapp`s over shared models are served through a typed `defroutes` table. A `Kinoko.Deployment` maps hosts to a universe's route table, either following its head or pinned to a commit. A catch-all `DeploymentLive` runs the matched app. Kinoko's own UIs live under `/_`.

**Architecture:**
- **Language:** a new `defroutes` declaration kind, with checker rules and a `Cmd.navigate` special form.
- **Codegen:** exports the route tables, and a pure route matcher resolves URLs.
- **Universe:** gains `apply`, `apps`, `routes`, commit broadcasts and execution pinned at a commit.
- **Deployments:** a process-free table behind `Kinoko.Deployment`.
- **Serving:** one generic `ElmLiveView`, `DeploymentLive`, renders Yabu `Html` through a safe component.

**Tech Stack:** Elixir/Phoenix 1.8 LiveView, Ecto/Postgres, Phoenix.PubSub, plus the existing Kinoko.Lang, Exec, Universe and CodeDb.

**Spec:** `docs/superpowers/specs/2026-10-15-apps-liveview-design.md`. Glossary: `docs/GLOSSARY.md`.

## Global Constraints

- `Kinoko.Universe` is the only interface to universes, and `Kinoko.Deployment` the only interface to deployments. `Kinoko.Lang` stays pure and internal. No Yabu value is ever sent to the browser.
- **Route param types:** `Int`, `String` and `Uuid` only. A URL param that doesn't parse as its type is a 404.
- **New checker codes:** `"duplicate-route"`, `"route-mismatch"`, `"bad-route"` (malformed pattern or non-app target) and `"bad-navigate"`. Reasons keep the shape `%{name, code, message}`.
- **`deployments` table:** `deployments(name text pk, universe text not null, routes text not null, commit integer null, hosts text[] not null default '{}', inserted_at, updated_at)`. `commit` null means follow head.
- **At boot:** a deployment `local` is ensured, with universe `"main"`, routes `"Main"`, following head, hosts `["localhost", "127.0.0.1"]`. A host `<name>.localhost` resolves to deployment `<name>`.
- **Reserved paths**, which the catch-all never receives: `/_`, `/mcp`, `/live`, `/assets`, `/phoenix`, `/images` and `/favicon.ico`. LiveDashboard moves to `/_/dev/dashboard`. Deployment serving and `/_` are mounted only when `:mcp_enabled` (dev and test).
- **Effects that run:** none, batch, `time.now`, `random.int` and `navigate`. Anything else produces a notice: `"<effect name> is not available yet"`.
- **Model on a commit:** carried over when `App.Model`'s signature is unchanged; otherwise `init` re-runs with the notice `"Model changed; app restarted"`.
- `mix precommit` must be green after every task. VCS is jj; end each task with `jj commit -m "<msg>"`. Never use git commit or git stash.

## Review Focus

1. **A route whose param type is `Int`, and a URL with a non-numeric or overflowing value.** Expected: 404, never a crash. *Task 2.*
2. **A browser sending a forged `phx-click` id, or an id from a stale render.** Expected: ignored, never an arbitrary Yabu value. *Task 6.*
3. **App HTML trying to inject `phx-click`, `javascript:`, `<script>` or raw HTML.** Expected: dropped or escaped. *Task 5.*
4. **A commit that removes the routes declaration or the app currently open.** Expected: a 404 page, no crash. *Task 6.*
5. **A pinned deployment after the universe moves on.** Expected: it still serves the old commit, and a re-pin rolls it back or forward. *Task 4.*

---

### Task 1: `defroutes` in the language

**Files:**
- Modify the lexer, parser, AST, format and checker modules under `lib/kinoko/lang/` (`types/check/decl.ex`, `jsx_app.ex` or wherever the app shape is checked), plus `types/extract.ex`.
- Tests: `test/kinoko/lang/routes_test.exs`.

**Interfaces:**
- **AST:** `{:defroutes, meta, [name, [{segments, app_symbol}]]}`, where a segment is `{:lit, "post"} | {:param, "id"}` and `/` is `[]`.
- **Signature:** `{:routes, [{segments, app_symbol}]}`.
- **Deps:** the target app symbols and their `init` functions.
- **`Cmd.navigate(App, args…)`:** checked as a special form. Its type is `Cmd<msg>` for the enclosing context's msg type, via a fresh type var unified as `Cmd<a>` like the other effects. `App` must be routed in exactly one `defroutes` and `args` must match that route's params (`"bad-navigate"`). The resolution is recorded in node meta for codegen.
- **App shape:** `init` may take parameters, whose types must be `Int`, `String` or `Uuid`.

- [ ] **Step 1 (failing tests):**
  - parse, format and parse again; CID stable across whitespace;
  - checker accepts the forum fixture: `Forum.Threads` (no params), `Forum.Post` with `init(id : Uuid)`, `Forum.Settings`, and a `defroutes Forum` declaration;
  - refuses: an unknown target; a non-app target; a param name mismatch; a param type mismatch (`init(id : Int)` routed as `/post/:slug`); a duplicate pattern (`/post/:a` vs `/post/:b`); a param type other than `Int`, `String` or `Uuid`;
  - `Cmd.navigate(Forum.Post, uuid_expr)` is OK; wrong arity or type gives `"bad-navigate"`; an unrouted app gives `"bad-navigate"`;
  - staging through `Kinoko.Universe` promotes the fixture;
  - the piece-1 oracle tests stay green.
- [ ] **Step 2:** Implement. The pattern string is parsed at parse time into segments; malformed patterns (`//`, empty param name, `:` mid-segment) give a parse error. Save the forum fixture as `test/fixtures/yabu/forum.yabu`, a small but real product: models, a thread list, a post view with `id`, settings, navigation between them, and `defroutes Forum`.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "feat(lang): defroutes, parameterised init, Cmd.navigate"`.

### Task 2: Codegen of routes and the pure route matcher

**Files:** modify `lib/kinoko/lang/codegen*.ex` and `lib/kinoko/lang/rt*.ex`; create `lib/kinoko/lang/routes.ex`; tests `test/kinoko/lang/routes_codegen_test.exs`.

**Interfaces:**
- `__yabu__(:routes)` returns `%{routes_name => [%{segments, app, params: [{name, type}]}]}`.
- `Cmd.navigate` values are `{:cmd, {:effect, "Cmd.navigate", nil, [app_symbol, args]}}`.
- `Kinoko.Lang.Routes.match(table_entries, path :: String.t()) :: {:ok, app, [arg_values]} | :not_found`. It is pure; it parses `Int` (i64 range), `Uuid` (canonical) and `String` (URL-decoded).
- `Kinoko.Lang.Routes.path(table_entries, app, args) :: {:ok, String.t()} | :error`, the reverse for navigate. It URL-encodes.

- [ ] **Step 1 (failing tests):** match the root, literals, params by type, order (first match wins), `Int` overflow and non-numeric → `:not_found`, a bad `Uuid` → `:not_found`, trailing slash handling (decide and document; recommended: `/post/1/` matches `/post/1`), and percent-decoding. `path` round-trips with `match`. Codegen exports the routes of the forum fixture.
- [ ] **Step 2:** Implement, then `mix precommit`, then `jj commit -m "feat(lang): route tables in images, pure matcher"`.

### Task 3: `Kinoko.Universe` additions

**Files:** modify `lib/kinoko/universe.ex`, `lib/kinoko/code_db.ex` and `lib/kinoko/exec.ex`; tests extend `test/kinoko/universe_test.exs`.

**Interfaces:**

```elixir
Universe.apply(universe, fun, args, opts) :: {:ok, value} | {:error, reason}     # Exec.apply in a worker against the current image
Universe.apps(universe) :: [app_symbol]
Universe.routes(universe) :: %{routes_name => entries}
Universe.subscribe(universe) :: :ok                                              # PubSub "universe:<name>"
# broadcast after persist: {:committed, universe, %{commit: n, image_hash: h}}
Universe.at(universe, commit) :: {:ok, handle} | {:error, reason}               # a pinned view: replay history to `commit`, fetch decls from CAS, build snapshot; cached by image hash
Universe.call(handle, symbol, args, opts) / Universe.apply(handle, fun, args, opts) / Universe.routes(handle)   # same API accepting a handle
```

`commit` is the 1-based index into the universe's history.

- [ ] **Step 1 (failing tests):**
  - `apply` of a closure and of a constructor fun;
  - `apps` and `routes` on the forum fixture;
  - a subscriber receives `{:committed, …}` after a promotion and nothing after a staged-only patch;
  - `at(u, 1)` still answers with commit 1's code after commit 2 changed it;
  - `at` with an out-of-range commit gives an error.
- [ ] **Step 2:** Implement.
  - The broadcast is an `Effect` from CodeDb's `update`, so it is performed after persist (piece 2 ordering). Use `Kinoko.PubSub`.
  - `at` builds through `Lang` and `Cas` in the caller, never inside CodeDb state, and caches by image hash.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "feat: Universe apply/apps/routes/subscribe/at"`.

### Task 4: Deployments

**Files:** a migration `create_deployments`, `lib/kinoko/deployment.ex`, and a boot ensure in `application.ex` (same pattern as `Registry.ensure_main`); tests `test/kinoko/deployment_test.exs`.

**Interfaces:**

```elixir
Deployment.create(name, universe, routes, opts \\ [commit: nil, hosts: []]) :: :ok | {:error, :exists | :bad_name | :no_such_universe}
Deployment.get(name) :: {:ok, d} | :error             # d = %{name, universe, routes, commit, hosts}
Deployment.list() :: [d]
Deployment.pin(name, commit) / Deployment.follow(name) :: :ok | {:error, _}
Deployment.resolve(host) :: {:ok, d} | :error         # exact host match first, then "<name>.localhost"
Deployment.ensure_local() :: :ok
Deployment.target(d) :: {:ok, universe_or_handle}     # head → universe name; pinned → Universe.at(universe, commit)
```

- [ ] **Step 1 (failing tests):** create, get, list; duplicate; bad name; unknown universe; pin/follow round trip; resolve exact host, `foo.localhost`, unknown host; `ensure_local` is idempotent; Review Focus 5 (pinned serves the old commit after a promotion; re-pin changes it).
- [ ] **Step 2:** Implement, then `mix precommit` and `MIX_ENV=dev mix ecto.migrate`, then `jj commit -m "feat: deployments table and Kinoko.Deployment"`.

### Task 5: `KinokoWeb.YabuHtml`

**Files:** `lib/kinoko_web/components/yabu_html.ex`; test `test/kinoko_web/yabu_html_test.exs`.

**Interfaces:** `YabuHtml.prepare(html_value) :: {rendered_tree, handlers :: %{"eN" => msg | {:change, fun}}}`, which is pure, plus a function component `<.yabu_html tree={…} />` that renders the prepared tree. Handler ids are `e0…` in render order.

- [ ] **Step 1 (failing tests):**
  - allow-listed attributes pass through; anything else is dropped;
  - a plain attribute named `phx-*` or `on*` is dropped;
  - `href`/`src` with `javascript:` or `data:` is dropped, while http, https and relative URLs are kept;
  - text and attribute values are escaped, and `<script>` as text renders inert;
  - `on-click` becomes `phx-click="yabu"` with `phx-value-h="eN"`;
  - `on-change` gets the documented input binding;
  - nested elements work;
  - handler ids are stable for the same tree.
- [ ] **Step 2:** Implement. Decide the `on-change` binding (recommended: `phx-change="yabu"` on the element itself plus a `name` and `phx-value-h`; check what LiveView supports on bare inputs, and wrap in a form if required) and document it. Then `mix precommit` and `jj commit -m "feat(web): safe Yabu Html rendering"`.

### Task 6: `KinokoWeb.DeploymentLive` and routing

**Files:** `lib/kinoko_web/live/deployment_live.ex`; modify `router.ex` (reserved `/_` scope, LiveDashboard move, catch-all last); tests `test/kinoko_web/deployment_live_test.exs`.

**Behaviour:** see the spec's "Serving" section. It is an `ElmLiveView` with `params: true`.
- **Model:** `%{deployment, target, routes_name, app, args, model, model_sig, tree, handlers, notice, error}`.
- **Events:** `{"yabu", %{"h" => id} = params}`. An unknown id is ignored (Review Focus 2).
- **Navigate:** resolved with `Routes.path` and executed with a `patch` host effect.
- **Commits:** handled for following deployments only.

- [ ] **Step 1 (failing tests):** use `Phoenix.LiveViewTest` with `conn` host set (`%{conn | host: "<name>.localhost"}`), on a fresh universe plus deployment per test, with the forum fixture staged:
  - `/` renders the thread list;
  - `/post/<uuid>` renders with `id`;
  - a navigate click moves to `Forum.Post` through `push_patch`;
  - `/post/notauuid` gives a 404;
  - an unknown host gives the "no deployment" page;
  - a click and an input change update the model;
  - a `random.int` app renders;
  - a store effect shows the notice;
  - a division by zero in `update` shows a banner and keeps the previous view;
  - Review Focus 2 and 4;
  - live code: a body-only change re-renders with the model kept, and a Model change re-inits with the notice;
  - a pinned deployment doesn't change on commit.
- [ ] **Step 2:** Implement.
  - The catch-all route goes last.
  - Ensure `/mcp` and `/_` still work, and that LiveDashboard is reachable at `/_/dev/dashboard`.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "feat(web): DeploymentLive serves route tables"`.

### Task 7: Console under `/_`, `mix kinoko.start`, glossary

**Files:** `lib/kinoko_web/live/console/{index,universe,deployment}_live.ex`, `lib/mix/tasks/kinoko.start.ex`, `docs/GLOSSARY.md`; tests `test/kinoko_web/console_test.exs`.

- [ ] **Step 1 (failing tests):**
  - `/_` lists universes and deployments;
  - `/_/u/:universe` shows apps, routes, symbols, staged patches with reasons, history and health, and refreshes after a commit (stage, then assert the new symbol appears);
  - `/_/d/:name` shows the deployment and its links.
  - Pages are styled with Tailwind (AGENTS.md: polished, no daisyUI components).
- [ ] **Step 2:** Implement.
  - `mix kinoko.start`: ensure the DB (`ecto.create` and `ecto.migrate`), `main` and `local`, then start the endpoint (`Mix.Tasks.Phx.Server` with the server enabled) and print the URLs. A test covers a pure helper, the URL banner.
  - Glossary: add **Route table** (`defroutes`), **Deployment**, **Routing table** and **Console**.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "feat: console under /_, mix kinoko.start, glossary"`.
