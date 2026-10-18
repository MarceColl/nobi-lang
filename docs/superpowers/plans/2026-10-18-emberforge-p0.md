# Emberforge P0 gaps Implementation Plan

## Overview

Close the four P0 gaps in `docs/emberforge-gap-log.md` so the Emberforge spike can run: one simulation run, called from a Nobi app, that shows its DPS. The gaps are G01 (WASM calls), G02 (`Float`), G03 (a timer `Cmd`) and G04 (the fixed 5 s call limit).

- **Motivation**: the gap log marks G01-G04 as blocking the spike. Its default is to close gaps in Nobi rather than take the workaround.
- **Related**: `docs/emberforge-gap-log.md`, `docs/superpowers/specs/2026-10-16-store-design.md` (purity and hook conventions), `lib/nobi_web/mcp/instructions.ex` (agent guide, part of the language contract).
- **Base**: `main` at `dc8b886`.

Each gap ships as its own PR and its own implementation session. Phases 1-6 below are in the recommended order.

## Current State Analysis

### G01. No foreign or WASM calls

- Stdlib rows are `{name, def_.(params, ret)}` in an ordered list (`lib/nobi/lang/types/stdlib.ex:13-142`). Two tests pin the count at 72 (`test/nobi/lang/extract_test.exs:119-120`), and so does the moduledoc (`types/stdlib.ex:3-5`).
- The runtime table is built at compile time from every row. `Wasm.call` would map to `Nobi.Lang.Rt.Stdlib.wasm_call/3` (`lib/nobi/lang/rt/stdlib.ex:53-63`). Codegen resolves it through `stdlib!` (`lib/nobi/lang/codegen/expr.ex:501-504`).
- `Result` values are `{:var, "Result", "Ok" | "Err", [v]}` (`lib/nobi/lang/rt/json.ex:107-108`). `JSON.parse` is the closest row with this shape (`types/stdlib.ex:81`).
- Compiled code reaches outside `lib/nobi/lang` only through hard-coded remote calls to hook modules: `Nobi.Exec.Hooks` (`expr.ex:26-29`) and `Nobi.Data.Hooks` (`expr.ex:486-489`).
- The CAS stores only declaration text that must re-parse (`lib/nobi/cas.ex:17-32`). No table holds binary artifacts.
- Deployments pin a commit as a 1-based integer (`lib/nobi/deployment.ex:195-206`).
- The worker stops code with `Process.exit/2` only (`lib/nobi/exec/worker.ex:84-100, 139-153`). **An exit signal can't interrupt a running NIF, and the heap limit doesn't count native memory.** The 5 s deadline therefore can't bound a WASM call. Fuel or epochs inside wasmtime have to.
- No deps for wasmex, rustler or rustler_precompiled (`mix.exs:126-156`). Dist builds are static musl binaries for four targets (`mix.exs:110-117`). exqlite is "the only NIF", and Burrito recompiles it with `zig cc` for cross targets (`lib/mix/tasks/nobi.dist.ex:94-102`). A Rust NIF can't take that path.
- wasmex 0.15.1 (hex, 2026-08-07) ships precompiled NIFs for `x86_64`/`aarch64-unknown-linux-musl` and both Apple targets, among others.

### G02. No `Float` type

- Builtins: `@builtin_named ~w(Int String Bool Uuid Unit Store Href)` (`lib/nobi/lang/types/extract.ex:26`).
- **Lexer:** reads ASCII digits only (`lib/nobi/lang/lexer.ex:112-121, 153`). `1.5` lexes as int, dot, int, and the parse fails.
- **Checker:** `operand/1` fixes `Int` for `+ - * / < > <= >=` (`lib/nobi/lang/types/check.ex:492`). Arithmetic always returns `"Int"` (`check.ex:394-399`), and `:neg` is Int to Int (`check.ex:408`).
- **Runtime:** `Rt.add/sub/mul/div/neg` are checked i64 (`lib/nobi/lang/rt.ex:137-155`). `div(_, 0)` throws `"division by zero"`. Comparisons compile to raw Erlang operators (`expr.ex:299-302`).
- The BEAM has no NaN or infinity: a float overflow, or `:math.sqrt(-1.0)`, raises `badarith`. OTP 27+ treats `0.0 =:= -0.0` as false.
- **Int is hard-coded in about 25 places beyond `extract.ex`:**
  - JSON: `rt/json.ex:342-347, 556-592, 632-633`
  - Store: `lib/nobi/data/schema.ex:223, 556-557`, `lib/nobi/data/codec.ex:33, 101-116, 197-209`, `types/store.ex:83-84`, `types/evolution.ex:204-209`
  - Html: `types/jsx_app.ex:221-222`, `rt.ex:606`, `lib/nobi_web/components/nobi_html.ex:290`
  - Display: `lib/nobi/exec/show.ex:59`, `lib/nobi_web/live/console/cell.ex:14, 30`
  - Ordering: `rt.ex:288, 416-429, 621-627`
  - Patterns: `types/patterns.ex:93-94`, `types/exhaustive.ex:130-131`
  - Guide: `instructions.ex:180, 267, 395`

