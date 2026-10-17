# Emberforge on Nobi: gap log

Emberforge (a WoW theorycrafting workbench) is being ported onto Nobi as a stress test. The Rust simulator is kept and runs as pure WASM, with JSON strings in and out. Everything else becomes Nobi: job scheduling, storage and the UI. Today that code is a React single-page app (about 2,400 lines of JSX and 2,900 of CSS) and a Cloudflare Worker with Durable Objects (about 400 lines).

Each gap below records:

- **Needs**: what Emberforge needs
- **Today**: what Nobi does today, with a file reference
- **Workaround**: what we would have to do without the gap closed
- **Proposal**: what Nobi could add
- **Status**: `open`, `in progress`, `closed (<change>)` or `wontfix (<why>)`

As a stress test, the default is to close the gap in Nobi rather than take the workaround.

Priority: **P0** blocks the spike (one sim run that shows its DPS). **P1** blocks the full port. **P2** is a quality or polish gap.

## Summary

| ID | Gap | Pri | Status |
|---|---|---|---|
| G01 | No foreign or WASM calls | P0 | open |
| G02 | No `Float` type | P0 | open |
| G03 | No timer `Cmd` | P0 | open |
| G04 | 5 s call limit is fixed | P0 | open |
| G05 | Apps run only while a browser is connected | P1 | open |
| G06 | Typed JSON only; no float or dynamic values | P1 | open |
| G07 | Events carry no payload; no on-input | P1 | open |
| G08 | No hover or popover primitive | P2 | open |
| G09 | No `svg` and no `style` attribute | P2 | open |
| G10 | Store has no queries or expiry | P2 | open |
| G11 | No generic defs | P1 | open |
| G12 | No `Html.map` or generic `Html<a>` | P2 | open |
| G13 | No modulo; one-expression case arms; no list patterns | P2 | open |
| G14 | No JSON or HTTP routes | P2 | open |
| G15 | Public serving waits on auth | P1 | open |
| G16 | Deterministic simulation testing is Elixir-only | P2 | open |
| G17 | Effects in flight are lost on restart | P2 | open |

## Gaps

### G01. No foreign or WASM calls (P0)

- **Needs:** call `simulate`, `inspect`, `resolve_character`, `catalog` and `optimization_begin`/`optimization_advance`. Each is a pure function, JSON string in and JSON string out.
- **Today:**
  - There is no FFI.
  - Stdlib calls map by name to `Nobi.Lang.Rt.Stdlib` through a table built at compile time (`lib/nobi/lang/rt/stdlib.ex:53-63`).
  - `mix.lock` has no WASM runtime.
- **Workaround:** none in Nobi itself. We would have to rewrite the simulator in Nobi or call it as a separate HTTP service, and Nobi has no HTTP either.
- **Proposal:**
  - Add a builtin like `Wasm.call(module, fn, String) : Result<String, String>`.
  - Run it with `wasmex` (wasmtime).
  - Address modules by content hash so they fit the CAS.
  - Add a signature row in `lib/nobi/lang/types/stdlib.ex:42-140` and an implementation in `rt/stdlib.ex`; codegen resolves it through `stdlib!` (`lib/nobi/lang/codegen/expr.ex:501-503`).
