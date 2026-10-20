# Spec changes

Each entry names its spec version and its class:

- **patch:** spec text only, behaviour unchanged.
- **minor:** compatible. Every program accepted at the previous version is
  accepted with the same types and gives the same result on every entry.
- **major:** anything else. It needs a migration or an explicit sign-off
  that lists the programs it breaks.

Triaged disagreements between the spec and the implementation are recorded
here too, each with its verdict.

## 1.1.0

Class: minor. A `let` may bind a function: a lambda, a def or a
constructor taken as a value. 1.0.0 refused such a binding with
`bad-name`, a rule the checker took from the Yabu reference and nothing in
Nobi relied on. Every program 1.0.0 accepts types and runs as before.

## 1.0.0 (initial)

Class: initial. The language as on main at
[`dc8b886`](https://github.com/MarceColl/nobi-lang/commit/dc8b8862ef16b245a51aeb6561fe5e8bf7cdab93).

### Open questions (from writing the core rules)

Places where the spec states a rule the implementation does not quite
follow, or leaves something unspecified. Each needs a verdict.

1. **Constructors of more than 8 arguments as values.** The spec says a
   constructor taken as a value equals the same constructor. On the BEAM one
   of more than 8 arguments is compiled as a closure, so it equals nothing
   (`rt.ex` L233-234).
2. **Deep tuple coverage.** The surface checker accepts a `case` on a tuple
   when its arms cover every value (Maranget usefulness,
   `types/exhaustive.ex`). The spec accepts it only when one arm matches
   everything. Programs that rely on deep coverage are outside the spec
   until it is specified.
3. **Order among functions.** The BEAM orders closures by their code's
   identity and defs by their compiled name. The spec leaves the order among
   functions unspecified beyond their kind; no program can observe it,
   because map keys hold no functions.
4. **Unit.** Surface Nobi has no Unit literal; Unit values come only from
   `always`/`sometimes`, which are outside core. Core keeps `unit` so the
   type has a value.
