# Running apps in the browser — design (piece 5)

Piece 5 of 7. It builds on piece 3 (`Kinoko.Universe`), piece 4 (`Kinoko.Exec`) and the Elm foundation (`KinokoWeb.ElmLiveView`). Terms are defined in `docs/GLOSSARY.md`.

## Goal

Any `defapp` in any universe runs in the browser at `/u/:universe/:app`. It is a live Elm loop: Yabu's `init`, `update` and `view` drive a LiveView. When the universe promotes new code, running apps pick it up without a reload. An index page per universe lists its apps, symbols, staged patches and history. `mix kinoko.start` brings the whole thing up.

## Decisions (Marce)

- **Effects:** only `Cmd.none`, `Cmd.batch`, `Cmd.time.now` and `Cmd.random.int` run. Every other effect (`store`, `blob`, `ai`) delivers nothing and shows a visible "not available yet" notice. No scope creep.
- **Live code and the model:** when a commit leaves `App.Model`'s signature unchanged, the running model carries over. When it changes, the app re-runs `App.init` and shows "Model changed; app restarted". There is no migration. A change to `App.Model` that breaks `update` or `view` doesn't promote in the first place, because it doesn't typecheck.

## Out of scope

- Persistent app state across reloads, or shared between viewers.
- `store`, `blob` and `ai` effects.
- Model migration.
- Auth.
- A standalone `kinoko` binary.
- Running apps in production. The routes are mounted in dev and test only, like `/mcp`.

## Shape

```
browser ──phx events──▶ KinokoWeb.AppLive (ElmLiveView, one per tab)
                          model   = the Yabu model value
                          handlers = %{"e17" => msg | {:change, ctor_fun}}   (server-side only)
                          image   = {universe, image_hash}
   init:    Universe.call(u, "App.init", [])            → {model, cmd}
   event:   Universe.call(u, "App.update", [msg, model]) → {model, cmd}
   render:  Universe.call(u, "App.view", [model])        → Html value → <.yabu_html> (HEEx)
   cmd:     Cmd → Kinoko.Elm.Effect (now/random) → result msg via Universe.apply(u, cb, [v])
   commits: PubSub "universe:<name>" → re-render on the new image (model kept or re-init)
```

Everything goes through `Kinoko.Universe`, which keeps the binding rule.

## Components

### `Kinoko.Universe` additions

- **`apply(universe, fun, args, opts)`** applies a Yabu function value, such as a `Cmd` callback or an `on-change` constructor, inside an Exec worker against that universe's current image. It returns `{:ok, value} | {:error, reason}`. Under the hood it is `Exec.apply(image, fun, args)`, a new Exec entry point.
- **`apps(universe)`** returns `[app_name]`, the committed `defapp` symbols.
- **Commit notifications.** The CodeDb broadcasts `{:committed, universe, %{image_hash, model_signatures}}` on `Phoenix.PubSub` topic `"universe:<name>"` after every promotion. That is an effect of the step, so it is performed after the state is persisted. `Universe.subscribe(universe)` subscribes the caller.

### `KinokoWeb.AppLive`

An `ElmLiveView` with `params: true`, mounted at `live "/u/:universe/:app"`.

**Model.**
```
%{universe, app, model, html, handlers, notice, error, model_sig}
```
- `model` is the Yabu value.
- `html` is the last view value.
- `handlers` maps handler ids to msgs.
- `model_sig` is the signature of `App.Model` the model was built under.

**Lifecycle.**
- **init:**
  1. Check the universe and app exist; otherwise render a clear "no such app" page.
  2. Call `App.init()` and render.
  3. On the connected mount only, subscribe to the universe's commits, then perform the `Cmd`.
- **Event `{"yabu", %{"h" => id, "value" => v}}`:** look the id up in `handlers`.
  - A plain msg: call `update`.
  - A `{:change, f}`: `Universe.apply(f, [v])` gives the msg, then call `update`.
  - Either way: perform the `Cmd`, then re-render.
