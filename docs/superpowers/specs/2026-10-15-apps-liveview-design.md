# Routes, deployments and serving apps — design (piece 5)

Piece 5 of 7. It builds on piece 3 (`Nobi.Universe`), piece 4 (`Nobi.Exec`) and the Elm foundation (`NobiWeb.ElmLiveView`). Terms are defined in `docs/GLOSSARY.md`.

## Goal

Nobi serves products, not single apps. A product is many `defapp`s over shared models. A **route table** declared in Nobi code maps URLs, with parameters, to apps. A **deployment** serves one universe's route table on one or more hosts. Locally, a deployment follows the universe's head, so every promotion goes live. Nobi's own UIs (console, MCP) are ordinary Phoenix routes, outside any deployment.

## Decisions (Marce)

- **Three kinds of routing:**
  1. **Deployed apps:** URL → deployment, through an internal production routing table. This is what makes rollback a pointer change.
  2. **Local apps:** the same mechanism; a deployment that follows a universe's head.
  3. **Nobi UIs:** plain Phoenix, not served through deployments.
- **Apps have internal routes with parameters.** `/post/:id` → `Forum.Post`, and `id` is part of the app's input.
- **Effects:** only `Cmd.none`, `Cmd.batch`, `Cmd.time.now` and `Cmd.random.int` run, plus `Cmd.navigate` (below). Every other effect shows a visible "not available yet" notice.
- **Live code and the model:** if `App.Model`'s signature is unchanged, the running model carries over. If it changed, the app re-runs `init` and shows "Model changed; app restarted".
- **Users are deferred, but the design leaves room for them:**
  - operators will get auth on the Nobi UIs and MCP;
  - app viewers will get an identity passed in through the app's input, the same way route parameters are.

## Out of scope (this piece)

- **Pinned deployments in production use:** remote nodes, pushing to them, rollback commands and real domains. Those are piece 7, deploy; this piece builds the table they use.
- **Query parameters**, and any route parameter type other than `Int`, `String` and `Uuid`.
- **Users and auth**, and app state persisted or shared between viewers.
- **`store`, `blob` and `ai` effects**, and model migration.
- **Serving outside dev/test.** Deployment serving is mounted in dev and test only, like `/mcp`, until auth exists.

## Language: `defroutes`

```
defroutes Forum do
  "/"           -> Forum.Threads
  "/post/:id"   -> Forum.Post
  "/settings"   -> Forum.Settings
end

def Forum.Post.init(id : Uuid) : (Forum.Post.Model, Cmd<Forum.Post.Msg>) do … end
```

- **A new declaration kind.** It is parsed, formatted, CID'd, staged, checked and committed like any other, and its symbol is the route table's name (`Forum`).
- **Patterns** are literal segments plus `:param` segments. Ordered, first match wins. Two patterns that match the same URLs are refused with `"duplicate-route"`.
- **Each target must be a `defapp`.** Its `init` parameters must be exactly the pattern's params, by name, with types `Int`, `String` or `Uuid` (`"route-mismatch"` otherwise).
- **The app-shape rule relaxes:** `init` may take parameters now. An app whose `init` takes parameters can only be opened through a route.
- **`Cmd.navigate(App, args…)`** is a new effect, type-checked as a special form:
  - `App` must be the target of exactly one route in the routes declaration that names it;
  - `args` must match that route's params.

  The host turns it into a URL in the same deployment. Plain `<a href="/post/…">` links also work, as ordinary navigation.
- **Image:** `__nobi__(:routes)` exports each route table as data, `%{name => [{pattern_segments, app, param_types}]}`, so the host can resolve URLs without re-reading declarations.

## Platform

### Deployments (`deployments` table, process-free like the CAS)

```
deployments(name text pk, universe text not null, routes text not null,
            commit integer null,          -- null = follow the universe's head
            hosts text[] not null default '{}',
            inserted_at, updated_at)
```

- **`Nobi.Deployment`** is the interface, and it is the only module that touches the table:
  - `list/0`, `get/1`, `create(name, universe, routes, opts)`;
  - `pin(name, commit)` and `follow(name)`;
  - `resolve(host) :: {:ok, deployment} | :error`.
- **At boot**, a deployment named `local` (universe `main`, routes `"Main"`, following head, hosts `["localhost", "127.0.0.1"]`) is created if missing. `<name>.localhost` resolves to deployment `<name>`, so several deployments can run side by side locally.
- **A pinned deployment** serves the image of that commit: replay history to that commit, then build the image, cached by hash. Rollback is `pin(name, older_commit)`. The mechanism exists in this piece; piece 7 adds its UX and remote use.

### Serving: `NobiWeb.DeploymentLive`