### G03. No timer `Cmd`

- `Fx.after_ms/2` builds `{:after_ms, ms, msg}` (`lib/nobi/elm/effect.ex:103`). The runtime sends it with `Process.send_after` (`lib/nobi/elm/runtime.ex:300-303`) and drops it during the static render (`runtime.ex:253`). `Nobi.Elm.Sim` already runs timers on virtual time (`lib/nobi/elm/sim.ex:368-370`).
- **`DeploymentLive` is itself an Elm module** (`use NobiWeb.ElmLiveView`, `lib/nobi_web/live/deployment_live.ex:129`). It lowers Nobi effects to `Fx` values (`deployment_live.ex:433-477`), so a Nobi timer can lower straight to `Fx.after_ms`.
- **Callback path:** `callback/2` emits `{:nobi_callback, gen, result}` (`deployment_live.ex:484-485`). `start/2` runs it only while `gen` matches (`deployment_live.ex:312-320`), so callbacks from a previous page are dropped.
- **Nobi side:** every `Cmd.*` row except `none`/`batch` gets a generated body that returns `{:cmd, {:effect, name, nil, args}}` (`rt/stdlib.ex:362-374`). `Effects.flatten/1` maps any name it doesn't know to `{:unavailable, name}` (`lib/nobi/deployment/effects.ex:56-76`).
- **MCP `send`:** runs effects synchronously in the caller and has no clock (`lib/nobi/deployment/runner.ex:255-346`).
- **Msg arguments:** a no-argument Msg constructor is a value, `{:var, owner, variant, []}` (`check.ex:281`). So `Cmd.after(ms, M.Msg.Tick)` takes a msg value, not a callback.

### G04. The 5 s call limit is fixed

- `Worker` options are `:timeout` (default 5_000), `:max_heap_size` (default 1 GiB in words) and `:max_result` (`lib/nobi/exec/worker.ex:24-26, 44-53`).
- **Callers:**
  - Every production caller passes `[]` or nothing: `deployment_live.ex:485, 504, 611, 724`, `runner.ex:204, 358, 374`, MCP `eval`/`test` (`lib/nobi_web/mcp/tools.ex:260, 269`), and the console (`lib/nobi_web/live/console/live.ex:307`).
  - Steps run off-process in `Fx.task` (`deployment_live.ex:283`), so a long `update` doesn't block the LiveView. Later steps queue behind it (`@queue_cap 32`, `deployment_live.ex:154`).
- No app env setting and no deployment column exist for limits (`priv/repo/migrations/20261015140000_create_deployments.exs`). The only other step budget is `Rt`'s `@budget 1_000_000` for equality and hashing (`rt.ex:98`).
- Tests pass small explicit limits, such as `timeout: 50` (`test/nobi/exec_test.exs:722-759`).

## Desired End State

- An Emberforge-shaped Nobi app can do all of the following, and an automated end-to-end test does the same against a WAT fixture:
  - `Wasm.call(hash, "simulate", req)` returns `Ok(json)`.
  - `JSON.parse` turns the result into a record with `Float` fields.
  - `update` re-arms itself with `Cmd.time.after(ms, Msg.Tick)`.
  - A deployment can raise its step limit above 5 s, within a ceiling.
- The agent guide (`instructions.ex`), formatter, checker and codegen agree on every new form.
- In `docs/emberforge-gap-log.md`, G01-G04 read `closed (<PR>)`.

## What We're NOT Doing

- **Out of scope:**
  - G05 headless apps
  - G06 dynamic `Json` values and custom tagged-union encodings
  - G16 simulating `defapp`s
  - G17 durable effects
- **Not in this plan:**
  - `Wasm.call` as a `Cmd`
  - WASI or any host imports for WASM modules
  - Fuel exposed in the language
- **No implicit Int/Float conversion.** `x * 2` with `x : Float` is a type error; write `2.0` or `Float.from_int(2)`.
- **No float literal patterns** in `case`.
- `List.sort_by` and `List.sum` stay Int-only. Sorting by a Float key belongs to G13.
- **Not in this plan:**
  - Cancelling a timer (`Cmd.time.cancel`)
  - Timers that survive a LiveView reconnect (that is G05)
- The store `tx` timeout (`lib/nobi/data/tx.ex:102`) stays as it is.

## Implementation Approach

| Order | Gap | Effort | Depends on | Why this order |
|---|---|---|---|---|
| 1 | G03 timer `Cmd` | S, about 0.5 day, about 150 lines with tests | none | Smallest change, and it unblocks the tick loop with no other gap |
| 2 | G04 limits | S, about 1 day | none | Small. It defines the step budget that G01's fuel budget must fit inside |
| 3-4 | G02 `Float` | L, 2-3 days, in two PRs | none | The widest change (about 25 touch points), but low risk |
| 5-6 | G01 WASM | L, 2-4 days, in two PRs | G04 (budget); G02 only for consuming results | Highest risk (a Rust NIF in static musl builds). Phase 5 is a go/no-go gate |