- **Errors.** A runtime error, timeout or `degraded` result from any Yabu call keeps the previous model and view, and shows an error banner with the code and message. It never crashes the LiveView.
- **Commit message:**
  - If `App.Model`'s signature is unchanged, re-render with the new code.
  - Otherwise re-run `init` and set the notice "Model changed; app restarted".
  - If `App` was removed, show "app no longer exists".

**Effects.** `Cmd` values are data, `{:cmd, …}`. They are lowered to `Kinoko.Elm.Effect`:
- `none` → `[]`.
- `batch` → each item.
- `{:effect, "Cmd.time.now", _, [cb]}` → `Effect.now`. The callback applies `cb` to Unix milliseconds via `Universe.apply`, which yields the msg.
- `Cmd.random.int(lo, hi, cb)` → `Effect.random(lo..hi)`, then the same callback path.
- Anything else → a notice `"<effect> is not available yet"`, and no msg.

### `KinokoWeb.YabuHtml`

A function component, `<.yabu_html html={@html} handlers=… />`, that renders an `Html` value safely:
- **Elements** pass through by tag name.
- **Attributes:**
  - `class`, `id`, `type`, `value`, `placeholder`, `href` (http, https or relative only), `src` (same), `alt`, `title`, `name`, `checked`, `disabled`, `for` and `aria-*`/`data-*` are allowed.
  - Anything else is dropped.
  - `phx-*` and `on*` names written as plain attributes are dropped, so code can't inject bindings.
- **Event attributes:**
  - `on-click` → `phx-click="yabu" phx-value-h="eN"`.
  - `on-change` → `phx-change` on an enclosing `<form>` is awkward, so inputs with `on-change` get `phx-change="yabu"` through a small form wrapper or `phx-keyup`. The implementer picks the LiveView-idiomatic way and documents it.
  - Other `on-<event>` → `phx-<event>` where LiveView supports it; otherwise dropped with a notice.
- **Children:** text is escaped by HEEx; nothing ever renders as raw HTML.
- **Handler ids** are assigned in render order (`e0`, `e1`, …) and rebuilt on every render. The id → msg map lives in the LiveView process and is never sent to the browser.

### `KinokoWeb.UniverseLive`, at `/u/:universe`

The index page: apps, linking to `/u/:universe/:app`; symbols with their signatures; staged patches with reasons; history; and health. It subscribes to commits and refreshes. `/` lists the universes and links to each one.

### `mix kinoko.start`

Creates and migrates the DB if needed, ensures `main` exists, starts the endpoint, and prints:
- `Kinoko running at http://127.0.0.1:4000`
- the MCP URL `/mcp`
- the `/u/main` link.

## Testing

- **YabuHtml:**
  - attributes on the allow-list render and others are dropped;
  - `phx-` injection is dropped;
  - `href` of `javascript:` is dropped;
  - text is escaped;
  - nesting is handled;
  - handler ids are assigned and returned.
- **AppLive** with `Phoenix.LiveViewTest`, on a fresh universe per test:
  - the counter corpus renders, and clicking `+` increments;
  - an `on-change` input updates the model;
  - a `Cmd.random.int` app eventually renders the random value;
  - a `Cmd.store.*` app shows the "not available yet" notice;
  - a runtime error in `update` (division by zero) shows the banner and keeps the previous view;
  - an unknown app gives a clear page.
- **Live code:**
  - stage a body-only change to `view`: the open LiveView re-renders with the new text and keeps its count;
  - stage a change to `App.Model` together with `init`/`update`/`view`: it re-inits and shows the notice.
- **UniverseLive:** lists apps and symbols, and refreshes after a commit.
- **`mix kinoko.start`:** a smoke test of the task's pure parts. The server start itself is checked manually.

## Done when

The tests pass, `mix precommit` is green, the counter app runs at `/u/<universe>/Counter` on the dev server and updates live when a patch is staged over MCP, and the glossary gains **AppLive**.
