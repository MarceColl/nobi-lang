# Nobi Erlang Codegen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Committed Nobi code runs on the BEAM. Each image compiles to one Erlang module, and you can call defs, evaluate expressions, run deftests and step apps from iex. Behaviour matches the Rust/TS evaluator goldens.

**Architecture:**
- `Nobi.Lang.Rt` is pure runtime support: values, the stdlib, JSON, checked arithmetic, and equality and ordering.
- `Nobi.Lang.Codegen` is pure: it turns typed trees into Erlang abstract forms, and `:compile.forms` turns those into a binary. `Nobi.Lang.image/1` exposes it.
- `Nobi.Exec` is outside the pure tree. It loads and caches modules by image hash, runs calls and `:erl_eval` expressions in a bounded, monitored process, and renders values back as Nobi syntax.

**Tech Stack:** Elixir 1.19 / OTP 28, `:compile`, `:erl_eval`, `:persistent_term`, ExUnit. No new deps.

**Spec:** `docs/superpowers/specs/2026-10-15-nobi-erlang-codegen-design.md`

**Reference:** `~/proj/kinoko-next/crates/yabu/src/interp/{value,eval,stdlib,json,program}.rs`, plus the tests `tests/interp_eval.rs`, `tests/interp_stdlib.rs`, `tests/golden.rs:556-830` and `tests/oracle/{decode,mod}.rs`. Port the semantics. Do not port Rust's budget, stack or memory mechanics: the BEAM bounds runs with a timeout and `max_heap_size` instead.

## Global Constraints

- Purity holds for everything under `lib/nobi/lang/`: no processes, IO, Repo, process dictionary, `:persistent_term` or code loading. `:compile.forms` is allowed because it is a pure computation. Code loading, caching and spawning live only in `Nobi.Exec` (`lib/nobi/exec.ex` and `lib/nobi/exec/`).
- No atom is created from user text. Function atoms are positional (`:d0`, `:d1`, …), and variables are positional (`:V0`, …). The only per-image atom is the module name: `:"nobi_img_" <> first 20 hex chars of the image hash`.
- Image hash: `sha256` over the sorted committed lines `name <> "\0" <> cid <> "\n"`, as lowercase hex.
- The value representation is exactly the table in the spec: `{:uuid, b}`, `{:rec, model, %{field => v}}`, `{:var, owner, variant, [args]}`, `{:cmd, :none | {:batch, [cmd]} | {:effect, name, model | nil, [args]}}`, and plain integers, binaries, booleans, lists, maps, tuples and funs.
- Runtime errors are `throw({:nobi_error, message})`, with messages worded as Rust `EvalError` words them. `Exec` turns them into `{:error, %{code: "runtime", message: m}}`. Exec's other codes are `"timeout"`, `"heap"` and `"compile"`, plus checker codes for `eval`.
- Exec defaults are a 5_000 ms timeout and `max_heap_size` of 1 GB (in words, `div(1_073_741_824, :erlang.system_info(:wordsize))`), both overridable through `opts`.
- `mix precommit` must be green after every task. Wall-clock tests carry `@tag :perf`, which is excluded by default.
- VCS is jj. End each task with `jj commit -m "<msg>"`.
- Existing API to build on: `Nobi.Lang.committed/1` (name → `%{cid, decl, typed, deps, signature}`), `Nobi.Lang.signatures/1`, `Nobi.Lang.parse/1`, `Nobi.Lang.stage/4`, `Nobi.Lang.Types.Check.expr/2` and `Nobi.Lang.Format`. Typed nodes carry `meta[:type]` and `meta[:res]`. Committed trees carry no positions.

## Review Focus

1. **Infinite recursion or a huge list in a call.** Expected: `{:error, %{code: "timeout" | "heap"}}` within the bound, the caller unharmed, and no orphan process left. *Task 4.*
2. **Two universes with identical committed code.** Expected: the same module; the module is not reloaded. A promotion yields a new module, and the old one still answers. *Task 4.*
3. **Int overflow at the i64 boundary** (`9223372036854775807 + 1`, `-9223372036854775808 * -1`). Expected: a runtime error, as in Rust, never a silently promoted bignum. *Task 2.*
4. **Map iteration order** (`JSON.stringify` of a map with 40 keys). Expected: keys in Nobi order, deterministic, and equal to Rust's output. *Task 2.*
5. **`eval` of an expression that fails to typecheck, or one referencing an uncommitted name.** Expected: a checker-coded error with no exec at all. *Task 4.*