- **Two orders are safe.** G02 and G03 are independent. Phase 5's dist spike can start in parallel with phase 1 to surface the NIF risk early.
- **Overloaded operators for `Float`, not `+.`.** Agents write `a + b` for both types. The checker picks the type from the operands it has already inferred, both sides must match, and an operand it can't resolve defaults to `Int`, as it does today. `Rt` dispatches on `is_float` with guard clauses, so the `Int` path is unchanged.
- **`Wasm.call` is a pure call, not a `Cmd`.** The Emberforge exports are pure, JSON in and JSON out. Three rules keep it deterministic:
  - Modules with imports are refused when they are stored.
  - Every call gets a fresh instance.
  - Every call has a fuel and memory cap.

  A `Cmd` version would cost a round trip per batch and add a Msg type for every call. The gap log's open question is answered this way; reviewers can overturn it.
- **WASM modules are addressed by content.** Code names a module as `"sha256:<hex>"`. The bytes live in a new append-only `wasm_modules` table. A deployment pinned to a commit therefore always calls the same bytes, and the checker never reads outside state.
- **The timer is named `Cmd.time.after`, not the gap log's `Cmd.after`.** It sits next to `Cmd.time.now` and follows the namespaced effect rows (`Cmd.store.*`, `Cmd.random.*`). Renaming it is a one-line change if Marce prefers `Cmd.after`.
- **G04 limits come in two layers.** App env sets defaults and a ceiling. Each deployment can store its own `timeout_ms`, clamped to that ceiling.

### Decisions for review

1. Should `Wasm.call` be a pure call with fuel (recommended) or a `Cmd`?
2. Should the timer be `Cmd.time.after` (recommended) or `Cmd.after`?
3. Should `Float` overload the existing operators (recommended) or get separate ones?
4. Should `-0.0` be normalised to `0.0` on every float result (recommended)? Otherwise equality and map keys see two zeros on OTP 27+.
5. G04 is the weakest P0, because the gap log's own workaround (batches under 5 s, a resumable optimizer) works. If time is short, downgrade it to P1 and keep only phase 2's app env layer.

## Quick Verification Reference

- Full gate: `mix precommit` (compile with warnings as errors, `deps.unlock --unused`, format, test)
- Focused: `mix test test/nobi/lang test/nobi/exec test/nobi_web/deployment_live_test.exs test/nobi_web/mcp_send_test.exs`
- Site samples: `mix test test/site`
- Dist build, phase 5 only: `mix nobi.dist linux_x86_64` (needs Zig 0.16.0 and `xz`)

---

## Phase 1: G03 timer `Cmd` (`Cmd.time.after`)

### Overview

Deliverable: `Cmd.time.after(ms, msg) : Cmd<a>` type-checks. A deployment fires it through `Fx.after_ms`, and MCP `send` fires it on a virtual clock. A one-line tick-loop app increments a counter on its own in a deployment test.

### Changes Required:

#### 1. Signature and runtime value
**File**: `lib/nobi/lang/types/stdlib.ex`
**Changes**:
- Add `{"Cmd.time.after", def_.([int, a], cmd.(a))}` after `Cmd.time.now`.
- Update the "72 in all" moduledoc. The body comes from `rt/stdlib.ex:362-374` automatically.

**File**: `test/nobi/lang/extract_test.exs`
**Changes**: Change the count from 72 to 73.

#### 2. Host lowering
**File**: `lib/nobi/deployment/effects.ex`
**Changes**:
- `bare/1` maps `{:effect, "Cmd.time.after", _, [ms, msg]}` to `{:after, ms, msg}` when `ms` is in `0..86_400_000`.
- Anything outside that range becomes `{:error, "Cmd.time.after: ms must be 0..86400000"}`.
- Add a `describe/1` clause.

**File**: `lib/nobi_web/live/deployment_live.ex`
**Changes**:
- Add a `lower_effect(m, {:after, ms, msg}, _)` clause that returns `{m, Fx.after_ms(ms, {:nobi_callback, m.gen, {:ok, msg}})}`.
- It reuses the gen-gated callback path, so a timer from a previous page is skipped.
- The Elm runtime already drops it during the static render.
- Make timer callbacks non-droppable in `droppable?/1` (`:271`). A dropped tick would stall a job loop silently. Instead, tag the item `{:callback, gen, result, :timer}`, or keep timers out of the cap.

#### 3. MCP `send` on a virtual clock
**File**: `lib/nobi/deployment/runner.ex`
**Changes**:
- Keep a list of pending timers sorted by due time.
- When the effect queue is empty, fire the earliest timer: advance the virtual clock, then run `update`.
- Each firing counts toward `@max_steps`.
- Report it as `after 500ms => Msg.Tick (virtual)`.

#### 4. Guide
**File**: `lib/nobi_web/mcp/instructions.ex`
**Changes**:
- Add `Cmd.time.after` to the effects a deployment runs (`:284-299`) and to the signatures.
- Explain that `send` fires timers on virtual time within the 50-step limit.