One generic `ElmLiveView` mounted on a catch-all route (`live "/*path"`), after every reserved Nobi route.

1. **`handle_params`:**
   1. Resolve the host to a deployment.
   2. Resolve the path through that deployment's route table, parsing params by type. A miss gives a 404 page.
   3. Mount the target app: `init(params…)`.
2. **The app loop**, through `Nobi.Universe` at the deployment's universe:
   - `update` on events;
   - `view` gives an `Html` value, rendered by `<.nobi_html>`.

   A runtime error, timeout or `degraded` result keeps the previous view and shows a banner. It never crashes.
3. **Events never send Nobi values to the browser.** Each render assigns handler ids (`e0`, `e1`, …) and keeps id → msg server-side.
   - `on-click` → `phx-click`.
   - `on-change` → the LiveView-idiomatic input binding, which the implementer picks and documents.
   - A constructor handler is applied to the input value through `Universe.apply`.
4. **Effects.**
   - `none` and `batch` are performed directly.
   - `time.now` and `random.int` map to the corresponding `Nobi.Elm.Effect`. The callback is applied through `Universe.apply`, which gives the msg.
   - `Cmd.navigate` becomes `push_patch` to the resolved URL, swapping the mounted app without a page reload.
   - Anything else shows a notice.
5. **Live code.** For a following deployment, the host subscribes to its universe's commits:
   - the route table is re-resolved;
   - the model carries over when `App.Model`'s signature is unchanged, otherwise `init` re-runs with a notice;
   - if the route or app disappears, a 404 page.

   A pinned deployment never changes until it is re-pinned.

### `NobiWeb.NobiHtml`

Safe rendering of `Html` values:
- elements pass through by tag;
- an allow-list of attributes, `href`/`src` restricted to http, https or relative;
- `phx-*` and `on*` names written as plain attributes are dropped;
- text is escaped and nothing renders as raw HTML.

### `Nobi.Universe` additions

- `apply(universe, fun, args, opts)`, with `Exec.apply` underneath.
- `apps(universe)` and `routes(universe)`.
- The CodeDb broadcasts `{:committed, universe, %{commit, image_hash}}` on `"universe:<name>"` after each promotion, performed after the state is persisted. `subscribe(universe)`.

### Nobi UIs (plain Phoenix, reserved prefix `/_`)

- `/_` lists universes and deployments.
- `/_/u/:universe` is the console: apps, routes, symbols, staged patches, history, health. It refreshes on commits.
- `/_/d/:deployment` shows a deployment: universe, routes, following or pinned commit, hosts, and links.
- **Reserved paths:** `/mcp` stays, and LiveDashboard moves under `/_` (`/dev/*` → `/_/dev/*`). The catch-all never sees `/_`, `/mcp`, `/live`, `/assets` or `/phoenix`.

### `mix nobi.start`

Creates and migrates the DB if needed, ensures `main` and the `local` deployment exist, starts the endpoint, and prints:
- the app URL (`http://localhost:4000`);
- the console (`/_`);
- MCP (`/mcp`).

## Testing

- **Language:**
  - parse, format and CID round-trip for `defroutes`;
  - the checker refuses unknown targets, param name or type mismatches, and duplicate routes;
  - `init` with parameters is accepted, and an unrouted parameterised app can still be committed;
  - `Cmd.navigate` is checked against the route table;
  - all piece-1 oracle tests stay green.
- **Codegen:** `__nobi__(:routes)` matches the declaration. A route-resolution unit test covers param parsing and a 404 on a type mismatch.
- **Deployment:**
  - create, get and resolve by host, including `<name>.localhost`;
  - pin and follow;
  - a pinned deployment serves the old commit after a new promotion;
  - rollback by re-pinning.
- **DeploymentLive**, with `Phoenix.LiveViewTest` on a fresh universe and deployment per test, using a small forum fixture (`Forum.Threads`, `Forum.Post(id)`, `Forum.Settings`):
  - `/` renders;
  - `/post/:id` passes `id`;
  - `Cmd.navigate` moves between apps;
  - a bad param gives a 404;
  - clicking and input changes update the model;
  - `random.int` renders;
  - an unsupported effect shows a notice;
  - a runtime error shows a banner;
  - live code: a body change re-renders and keeps the model, and a Model change re-inits.
- **NobiHtml:** the allow-list, injection, `javascript:` links, escaping and handler ids.
- **Console pages:** they render and refresh on commits.

## Done when

- The tests pass and `mix precommit` is green.
- On the dev server, staging a forum fixture into `main` with a `Main` route table serves it at `http://localhost:4000`, and a patch staged over MCP shows up live.
- The glossary gains **Route table**, **Deployment**, **Routing table** and **Console**.
