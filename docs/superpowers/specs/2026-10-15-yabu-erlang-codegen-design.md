# Yabu → Erlang codegen and execution — design (piece 4)

Piece 4 of 7. It builds on piece 1, `Kinoko.Lang`, and is followed by piece 2 (`PersistentElmGenServer`).

## Goal

Committed Yabu code runs on the BEAM. Each committed image (one universe state) compiles to **one Erlang module**, built from abstract forms and loaded in memory. You can call defs, evaluate expressions, run deftests and step an app's `init`/`update`/`view` from iex. Behaviour matches the Rust/TS evaluators on their golden answers.

## Out of scope

- Hosting apps in LiveView (piece 5).
- Performing `Cmd` effects. A `Cmd` is data here, exactly as in the Rust evaluator.
- Persistence (piece 2), universes (6), deploy (7).
- Model migration of live state.

## Shape

```
Kinoko.Lang (pure)                          Kinoko.Exec (processes, code loading)
  committed image ──Codegen──▶ forms ──:compile.forms──▶ {module, beam}
                                                          │ load once, cached by image hash
  expr source ──check_expr──▶ typed expr ──Codegen──▶ expr forms ──:erl_eval──▶ value
```

- **`Kinoko.Lang.Codegen`** is pure and lives under `lib/kinoko/lang/`, so the purity rule holds. It turns the committed typed trees into Erlang abstract forms for one module, plus a name table.
  - `:compile.forms/2` is a pure computation, so compiling to a binary also stays inside `Kinoko.Lang`, as `Kinoko.Lang.image/1`.
- **`Kinoko.Lang.Rt`** is pure. It holds the runtime support the generated code calls: the stdlib bodies, checked arithmetic, Yabu equality and ordering, JSON, and the record, variant and Cmd constructors.
- **`Kinoko.Exec`** lives outside `lib/kinoko/lang/` and may use processes. It loads images, caches loaded modules by image hash, and runs calls in a monitored, bounded process.

## Image = module

- **Image hash:** `sha256` of the sorted `name\0cid\n` lines of committed code. Two universes with the same committed code share a module.
- **Module name:** `:"yabu_img_<first 20 hex chars of the image hash>"`. This is one atom per distinct image ever loaded, and the count is bounded by commits. That trade-off is accepted and documented.
- **Functions:** one exported function per def. Function atoms are **positional**: `:d0`, `:d1`, … by the def's index in sorted name order, so no atom is ever made from user text. The module also exports:
  - `__yabu__(:names)`, giving `%{name => {fun_atom, arity}}`;
  - `__yabu__(:image)`, giving the hash;
  - `__yabu__(:models)` and `__yabu__(:types)`, which carry the field order and the type info JSON needs.
- **Calls between defs** are local calls inside the module, so an image is one consistent snapshot. Every promotion produces a new image and a new module. The old module stays loaded and keeps serving whatever still runs it; "multiple versions running until one dies" falls out naturally. `Exec.unload/1` purges an image when the caller no longer needs it.
- **Rollback** is loading an older image: replay history to that round, then compile.

## Value representation (BEAM terms)

| Yabu | BEAM |
|---|---|
| `Int` | integer, checked against i64 after `+ - *` and on literals; overflow raises a Yabu runtime error |
| `String` | UTF-8 binary; `++` is binary concat |
| `Bool` | `true` / `false` |
| `Uuid` | `{:uuid, binary}` |
| `List<T>` | list |
| `Map<K,V>` | Erlang map. Equality ignores order. Anything that iterates a map sorts its keys by Yabu order (`Rt.compare/2`) |
| tuple | tuple |
| model record | `{:rec, "Model.Name", %{"field" => v}}` |
| variant | `{:var, "Owner", "Variant", [args]}`. `Option`, `Result` and `Html` (`Element`/`Text`) are ordinary variants |
| function | Erlang fun. A def used as a value is `&mod.dN/k`; a constructor reference is a fun that builds the variant |
| `Cmd` | `{:cmd, :none}` · `{:cmd, {:batch, [cmd]}}` · `{:cmd, {:effect, "Cmd.store.insert", model_or_nil, [args]}}` |