#### 5. Tests
**Files**:
- `test/nobi/exec/stdlib_test.exs`: one effect-as-data case per `Cmd` row (`:173-179`).
- `test/nobi/lang/rt_test.exs`
- `test/nobi_web/deployment_live_test.exs`: a tick-loop app that counts to 3, with a 10 ms timer.
- `test/nobi_web/mcp_send_test.exs`: virtual firing, and the step cap ending an endless loop.
- A `Nobi.Deployment.Effects` unit test for the range check.

### Success Criteria:

#### Automated Verification:
- [ ] Stdlib row count and effect-as-data tests pass: `mix test test/nobi/lang/extract_test.exs test/nobi/exec/stdlib_test.exs test/nobi/lang/rt_test.exs`
- [ ] Deployment tick-loop test passes: `mix test test/nobi_web/deployment_live_test.exs`
- [ ] MCP virtual-timer tests pass: `mix test test/nobi_web/mcp_send_test.exs`
- [ ] Full gate passes: `mix precommit`

#### Automated QA:
- [ ] The agent stages and promotes a counter app whose `init` returns `Cmd.time.after(200, Msg.Tick)` and whose `update` re-arms it. Over the MCP `send` tool it sees `after 200ms => ...Tick (virtual)` entries, ending at the 50-step cap with a clear note.
- [ ] With `mix phx.server` running, the agent loads the app at `http://<name>.localhost:4000/` (curl or a browser tool) and sees the counter rise over 1 s.

#### Manual Verification:
- [ ] Marce accepts `Cmd.time.after` or asks for `Cmd.after` (decision 2).

**Implementation Note**: After this phase, pause for review. Mark G03 `closed (<PR URL>)` in `docs/emberforge-gap-log.md` in the same PR.

---

## Phase 2: G04 configurable step limits

### Overview

Deliverable:
- `config :nobi, Nobi.Exec` sets default `timeout`/`max_heap_size` and a `max_timeout` ceiling.
- A deployment can carry `timeout_ms`, set through `Deployment.create/4` and the MCP `create_deployment` tool.
- `DeploymentLive` and `Runner` pass it to every step and callback.

### Changes Required:

#### 1. Defaults from app env
**File**: `lib/nobi/exec/worker.ex`
**Changes**:
- Read defaults with `Application.get_env(:nobi, Nobi.Exec, [])` at call time, keeping today's values as the fallback.
- Clamp `:timeout` to `max_timeout` (default 60_000).

**File**: `config/config.exs`
**Changes**: Document the keys with today's values: `timeout: 5_000`, `max_timeout: 60_000`.

#### 2. Per-deployment limit
**File**: `priv/repo/migrations/20261019120000_add_timeout_to_deployments.exs` (new)
**Changes**: `alter table(:deployments), add :timeout_ms, :integer, null: true`. Rows that already exist keep `NULL`, which means the default.

**File**: `lib/nobi/deployment.ex`
**Changes**:
- Add `timeout_ms` to the type, `create/4` options, reads and `list`.
- Add `set_timeout/2`.
- Validate a positive integer no larger than `max_timeout`. Otherwise return `{:error, :bad_timeout}`.

**File**: `lib/nobi_web/mcp/tools.ex`
**Changes**:
- Add an optional `timeout_ms` property to `create_deployment` (`:92-112`).
- Show it in `list_deployments`.

#### 3. Pass-through
**File**: `lib/nobi_web/live/deployment_live.ex`
**Changes**:
- Build `exec_opts(m)` from `m.deployment` (it is `[]` when `nil`).
- Pass it at `:485, :504, :611, :724` instead of `[]`.

**File**: `lib/nobi/deployment/runner.ex`
**Changes**: The same at `:204, :358, :374`.

#### 4. Guide
**File**: `lib/nobi_web/mcp/instructions.ex`
**Changes**: One line on `timeout_ms` and the ceiling, near the `send` limits.

#### 5. Tests
**Files**:
- `test/nobi/exec_test.exs`: the app env default applies, and the ceiling clamps. Use `Application.put_env` in a non-async test and restore it afterwards.
- `test/nobi/deployment_test.exs`: the create and validate round trip.
- `test/nobi_web/deployment_live_test.exs`: a deployment with `timeout_ms: 100` reports `"timeout"` on a looping `update`. A test of the default keeps its existing behaviour.

### Success Criteria:

#### Automated Verification:
- [ ] Migration runs on a fresh test DB: `MIX_ENV=test mix ecto.reset`
- [ ] Worker and deployment tests pass: `mix test test/nobi/exec_test.exs test/nobi/deployment_test.exs`
- [ ] LiveView timeout test passes: `mix test test/nobi_web/deployment_live_test.exs`
- [ ] Full gate passes: `mix precommit`

#### Automated QA:
- [ ] Through MCP, the agent creates a deployment with `timeout_ms: 20000`, then calls `list_deployments` and sees the value.
- [ ] With `timeout_ms: 999999`, the agent gets an error that names the ceiling.