---

## File Structure

```
lib/nobi/lang/rt.ex              values: eq/compare, checked arith, constructors, show-agnostic helpers
lib/nobi/lang/rt/stdlib.ex       List/String/Option bodies         (interp/stdlib.rs)
lib/nobi/lang/rt/json.ex         type-directed parse, stringify     (interp/json.rs)
lib/nobi/lang/codegen.ex         image → forms; names table; image hash
lib/nobi/lang/codegen/expr.ex    typed expr → erl forms (patterns, case, fn, jsx, blocks)
lib/nobi/lang.ex                 + image/1, + check_expr/2 (typed expr against committed)
lib/nobi/exec.ex                 load/call/eval/test/show/unload
lib/nobi/exec/show.ex            value → Nobi source text
test/fixtures/nobi/eval/*.json     calls/traces/tests goldens + stdlib.json
test/support/nobi_golden.ex        loader + TS-JSON → BEAM value decoder (decode.rs)
test/nobi/lang/rt_test.exs, codegen_test.exs, test/nobi/exec_test.exs, test/nobi/exec_golden_test.exs
```

---

### Task 1: Eval goldens and decoder

**Files:**
- Create: `test/fixtures/nobi/eval/{corpus,generated}.json`, `test/fixtures/nobi/eval/stdlib.json`
- Create: `test/support/nobi_golden.ex`
- Test: `test/nobi/nobi_golden_test.exs`

**Interfaces:**
- Produces:
  - `NobiGolden.corpus() :: [%{"file", "calls", "traces", "tests"}]`
  - `NobiGolden.generated() :: [%{"seed", "source", "calls", "traces"}]`
  - `NobiGolden.stdlib() :: [%{"name", "examples"}]`
  - `NobiGolden.decode(json, type, sigs) :: {:ok, term} | {:error, why}`, which decodes TS's shape into the spec's BEAM representation
  - `NobiGolden.lambda()`, the closure marker
  - `NobiGolden.without_closures(term)`

- [ ] **Step 1:** Extract the `calls`, `traces` and `tests` keys from `~/proj/kinoko-next/crates/yabu/tests/oracle/{corpus,generated}.json`, keyed by `file` or `seed`, plus `generated[i].source`. Apply the same typed-Html migration piece 1 used (`with_typed_html`, `oracle/mod.rs:210`) to every source. Write them to `test/fixtures/nobi/eval/`, and copy `stdlib.json`. Use a python3 one-off and keep `ensure_ascii=False`.
- [ ] **Step 2:** Read `tests/oracle/decode.rs` and `oracle/mod.rs`, and port the decoder to the BEAM representation. Port `the_decoder_reads_a_value_by_its_declared_type` (`golden.rs:830`) as a test, along with a fixture-count test.
- [ ] **Step 3:** Run, see it fail, implement, see it pass. Run `mix precommit`, then `jj commit -m "test: eval goldens and value decoder"`.

### Task 2: Runtime support (`Nobi.Lang.Rt`)

**Files:** `lib/nobi/lang/rt.ex`, `lib/nobi/lang/rt/stdlib.ex`, `lib/nobi/lang/rt/json.ex`; tests `test/nobi/lang/rt_test.exs`, `test/nobi/lang/rt_json_test.exs`

**Interfaces:**
- Produces:
  - `Rt.add/sub/mul/div(a, b)`: checked i64 arithmetic; division by zero and overflow throw `{:nobi_error, msg}`
  - `Rt.eq/2`, `Rt.compare/2` (`:lt | :eq | :gt`, Rust `Value` Ord), `Rt.concat/2`
  - `Rt.record/2`, `Rt.variant/3`
  - `Rt.cmd_none/0`, `Rt.cmd_batch/1`, `Rt.cmd_effect/3`
  - `Rt.html_element/3`, `Rt.html_text/1`
  - `Rt.always!/1`
  - One public function per stdlib def, named by its snake-cased Nobi name: `Rt.Stdlib.list_map/2`, `string_split/2`, …
  - `Rt.Json.parse(text, type, models) :: {:var, "Result", "Ok"|"Err", [..]}` and `Rt.Json.stringify(v, type, models)`. Here `models` is `%{model => [{field, type}]}` from the image.