- **Equality** is structural (`Rt.eq/2`, which is `=:=` on this representation). Closures compare by Erlang fun equality; Rust says a closure equals nothing. The checker never lets a function reach a map key, so the difference shows only for `==` on closures, which the oracle never asks. This is documented and accepted.
- **Ordering** (`Rt.compare/2`) follows the Rust `Value` `Ord`:
  - first by kind, in the order Int, Str, Bool, Uuid, List, Map, Tuple, Record, Variant;
  - then structurally.

  It is what map iteration and `List.sort_by` use.
- **Runtime errors** are raised as `throw({:yabu_error, message})`, with the messages taken from Rust's `EvalError`: division by zero, `Int` overflow, no matching case arm, `always` violated. `Exec` turns them into `{:error, %{code: "runtime", message}}`.

## Codegen rules (typed tree → forms)

- **Params and locals** become Erlang variables named by position (`V0`, `V1`, …), never from user names. Rebinding in a block maps to a fresh variable.
- **`case`** becomes a single Erlang `case` over the lowered patterns. The checker guarantees exhaustiveness; a final `_ -> throw(no_arm)` clause stays as a guard.
- **`if`** becomes `case Cond of true -> …; false -> … end`.
- **Lambdas** become `fun`s. Closures capture by Erlang semantics.
- **`always(e)`** evaluates `e`, raises if it is false, and is otherwise `ok`; it behaves as a unit statement. **`sometimes(e)`** evaluates and ignores `e`. Assertion sites matter only to the simulator, which is out of scope.
- **Annotations** are erased.
- **`JSON.parse`** is type-directed: codegen passes the target type, as a literal term, into `Rt.json_parse/2`.
- **Stdlib calls** become remote calls into `Kinoko.Lang.Rt`. Constructor calls build variant or record terms inline.
- **JSX** builds `Html.Element(tag, attrs, children)` and `Html.Text` variants, exactly as the Rust evaluator writes them. Event attrs hold their Msg value or constructor fun.

## Execution (`Kinoko.Exec`)

- `Exec.load(u) :: {:ok, image}`. It compiles and loads the image if needed, keeping a cache keyed by image hash in `:persistent_term`. Loading again is a no-op.
- `Exec.call(u_or_image, name, args, opts)` and `Exec.eval(u, expr_source, opts)`:
  - `eval` type-checks the expression against the committed signatures, lowers it to forms, and evaluates them with `:erl_eval`, binding remote calls to the image module, so no module is created per eval;
  - both run in a spawned, monitored process with `max_heap_size` and a timeout (defaults 5 s and 1 GB).
  - They return `{:ok, value, type}` or `{:error, %{code: "runtime" | "timeout" | "heap" | <checker codes>, message}}`.
- `Exec.test(u, test_name)` runs a deftest.
- **`Exec.show(value, type)`** renders a value as Yabu source syntax, so the REPL echoes it, for example `%Counter.Model{count: 1}`.
- REPL convenience: `Kinoko.Exec` moduledoc shows parse → stage → `eval("Counter.update(Counter.Msg.Increment, …)")`.

## Testing — the oracle

From the *original* `~/proj/kinoko-next/crates/yabu/tests/oracle/*.json` (the `calls` and `traces` keys that piece 1 dropped), plus `stdlib.json`:
- **calls:** every def call TS answered gives an equal value, or both sides error.
- **traces:** for every app trace, `init`, then each `update` and `view`, equals TS's answer step by step.
- **stdlib.json:** every example expression evaluates to `true`.
- The interpreter tests from `tests/interp_eval.rs` and `tests/interp_stdlib.rs` are ported where they test semantics rather than Rust memory or stack mechanics.

A test-support decoder, ported from `tests/oracle/decode.rs`, turns TS's JSON values into the BEAM representation above, directed by the declared type.

## Done when

- The goldens pass, apart from cases the Rust port also pins.
- The counter app can be stepped from iex.
- `mix precommit` is green.