#### Manual Verification:
- [ ] Marce confirms G04 stays P0 (decision 5).

**Implementation Note**: After this phase, pause for review. Mark G04 closed in the gap log. Phase 5 sets WASM fuel against the step deadline from this phase.

---

## Phase 3: G02 `Float` core (literal, type, operators)

### Overview

Deliverable:
- `Float` is a builtin type.
- `1.5`, `2.0e-3` and `-0.25` lex, parse, format canonically and type-check.
- `+ - * / < > <= >= == != neg` work on `Float`.
- Overflow and division by zero are runtime errors, and `-0.0` normalises to `0.0`.

### Changes Required:

#### 1. Type and literal
**Files**: `lib/nobi/lang/types/extract.ex`, `lib/nobi/lang/lexer.ex`, `lib/nobi/lang/parser.ex`, `lib/nobi/lang/ast.ex`, `lib/nobi/lang/format.ex`
**Changes**:
- Add `Float` to `@builtin_named`.
- **Lexer:**
  - After the integer digits, a `.` followed by a digit continues a float.
  - An optional `e[+-]?digits` follows.
  - The result is `{:float, f}`, and an out-of-range literal is a lex error.
  - `x.field` and `1.` followed by a name stay as they are today.
- **Parser:** `primary` builds `{:float, m, [f]}`. Float literal patterns are refused with a clear error.
- **Formatter:** prints `:erlang.float_to_binary(f, [:short])`, always with a `.`. The text has to be canonical, because a CID hashes the formatted text (`lib/nobi/lang/cid.ex:24-26`). Round-trip tests guard this.

#### 2. Checker
**Files**: `lib/nobi/lang/types/check.ex`, `lib/nobi/lang/types/hints.ex`
**Changes**:
- Type `{:float, _, _}` as `named("Float")` (`:328-330`).
- **Arithmetic and comparison ops:**
  - Synthesize both sides.
  - If either side resolves to `Float`, unify both with `Float`; otherwise unify with `Int`, as today.
  - Arithmetic yields the operand type (`:387-399`).
  - `:neg` follows its operand (`:408`).
- **Hint:** "Int and Float don't mix; write 2.0 or Float.from_int(x)" for an Int/Float unify failure on an operator.

#### 3. Runtime and codegen
**Files**: `lib/nobi/lang/rt.ex`, `lib/nobi/lang/codegen/expr.ex`
**Changes**:
- Codegen emits float literals as plain Erlang floats.
- **Arithmetic:**
  - `Rt.add/sub/mul/div/neg` gain `is_float` clauses.
  - A float `div` by `0.0` throws `"division by zero"`.
  - `ArithmeticError` becomes `{:nobi_error, "float overflow"}`.
  - Results pass through `fnorm/1`, which maps `-0.0` to `0.0`.
- **Ordering:** `kind/1`, `kind_name` and `sorted_entries` handle floats (`rt.ex:288, 416-429, 621-627`). The constant table (`rt.ex:113-114`) does too.

#### 4. Guide
**File**: `lib/nobi_web/mcp/instructions.ex`
**Changes**:
- Add `Float` to the type list (`:395`).
- Add the literal syntax, the no-mixing rule, and errors on overflow and division by zero.

#### 5. Tests
**Files**:
- `test/nobi/lang/lexer_test.exs`, `parser_test.exs` and `format_test.exs`: round trips including `1.0`, `1.0e-7` and `1e300` overflow, plus `x.1` not becoming a float.
- `check_test.exs`: mixing is refused, and an unresolved operand defaults to Int.
- `codegen_test.exs` and `rt_test.exs`: overflow, division by zero, and `-0.0 == 0.0`.
- `test/fixtures/nobi/ill_typed.json`: two to three Float mixing cases, with the count bumped in `test/nobi/lang/oracle_fixtures_test.exs:4-9`.
- `test/support/universe_cases.ex:14`: a `{"Float", "1.5", :+}` triple.

### Success Criteria:

#### Automated Verification:
- [ ] Lexer, parser and formatter tests pass: `mix test test/nobi/lang/lexer_test.exs test/nobi/lang/parser_test.exs test/nobi/lang/format_test.exs`
- [ ] Checker and fixture tests pass: `mix test test/nobi/lang/check_test.exs test/nobi/lang/oracle_fixtures_test.exs test/nobi/lang/hints_test.exs`
- [ ] Runtime tests pass: `mix test test/nobi/lang/rt_test.exs test/nobi/lang/codegen_test.exs`
- [ ] Golden corpora are unchanged: `mix test test/nobi/nobi_golden_test.exs`
- [ ] Full gate passes: `mix precommit`

#### Automated QA:
- [ ] Through MCP `eval`, `1.5 + 2.25` gives `3.75`, and `1.0e308 * 10.0` gives a runtime error naming float overflow.
- [ ] `1 + 1.5` is refused with the mixing hint.
- [ ] A def using a Float stages and promotes. Re-reading it with `read` shows the canonical text, and its CID is stable across a format round trip.

#### Manual Verification:
- [ ] Marce accepts overloaded operators (decision 3) and `-0.0` normalisation (decision 4).