- [ ] **Step 1:** Read `interp/value.rs` (Ord, equality, Html, Cmd), `interp/stdlib.rs` and `interp/json.rs`.
- [ ] **Step 2: Failing tests.**
  - Port the semantic tests from `tests/interp_stdlib.rs` at the `Rt` level, calling `Rt.Stdlib.*` with BEAM values. Tests that need the evaluator wait for Task 4: list their names in the task report.
  - Port the JSON tests.
  - Add the Review Focus tests:

```elixir
test "i64 overflow is a runtime error" do
  assert catch_throw(Rt.add(9_223_372_036_854_775_807, 1)) == {:nobi_error, "Int overflow"} # use Rust's exact wording
  assert {:nobi_error, _} = catch_throw(Rt.mul(-9_223_372_036_854_775_808, -1))
end

test "map stringify follows Nobi key order for large maps" do
  m = Map.new(1..40, &{&1, &1})
  ty = {:applied, "Map", [{:named, "Int"}, {:named, "Int"}]}
  assert Rt.Json.stringify(m, ty, %{}) == Rt.Json.stringify(Map.new(Enum.shuffle(1..40), &{&1, &1}), ty, %{})
  assert Rt.Json.stringify(m, ty, %{}) =~ ~r/^\{"1":1,"2":2/ # whatever Rust writes; copy its exact format
end
```

- [ ] **Step 3:** Implement, see it pass, `mix precommit`, then `jj commit -m "feat(lang): runtime support"`.

### Task 3: Codegen

**Files:** `lib/nobi/lang/codegen.ex`, `lib/nobi/lang/codegen/expr.ex`, modify `lib/nobi/lang.ex`; test `test/nobi/lang/codegen_test.exs`

**Interfaces:**
- Consumes: `Nobi.Lang.committed/1` and `Rt`.
- Produces:

```elixir
Nobi.Lang.image(u) :: {:ok, %{module: atom, binary: binary, hash: String.t(), names: %{name => {atom, arity}}}} | {:error, %{code: "compile", message}}
Nobi.Lang.Codegen.image_hash(committed) :: String.t()
Nobi.Lang.Codegen.expr_forms(typed_expr, names, module) :: [erl_expr]   # for :erl_eval; calls image defs as remote calls module:dN(...)
Nobi.Lang.check_expr(u, source) :: {:ok, typed_expr, type} | {:error, [reason]}
```

  The module exports `dN/arity` for every def, plus `__nobi__/1`, which answers `:names`, `:image`, `:models` and `:types`.

- [ ] **Step 1:** Read `interp/eval.rs` (how each node evaluates) and `program.rs`.
- [ ] **Step 2: Failing tests.**
  - Every corpus program and every generated program, once promoted in a fresh universe, compiles with `:compile.forms` and no warnings or errors.
  - `__nobi__(:names)` lists every def.
  - Two universes with the same code produce the same module name.
  - No atom is created from user names: assert on `Atom.to_string` of every atom in the forms, matching `~r/^(d\d+|V\d+|nobi_img_[0-9a-f]{20}|__nobi__|…erlang-builtins)$/`, or walk the forms and check every `:atom` literal comes from a fixed allowlist.
- [ ] **Step 3:** Implement. Notes:
  - Lower `case` patterns to Erlang patterns over the representation, including nested variants and tuples.
  - Blocks rebind to fresh `V` variables.
  - Closures become `fun` forms.
  - Variant and record construction is inline tuples.
  - Stdlib calls are remote calls to `'Elixir.Nobi.Lang.Rt.Stdlib'`.
  - A def used as a value becomes `fun mod:dN/K`.
  - A constructor reference becomes a fun.
  - `always` calls `Rt.always!/1`.
  - JSON calls pass the literal type plus the `models` table (`__nobi__(:models)` inside the module).