- **Open questions:**
  - Should it be a plain pure call (inside the worker's limits) or a `Cmd` (run as an `Fx.task`, result returned as a Msg)?
  - How do modules get into a universe or deployment?
  - Should we add a fuel or epoch limit inside wasmtime?
- **Emberforge side:** replace the `wasm-bindgen` exports with a plain C ABI (`alloc`/`free` plus pointer and length), because Nobi won't have the JS glue.

### G02. No `Float` type (P0)

- **Needs:** DPS, variance, standard error, damage averages, spell coefficients, stat conversions.
- **Today:** the builtin types are `Int String Bool Uuid Unit Store Href` (`lib/nobi/lang/types/extract.ex:26`). `Int` is a checked i64, and there are no floats anywhere in lang or rt.
- **Workaround:** keep all floats inside WASM and add a Rust "presenter" function that returns integers and preformatted strings. It works, but Nobi then can't compute anything, such as aggregates, sorting by DPS or deltas.
- **Proposal:**
  - Add `Float` with arithmetic, comparison, `Float.from_int`, `round`/`floor`/`ceil`, `sqrt` and `to_string(precision)`.
  - Decode JSON numbers into it.
  - Decide what NaN and infinity do. Making them runtime errors would match checked `Int`.

### G03. No timer `Cmd` (P0)

- **Needs:**
  - A job loop: tick, run N iterations, save the checkpoint, tick again.
  - Polling the optimizer.
  - Debouncing validation while you type in the rotation editor.
- **Today:**
  - The Nobi stdlib has no delay.
  - The Elixir runtime already dispatches `after_ms` (`lib/nobi/elm/runtime.ex:251, 300`).
- **Workaround:** none that works without a timer.
- **Proposal:**
  - Add `Cmd.after(ms, Msg)`, wired to the existing `after_ms`.
  - Simulate it with virtual time (see G16).

### G04. The 5 s call limit is fixed (P0)

- **Needs:** batches of simulation iterations (tens of ms each) and optimizer steps (can take longer), inside `update`.
- **Today:**
  - `@default_timeout 5_000` and about 1 GB of heap (`lib/nobi/exec/worker.ex:24-25`).
  - Deployments pass `[]` options, so they always get the defaults (`lib/nobi_web/live/deployment_live.ex:485, 504, 611, 724`).
- **Workaround:** pick a batch size that stays well under 5 s. The optimizer is already resumable (`optimization_advance(state, budget)`), so this is fine.
- **Proposal:**
  - Keep the limit, but give WASM calls their own budget, using wasmtime fuel or epochs, so a long call isn't simply killed.
  - Or make `Wasm.call` a `Cmd` that runs outside `update` (see G01).

### G05. Apps run only while a browser is connected (P1)

- **Needs:** a simulation or optimization that keeps running when the tab is closed. Emberforge has this today: one Durable Object per run, driven by an alarm.
- **Today:**
  - One model per LiveView connection, gone on reload (`lib/nobi_web/live/deployment_live.ex:30-33`).
  - `PersistentElmGenServer` exists but is Elixir-only (`lib/nobi/persistent_elm_genserver.ex`).
  - Persisted or shared app state is listed as out of scope (`docs/superpowers/specs/2026-10-15-apps-liveview-design.md:22-27`).
- **Workaround:** save a checkpoint after each tick; the run pauses while the tab is closed and resumes when `/runs/:id` reopens. Acceptable for a local tool.
- **Proposal:**
  - Add headless app instances: a `defapp` with no view, hosted by a `PersistentElmGenServer` under a durable key and started with something like `Cmd.spawn(App, args)`.
  - Pages subscribe to them; the runtime already has `broadcast` and `subscribe`.
- **This is the biggest feature on the list.**

### G06. Typed JSON only; no float or dynamic values (P1)

- **Needs:**
  - Decode the catalog: 347 spell records and 360 items, with float coefficients.
  - Decode results, which have a `by_spell` map of float stats.
  - Pass simulator requests through without changing them.
- **Today:**
  - `(JSON.parse(s) : T)` returns `Result<T, String>`.
  - Only integer numbers that fit in i64 decode (`lib/nobi/lang/rt/json.ex:20`).
  - Variants other than records encode as `{"$variant": …}` (`json.ex:12-15`).
  - There is no dynamic value type.
- **Workaround:** keep requests and results as opaque `String`s and decode only presenter output.
- **Proposal:**
  - Decode floats once G02 exists.
  - Optionally add a `Json` value type for passing JSON through untouched.
  - Optionally add control over the external encoding (tagged unions as `{"kind": …}`) so Nobi types can match an existing JSON contract.

### G07. Events carry no payload; no on-input (P1)

- **Needs:**
  - Validating the rotation as you type.
  - Keyboard handling (Escape closes a popover, arrow keys in pickers).
  - Live search in the equipment and spell pickers.
- **Today:**
  - The only events are click, blur, focus, keydown, keyup, submit and change (`lib/nobi/lang/types/jsx_app.ex:19-27`).
  - Only `change` passes text. Key events send a fixed Msg with no key (`deployment_live.ex:385`).
- **Workaround:** validate on change or blur, and use buttons instead of key handling.
- **Proposal:**
  - Add `on-input` that takes a String constructor (debounced with G03, or with a built-in `phx-debounce`).
  - Make `on-keydown` pass the key (`Msg(String)`).

### G08. No hover or popover primitive (P2)

- **Needs:** spell and talent tooltips anchored to an icon. They open on hover or focus today.
- **Today:** no pointer events. `details` and `summary` are the only built-in disclosure elements (`lib/nobi_web/components/nobi_html.ex:70-73`).
- **Workaround:** open with focus or click, or use `<details>`. Without a `style` attribute we can't position anything, so the popover stays inline.
- **Proposal:**
  - Add a host-rendered `<popover anchor=…>`, or allow the native `popover` and `popovertarget` attributes.
  - CSS anchor positioning keeps it free of JS.

### G09. No `svg` and no `style` attribute (P2)

- **Needs:** WoW-style icons and frames, spell breakdown bars, and later DPS distribution charts.
- **Today:** a fixed tag and attribute allowlist without `svg`, `canvas` or `style` (`nobi_html.ex:70-79`). `img src` allows http(s) URLs only.
- **Workaround:** draw bars as Tailwind width classes (coarse steps), or as `<progress>`/`<meter>`, which are also not allowlisted yet.
- **Proposal:** allow a safe subset of SVG, plus `meter` and `progress`. Allow a restricted `style` (custom properties only, for example `--pct: 42`).

### G10. The store has no queries or expiry (P2)

- **Needs:**
  - List recent runs for a character.
  - Look up a run by id, already supported.
  - 24 h retention, which Emberforge has today.
- **Today:** insert, list, get, update, delete and tx; insertion order only; at most 10,000 rows per `list` (`lib/nobi/data.ex:74`). Queries are out of scope (`docs/superpowers/specs/2026-10-16-store-design.md:112-114`). There is no TTL.
- **Workaround:** filter in Nobi after `list`, and clean up through a sweep app (which needs G03 and G05).
- **Proposal:** filter on fields with an index, and expire rows (`expires_at`, or TTL per model).

### G11. No generic defs (P1)

- **Needs:**
  - Reusable helpers: a `Result` combinator, a list helper over any element type, a picker component over any item type.
  - These affect the UI more than anything else.
- **Today:** user `def`s can't take type parameters (`lib/nobi/lang/types/check.ex:288`).
- **Workaround:** write a monomorphic copy for each type.
- **Proposal:** parametric defs. `deftype` already parses type parameters (`lib/nobi/lang/parser.ex:551-560`).

### G12. No `Html.map` or generic `Html<a>` (P2)

- **Needs:**
  - Character, Talents, Simulator and Optimizer as separate components with their own Msg types.
  - Today's React splits into 11 components.
- **Today:** helpers must return `Html<App.Msg>`.
- **Workaround:** one large Msg type for the whole app.
- **Proposal:** `Html.map(f, html)`, which needs G11.

### G13. Language papercuts (P2)

- **Today:**
  - No modulo, because `%` is the struct sigil (`lib/nobi/lang/lexer.ex:255`).
  - A case arm's body is one expression.
  - No list patterns, and no destructuring in a binding (`lib/nobi_web/mcp/instructions.ex:174-183`).
  - `List.sort_by` sorts by an Int key only (`lib/nobi/lang/types/stdlib.ex:60`).
- **Proposal:** `Int.rem`/`mod`, sorting by any comparable key (or with a comparator), list patterns.
- **Log specific cases here as the UI port runs into them.**

### G14. No JSON or HTTP routes (P2)

- **Needs:** optional. A JSON API for scripts and other tools, which Emberforge's `/api/*` has today.
- **Today:** deployments serve only route-table apps, and the `/api` scope is commented out (`lib/nobi_web/router.ex:63-64`).
- **Workaround:** drop the public API.
- **Proposal:** a route type that maps to a pure `Request -> Response` def, or `defendpoint`.

### G15. Public serving waits on auth (P1)

- **Needs:** host Emberforge publicly. It's public on Cloudflare today, with a rate limit on creating runs.
- **Today:** production serving is dev/test-only until users and auth exist (`docs/superpowers/specs/2026-10-15-apps-liveview-design.md:18-28`).
- **Workaround:** local-only.
- **Proposal:** the auth work already planned, plus a per-deployment rate limit on effects.

### G16. Deterministic simulation testing is Elixir-only (P2)

- **Needs:**
  - Test the run lifecycle: cancel during a tick, resume after a restart, results never counted twice.
  - Emberforge's workerd tests cover this today with evictions and manual alarms.
- **Today:**
  - `Nobi.Elm.Sim` explores message orderings and virtual timers, but only for Elixir Elm modules (`lib/nobi/elm/sim.ex:1-38`).
  - In Nobi tests, effects are only data (`instructions.ex:284`).
- **Proposal:** run `Nobi.Elm.Sim` over `defapp`s, with `always` and `sometimes` checked across the explored schedules.

### G17. Effects in flight are lost on restart (P2)

- **Needs:** Emberforge's Durable Object writes results and the next step in one transaction, so a retry never counts an iteration twice.
- **Today:** effects aren't durable (`docs/superpowers/specs/2026-10-15-persistent-elm-genserver-design.md:11-13`).
- **Workaround:** idempotent ticks. The checkpoint holds `completed_iterations`, and `Cmd.store.tx` writes it atomically.
- **Proposal:** probably fine as is. Revisit after G05.

## Entries

Add a dated entry each time the port runs into something: what we tried, which gap it hit (or a new gap), and what we did.

- **2026-10-18:** initial survey. G01–G17 recorded from reading the source. Nothing has been built yet.