**Implementation Note**: After this phase, pause for review. G02 is still open until phase 4 lands.

---

## Phase 4: G02 `Float` at the edges (stdlib, JSON, store, Html, display)

### Overview

Deliverable:
- The stdlib has `Float.from_int`, `round`, `floor`, `ceil`, `sqrt`, `abs` and `to_string(Float, Int)`.
- JSON numbers decode into `Float` and floats encode back.
- Stored models can have `Float` fields (a `REAL` column).
- `{x : Float}` renders in Html, and the console shows floats.

### Changes Required:

#### 1. Stdlib
**Files**: `lib/nobi/lang/types/stdlib.ex`, `lib/nobi/lang/rt/stdlib.ex`, `test/fixtures/nobi/eval/stdlib.json`
**Changes**:
- **New rows:**
  - `Float.from_int : (Int) -> Float`
  - `Float.round`, `Float.floor`, `Float.ceil : (Float) -> Int`: a result outside i64 is `"integer overflow"`
  - `Float.sqrt : (Float) -> Float`: a negative input is a runtime error
  - `Float.abs : (Float) -> Float`
  - `Float.to_string : (Float, Int) -> String`: fixed decimals 0..15, through `:erlang.float_to_binary(f, decimals: p)`
- Each row gets examples in `stdlib.json`.
- Bump the row count in the moduledoc and `extract_test.exs`. `Float` becomes a reserved root through `check/decl.ex:186-193`.

#### 2. JSON
**File**: `lib/nobi/lang/rt/json.ex`
**Changes**:
- **Decode** (`coerce`, `:342-347`): `Float` accepts any JSON number, including `3` and `1e3`, and anything out of range is an error. `Int` stays strict.
- **Encode** (`write`, `:632-633`): floats use the shortest round-trip form.
- Update the moduledoc (`:20`).

#### 3. Store
**Files**: `lib/nobi/data/schema.ex`, `lib/nobi/data/codec.ex`, `lib/nobi/lang/types/store.ex`, `lib/nobi/lang/types/evolution.ex`
**Changes**:
- `Float` joins the scalars (`schema.ex:223`, `codec.ex:33`) and maps to `REAL` (`schema.ex:556-557`).
- Encode and decode in `codec.ex:101-116, 197-209`. SQLite may hand back an integer for a whole `REAL`, so decode accepts it.
- Float defaults are constants (`store.ex:83-84`), and evolution suggests `0.0` (`evolution.ex:204-209`).

#### 4. Html and display
**Files**: `lib/nobi/lang/types/jsx_app.ex`, `lib/nobi/lang/rt.ex`, `lib/nobi_web/components/nobi_html.ex`, `lib/nobi/exec/show.ex`, `lib/nobi_web/live/console/cell.ex`
**Changes**:
- A `{x}` child may be `Float` (`jsx_app.ex:221-222`) and renders in the shortest form (`rt.ex:606`, `nobi_html.ex:290`).
- `show.ex:59` and `cell.ex:14, 30` handle floats.

#### 5. Guide
**File**: `lib/nobi_web/mcp/instructions.ex`
**Changes**:
- Add `Float` to the model field types (`:267`).
- List the `Float.*` signatures.
- Note that `List.sum`/`sort_by` stay Int-only (G13).

#### 6. Tests
**Files**:
- `test/nobi/exec/stdlib_test.exs`, which runs the new `stdlib.json` examples
- `test/nobi/lang/rt_json_test.exs`: `1.5` decodes as Float and is still refused for Int, `3` decodes as `3.0`, and encode round-trips
- `test/nobi/lang/store_lang_test.exs`
- `test/nobi/universe_store_evolution_test.exs`: adding a Float field with a default
- `test/nobi/exec/show_test.exs`
- `test/nobi_web/nobi_html_test.exs`

### Success Criteria:

#### Automated Verification:
- [ ] Stdlib examples pass: `mix test test/nobi/exec/stdlib_test.exs test/nobi/lang/extract_test.exs`
- [ ] JSON tests pass: `mix test test/nobi/lang/rt_json_test.exs`
- [ ] Store tests pass: `mix test test/nobi/lang/store_lang_test.exs test/nobi/universe_store_evolution_test.exs test/nobi/data`
- [ ] Display tests pass: `mix test test/nobi/exec/show_test.exs test/nobi_web/nobi_html_test.exs`
- [ ] Site samples still pass: `mix test test/site`
- [ ] Full gate passes: `mix precommit`

#### Automated QA:
- [ ] Through MCP, the agent promotes a stored model `Run { id : Uuid, dps : Float = 0.0 }` and an app that does three things: decodes `{"dps": 1234.567}` with `JSON.parse`, stores it, and renders `Float.to_string(r.dps, 1)`. `send` shows the insert. The page shows `1234.6`.

#### Manual Verification:
- [ ] None.

**Implementation Note**: After this phase, pause for review. Mark G02 closed in the gap log.

---

## Phase 5: G01 WASM runtime (go/no-go gate)

