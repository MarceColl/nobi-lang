# Yabu language core in Elixir — design

Piece 1 of 7 of the Kinoko-on-BEAM effort:
1. language core
2. `PersistentElmGenServer`
3. code DB server and MCP
4. Erlang codegen, one module per commit
5. `defapp` on `ElmLiveView` and `kinoko start`
6. universes
7. deploy (source plus hashes)

## Goal

A pure Elixir library. Yabu source text goes in; parsed, hashed and typechecked declarations come out, plus a universe that promotes staged patches only when the whole committed image typechecks. Checking is incremental: an edit that keeps a declaration's signature never rechecks its dependents.

It is a **port** of `~/proj/kinoko-next/crates/yabu` (Rust). Rust and TS are the oracle for behaviour. Representations are re-chosen for Elixir, and there is no compatibility with the JSON or KNV1 encodings.

## Out of scope

- An interpreter or eval. Execution arrives with codegen in piece 4, which then takes the eval goldens and `stdlib.json` examples as its tests. Stdlib *signatures* are in scope, because checking needs them.
- Persistence, processes, MCP, environments, forks, deploy, runtime, model migration.

## Shape

```
source text ──parse──▶ AST ──format──▶ canonical text ──sha256──▶ CID
                        │
                        └─▶ Universe.stage(u, id, source) ──▶ {u, verdict}
                               (salsa memo: Signature(cid) / Sig(name) / Check(cid))
```

Everything is a pure function over plain data. The universe is a struct that a later GenServer holds as its state.

### Modules (`lib/kinoko/lang/`)

| Module | Job | Rust origin |
|---|---|---|
| `Lexer`, `Parser` | text → AST; parse errors carry line and column | `syntax/lexer.rs`, `parser.rs` |
| `Format` | AST → canonical text; `format(parse(format(x))) == format(x)` | `syntax/format.rs` |
| `Cid` | `sha256("yabu/1\n" <> canonical_text)`, hex | replaces `canonical/` |
| `Types.Extract` | declaration → signature | `types/extract.rs` |
| `Types.Infer` | unification variables and schemes | `types/infer.rs` |
| `Types.Check` | bidirectional check of one declaration against its deps' signatures; patterns, exhaustiveness, JSX/app shape, hints | `types/check/*` |
| `Types.Stdlib` | stdlib and `Cmd.*` signatures | `types/stdlib.rs` |
| `Salsa` | layered inputs, red-green memo, early cutoff | `salsa.rs` |
| `Universe` | stage, unstage, promote, history, committed code | `universe/mod.rs`, `db.rs` |
| `Universe.Search` | promotion search: root, links, components, pruning | `universe/search.rs` |

There is one public façade, `Kinoko.Lang`:

- `parse/1`, `format/1`, `cid/1`
- `Universe.new/0`
- `stage(u, id, source) :: {u, {:promoted, [id]} | {:staged, reasons}}`
- `unstage/2`, `read/2`, `symbols/1`, `history/1`

## Representation

- **AST:** Elixir-quoted-style tagged tuples, `{kind, meta, args}`.
  - `meta` is a keyword list holding `line` and `col`.
  - `kind` is an atom from a closed set. The kinds are the ones in the oracle's `generated.json`, plus the declaration forms `def`, `defmodel`, `deftype`, `defapp` and `deftest`.
  - Pattern matching on the AST is the main idiom for the checker and for the later codegen.
- **Names** are fully qualified strings, for example `"Counter.update"`. `String.to_atom` is never called on source.
- **Types** are tagged tuples too: `{:named, n}`, `{:applied, n, ts}`, `{:arrow, params, ret}`, `{:tuple, ts}`, `{:var, n}` (the Rust `Type` enum). Checking stores each node's `type:` and `res:` in its `meta`, the way Elixir annotates quoted code, so the typed tree has the same shape as the parsed one.
- **Storage form is canonical text.** The AST is private to the compiler and may change shape freely. The CID hashes the formatter's output, with the format version `yabu/1` mixed in. So whitespace never changes a CID, and a deliberate formatter change bumps the version and rehashes everything.
- **References are by name**, not by CID. Editing a dependency leaves its dependents' CIDs unchanged, and the salsa layer cuts off at signatures.
- **Universe state** is a struct of plain maps and lists:
  - `cas: %{cid => text}`
  - `history: [round]`, newest first, append-only
  - `committed: %{name => cid}`, derived from history
  - `staged: %{id => patch}`
  - `salsa: Salsa.t()`

## Salsa

This is a port of `salsa.rs` semantics, as a pure struct threaded through calls:

- A context is an ordered list of layers: `:committed` plus `{:patch, id}`. A tombstone in a layer reads as absent.
- Each memo records the reads it made, in order. A memo is reused when every read still gives the same value (red-green). The walk stops at the first read that differs.
- Values are compared by value. A recompute that produces an equal value invalidates nothing that read it (early cutoff).
- The revision moves only when an input changes. Cycles and depth beyond 256 return errors.
- The queries are `{:signature, cid}`, `{:sig, name}`, `{:reaching, name}` and `{:check, cid}`.

## Universe and promotion

The semantics follow `specs/universe/universe.qnt`:

- A patch defines names and tombstones names. It promotes whole or not at all.
- After each stage, the largest set of staged patches that typechecks together promotes as one history round. This repeats until nothing more can promote.
- Invariants:
  - `nothingLeftPromotable`;
  - `stagedHasReason`: every staged patch carries the exact reasons it cannot promote;
  - committed code equals what replaying history produces.
- The search is a port of `search.rs`, including its known exponential case on k jointly-linked patches. That case is accepted.

## Error reporting

These are lessons from TS:

- Reasons are structured as `%{name, code, message}`. Any hint is worded into the message, as Rust does.
- Codes match the oracle's.
- Messages show the correct syntax, for example the `%M{}` construct form, never a bare "unbound".

## Testing — the oracle

Copy `corpus/*.yabu` and `crates/yabu/tests/oracle/*.json` into `test/fixtures/yabu/`, keeping the oracle's TS-commit stamp.

| Test | Asserts |
|---|---|
| format | round-trip and idempotence on corpus and generated programs; CID is stable under whitespace edits |
| corpus | per-declaration verdict, error codes and deps equal `corpus.json` |
| generated | every program in `generated.json` typechecks |
| ill_typed | every program in `ill_typed.json` is rejected with the oracle's codes |
| salsa | ported `tests/salsa.rs` cases: reuse, early cutoff, layers, cycles |
| universe | ported `universe/tests.rs` and `universe_conformance.rs`; search equals a naive all-subsets search on seeded random patch sets (`:rand` with a fixed seed, no new dependencies) |
| incrementality | a body-only edit to a dependency causes zero `{:check, cid}` recomputes of its dependents (counted through salsa stats) |

## Done when

- Every oracle fixture passes.
- `mix precommit` is green.
- `Kinoko.Lang` is the only module that other pieces call.