- [ ] **Step 4:** See it pass, `mix precommit`, then `jj commit -m "feat(lang): Erlang codegen"`.

### Task 4: `Nobi.Exec`

**Files:** `lib/nobi/exec.ex`, `lib/nobi/exec/show.ex`; test `test/nobi/exec_test.exs`

**Interfaces:**

```elixir
Nobi.Exec.load(u) :: {:ok, image} | {:error, reason}          # cached by hash in :persistent_term; load_binary once
Nobi.Exec.call(u_or_image, name, args, opts \\ []) :: {:ok, value} | {:error, %{code, message}}
Nobi.Exec.eval(u, source, opts \\ []) :: {:ok, value, type} | {:error, %{code, message}}
Nobi.Exec.test(u, name, opts \\ []) :: :ok | {:error, %{code, message}}
Nobi.Exec.show(value, type) :: String.t()                     # Nobi source syntax
Nobi.Exec.unload(image) :: :ok
```

- [ ] **Step 1: Failing tests.**
  - Port the semantic tests from `tests/interp_eval.rs` through `Exec.eval`, plus the evaluator-dependent stdlib tests that Task 2 deferred.
  - Add the Review Focus tests:
    - infinite recursion gives `"timeout"` with a short timeout, and the spawned process is gone afterwards (check with a monitor or `Process.list` diff);
    - a huge list gives `"heap"` with a small `max_heap_size`;
    - identical universes share a module, with no second `load_binary`;
    - after a promotion, the old image still answers its old body;
    - `eval` of an ill-typed expression or an unknown name returns a checker code and spawns nothing;
    - `show` round-trips: `Exec.eval(u, Exec.show(v, t))` gives `v` back for corpus values.
- [ ] **Step 2:** Implement.
  - Run in `spawn_monitor` with `Process.flag(:max_heap_size, %{size: n, kill: true, error_logger: false})` set inside the child.
  - Receive with a timeout, and `Process.exit(pid, :kill)` on timeout.
  - Map `:killed` from the heap limit to `"heap"`.
  - `eval` evaluates the forms from `Codegen.expr_forms` with `:erl_eval.exprs/2`.
- [ ] **Step 3:** See it pass, `mix precommit`, then `jj commit -m "feat: Nobi.Exec loads, calls and evaluates images"`.

### Task 5: Goldens green

**Files:** test `test/nobi/exec_golden_test.exs`

- [ ] **Step 1: Port** `golden.rs:556-830`:
  - every corpus and generated call answers as in TS;
  - every trace (init, view, updates, steps) answers as in TS;
  - every corpus deftest scores as in TS;
  - every `stdlib.json` example is `true`;
  - failures are pinned exactly as Rust pins them (`every_interpreter_failure_is_pinned_or_division_by_zero`).

  Use the same `Tally` approach: compare where TS had an answer, compare closures through the `lambda()` marker, and report mismatches with the site.
- [ ] **Step 2:** Any divergence is a bug in Rt or Codegen. Fix it there, never in a fixture, and record each fix in the report.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "test: Erlang-backed evaluation matches TS goldens"`.

### Task 6: REPL experience

**Files:** modify `lib/nobi/exec.ex` and `lib/nobi/lang.ex` moduledocs; create `.iex.exs` with aliases (`alias Nobi.{Lang, Exec}`); test `test/nobi/exec_repl_test.exs`

- [ ] **Step 1: Test**, as a doctest or a plain test, the iex walkthrough:
  1. load the counter corpus;
  2. `Exec.eval(u, "Counter.init()")`;
  3. `Exec.eval(u, "Counter.update(Counter.Msg.Add(5), %Counter.Model{count: 1})")` shows `(%Counter.Model{count: 6}, Cmd.none())`;
  4. `Exec.eval(u, "Counter.view(%Counter.Model{count: 2})")` shows Html.
- [ ] **Step 2:** Write the moduledoc walkthrough and `.iex.exs`. Commit with `jj commit -m "docs: iex walkthrough for running Nobi"`.