### Overview

Deliverable:
- `Nobi.Wasm`, outside `lib/nobi/lang`, does three things:
  - stores modules by sha256 in a new `wasm_modules` table, refusing modules with imports
  - caches compiled modules
  - runs `call(hash, export, input_string)` on a fresh instance with fuel and memory caps
- The ABI is `alloc(len) -> ptr`, then `fn(ptr, len) -> i64`, which packs `ptr << 32 | len`, then `free(ptr, len)`.
- **Gate:** `mix nobi.dist linux_x86_64` and the host target build, and the binary runs a call. If they don't, stop and pick a fallback before phase 6.

### Changes Required:

#### 1. Dependency
**File**: `mix.exs`, `mix.lock`
**Changes**: Add `{:wasmex, "~> 0.15"}`, which uses rustler_precompiled, so CI needs no Rust toolchain.

#### 2. Storage
**File**: `priv/repo/migrations/20261019130000_create_wasm_modules.exs` (new)
**Changes**: `wasm_modules(hash TEXT PRIMARY KEY, bytes BLOB NOT NULL, exports TEXT NOT NULL, inserted_at)`. It is append-only, like `declarations`.

#### 3. Runtime
**Files**: `lib/nobi/wasm.ex`, `lib/nobi/wasm/cache.ex` (new)
**Changes**:
- **`put(bytes)`:**
  - Compiles the module to validate it.
  - Refuses any import and requires `memory`, `alloc` and `free` exports.
  - Inserts with `on_conflict: :nothing` and returns `"sha256:<hex>"`.
  - Caps size at 32 MB.
- **`Cache`** keeps one shared `Wasmex.Engine` (with `consume_fuel`) and the compiled `Wasmex.Module`s in ETS, keyed by hash and filled lazily from the table.
- **`call(hash, export, input)`:**
  - Builds a new store with `StoreLimits` (memory 256 MB) and fuel from config, then instantiates.
  - Writes the input with `alloc`, calls, reads the output (which must be UTF-8), and frees it.
  - Returns `{:ok, string}` or `{:error, reason}`. The reasons are `unknown module`, `no export`, `trap: …`, `out of fuel`, `out of memory` and `output is not UTF-8`.
- **Fuel default:** calibrate fuel per second on the dev box and set the default so a call ends well inside the step deadline from phase 2. This matters because killing the worker doesn't stop the native thread.
- **API check:** check exact wasmex 0.15 call names (`EngineConfig.consume_fuel/2`, `StoreOrCaller.set_fuel/2`, `Instance.call_exported_function/5`) against hexdocs before coding.

#### 4. Test fixture
**File**: `test/fixtures/wasm/echo.wat` (new)
**Changes**:
- Hand-written WAT exporting `memory`, `alloc` and `free`, plus five functions:
  - `echo`
  - `upper`
  - `spin`, an infinite loop
  - `trap`, `unreachable`
  - `grow`, which grows memory past the cap
- A second fixture imports a function, so `put` can be shown to refuse imports.
- Compile at test time with `Wasmex.Wat.to_wasm/1`, so the repo has no Rust or binary fixture.

#### 5. Tests
**File**: `test/nobi/wasm_test.exs` (new, not async, because it writes to the DB)
**Changes**:
- `put` is idempotent and refuses imports.
- `echo` round-trips multi-byte UTF-8.
- `spin` ends as `out of fuel` within 2 s.
- `grow` ends as `out of memory`, and `trap` ends as `trap`.
- The cache survives a cold start.

### Success Criteria:

#### Automated Verification:
- [ ] Deps resolve without Rust: `mix deps.get && mix compile --warning-as-errors`
- [ ] Runtime tests pass: `mix test test/nobi/wasm_test.exs`
- [ ] Full gate passes: `mix precommit`
- [ ] Dist build for a cross target succeeds: `mix nobi.dist linux_x86_64`

#### Automated QA:
- [ ] On a Linux box, the agent runs `dist/nobi-linux-x86_64 start`. From `bin/nobi remote` or an eval hook it calls `Nobi.Wasm.put` on the `echo.wat` bytes, then `Nobi.Wasm.call`, and gets the echo back.
- [ ] The agent records the measured fuel per second in the PR body.

#### Manual Verification:
- [ ] Marce runs the `macos_arm64` dist binary (the host target, which needs a Mac) and runs the same echo call.
- [ ] **Go/no-go.** If the musl or Burrito build can't carry the wasmex NIF, choose a fallback before phase 6: (a) ship WASM in source and dev builds only, with `Wasm.call` returning `Err("wasm is unavailable in this build")`, or (b) patch `nobi.dist` to place the musl rustler_precompiled artifact per target.

**Implementation Note**: Pause after this phase for the go/no-go decision. Phase 6 must not start until it is made.

---

## Phase 6: G01 `Wasm.call` in the language, plus module upload

### Overview

Deliverable:
- `Wasm.call(module : String, fn : String, input : String) : Result<String, String>` type-checks, compiles and runs inside the worker.
- MCP `put_wasm` stores a module and returns its hash.
- An end-to-end test has a Nobi app call the WAT fixture and decode its JSON into a `Float` record.

