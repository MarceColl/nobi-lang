# spec

The executable Lean 4 specification of Nobi's core language.

| Path | What it is |
|---|---|
| `semantics.md` | Every typing and evaluation rule, each named (`[T-…]`, `[E-…]`) |
| `CHANGES.md` | Spec versions, each with its class, and triaged disagreements |
| `excluded.json` | AST kinds and stdlib names deliberately outside core |
| `beam-assumptions.md` | BEAM behaviours the runtime relies on (`[B-…]`) |
| `lean/` | The Lake package: `Nobi` (the spec), `nobi-ref` (its CLI), `Tests` |

## Running it

Needs [elan](https://github.com/leanprover/elan); it installs the toolchain
pinned in `lean/lean-toolchain`. No Mathlib and no other Lake dependencies.

```sh
cd spec/lean
lake build                         # the spec and nobi-ref
lake test                          # every #guard, the VERSION check and scripts/rule-names.sh
.lake/build/bin/nobi-ref version   # the spec version
.lake/build/bin/nobi-ref prims     # every stdlib primitive and its signature, as JSON
```

CI runs the same through `.github/workflows/spec.yml` on every pull request
that touches `spec/`, `lib/nobi/lang/`, `lib/nobi/exec/` or
`test/support/spec/`.