### Changes Required:

#### 1. Signature and implementation
**Files**: `lib/nobi/lang/types/stdlib.ex`, `lib/nobi/lang/rt/stdlib.ex`, `test/nobi/lang/extract_test.exs`
**Changes**:
- Add the row `{"Wasm.call", def_.([str, str, str], ap.("Result", [str, str]))}`.
- `wasm_call/3` is one line, delegating to `Nobi.Wasm.Hooks.call/3`. This follows the `Nobi.Data.Hooks` precedent, so `lib/nobi/lang` names the hook and never wasmex. The hook turns `{:ok, s}` and `{:error, why}` into `Result` variants.
- Bump the row count.

#### 2. Hook
**File**: `lib/nobi/wasm/hooks.ex` (new)
**Changes**:
- Call `Nobi.Wasm.call/3` with fuel from config.
- A malformed hash, meaning not `sha256:` plus 64 hex characters, is `Err`, not a crash.

#### 3. Upload
**File**: `lib/nobi_web/mcp/tools.ex`
**Changes**:
- Add a `put_wasm` tool with `bytes_base64` (required), modelled on `stage_patch` (`:48-64, 195-206`).
- It returns `sha256:<hex>` plus the export list, and it is in `@no_universe`, because modules are global and content-addressed.

**File**: `lib/mix/tasks/nobi.wasm.put.ex` (new)
**Changes**: `mix nobi.wasm.put path/to/sim.wasm` prints the hash. It suits large modules and local work.

#### 4. Guide
**File**: `lib/nobi_web/mcp/instructions.ex`
**Changes**:
- Add the `Wasm.call` signature, the ABI (`alloc`/`free`, packed `i64` return, no imports), and the error strings.
- Explain that the module is named by hash, so a pinned commit always calls the same bytes.

#### 5. Tests
**Files**:
- `test/nobi/exec/stdlib_test.exs`: a `Wasm.call` against a module stored in setup
- `test/nobi/lang/codegen_test.exs`
- `test/nobi_web/mcp_test.exs`: `put_wasm` round trip, bad base64, and imports refused
- `test/nobi_web/mcp_send_test.exs`: the end-to-end test. The app's `update` calls `Wasm.call(h, "echo", "{\"dps\": 1234.5}")`, `JSON.parse`s the result into `{ dps : Float }`, and re-arms with `Cmd.time.after`.
- A test that a `spin` call inside `update` returns `Err("out of fuel")` and the deployment stays usable.

### Success Criteria:

#### Automated Verification:
- [ ] Stdlib and codegen tests pass: `mix test test/nobi/exec/stdlib_test.exs test/nobi/lang/extract_test.exs test/nobi/lang/codegen_test.exs`
- [ ] MCP tests pass: `mix test test/nobi_web/mcp_test.exs test/nobi_web/mcp_send_test.exs`
- [ ] Full gate passes: `mix precommit`

#### Automated QA:
- [ ] The agent uploads `echo.wat`, compiled with `put_wasm`, and promotes an app that calls it. It drives the app with `send` and sees `Ok` with a decoded `Float`, then sees `Err("out of fuel")` for `spin`, with the next `send` still working.

#### Manual Verification:
- [ ] On the Emberforge side, the simulator is rebuilt with the C ABI (`alloc`/`free`/pointer and length; see the gap log). The real `simulate` export runs through `Wasm.call`, the app shows a DPS number, and the gap log gets a dated entry.

**Implementation Note**: After this phase, mark G01 closed in the gap log. The spike's definition of done ("one sim run that shows its DPS") is met.

---

## Appendix

- **Follow-up plans**:
  - G06 (dynamic `Json` passthrough) becomes cheap after phase 4.
  - G16 can add virtual-time timer exploration on top of phase 1.
  - G05 decides whether timers move into a `PersistentElmGenServer`.
- **Risks**:
  1. **The Rust NIF in static musl Burrito builds** is the reason phase 5 is a gate.
  2. **The fuel-to-time ratio varies by host.** Fuel bounds CPU work, not wall time, so the default needs headroom.
  3. **An unresolved operand defaults to Int**, so code such as a lambda with an unannotated param used with floats gets an Int error. The hint covers it, and G11 changes the picture.
  4. **WASM float NaN bit patterns are nondeterministic in principle.** They don't matter here because only strings cross the boundary.
- **Derail notes**:
  - `lib/nobi/deployment/effects.ex:4-5` already mentions "a timer" as a lowering target, before one exists. Phase 1 makes that true.
  - `PersistentElmGenServer` documents that pending `after_ms` timers die on restart (`lib/nobi/persistent_elm_genserver.ex:93-95`). That is relevant to G05, not here.
- **References**:
  - Gap log: `docs/emberforge-gap-log.md`
  - wasmex 0.15.1: https://hexdocs.pm/wasmex
  - Prior research task: G02-G04 were spot-checked against `main` at `dc8b886`.
