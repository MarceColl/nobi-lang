# Nobi core semantics

The rules of Nobi's core language: its types, how each expression is typed
(`Γ ⊢ e : τ`) and how it evaluates (`ρ ⊢ e ⇓ r`). The executable form of
every rule is in `spec/lean/`. Each rule has a name such as `[E-Case]`, and
that name tags exactly one match arm in `spec/lean/Nobi/` (checked by
`spec/lean/scripts/rule-names.sh`, which `lake test` runs).

Each rule line gives its name, the rule, and the spec version it has held
since. The line under it names the Elixir source it was checked against
(paths under `lib/nobi/lang/`, at
[`dc8b886`](https://github.com/MarceColl/nobi-lang/tree/dc8b8862ef16b245a51aeb6561fe5e8bf7cdab93)).

Surface Nobi lowers to this core: `if`, `and`/`or`, `!=`, blocks, annotations
and JSX become the forms below (see "Lowering"). What core leaves out is
listed in `spec/excluded.json`.

## Types

```
τ ::= Int | String | Bool | Unit | Uuid
    | (τ₁, …, τₙ)            n ≥ 2
    | List τ | Map τ τ
    | (τ₁, …, τₙ) -> τ
    | T τ*                    a deftype or a model; Option and Result are stdlib deftypes
    | a                       a deftype's parameter, only inside its variants
```

Types are compared structurally: two types are equal when they are the same
tree. There are no type variables outside deftype declarations: every def
and lambda parameter is annotated, every polymorphic primitive and
constructor carries its type arguments, and a list or map literal carries its
item types. A lowering from surface Nobi reads them from the checker's
`type:` meta.

A type written in a program is **well-formed** when every name in it resolves
to a builtin, a deftype with as many arguments as it declares parameters, or
a model with none (`unbound`, `arity`). Its map keys must be **data**: no
function type anywhere in a key type, including through a deftype parameter
that reaches a map key (`non-data-map-key`, `types/keys.ex`).

Those are the only constraints on a type itself (`types/check.ex`
L145-213). Every type parameter stands for any type: there are no
higher-kinded parameters, bounds or classes, so a count is all an argument
list needs. The other rules sit where a type is declared, in [T-Program]:
model fields and variant arguments hold data, and parameter names are
distinct (`types/check/decl.ex` L104-165, L255-270). Because a variant
argument never holds a function, a deftype cannot recur through one, and
recursive deftypes need no positivity check.

## Values

```
v ::= int n | str s | bool b | unit | uuid s
    | tuple v* | list v* | map (v × v)*        entries sorted by key, keys unique
    | record M (f × v)*                         fields sorted by name
    | variant Owner C v*
    | closure ρ (x : τ)* e | defRef g | ctorRef Owner C arity
r ::= ok v | err c
c ::= divZero | noField | noArm | weight | fuel | stuck
```

`stuck` is the result wherever a value has the wrong shape for its rule
(adding a Bool, reading a field of an Int, calling an Int). `noArm` is a
`case` no arm matched. A well-typed program never produces either (G3 in the
plan); the BEAM has no `stuck`, and there the same situation is an `internal`
error. `fuel` is running out of fuel: inconclusive, not an error of the
program. The Lean `Value.conforms P v τ` is the runtime check that `v` is a
value of type `τ`.

## Numbers

Int only (Float arrives in spec 2.1.0).

- **Domain:** every integer, as Lean `Int`. There is no range check and no
  overflow.
- **`+ − *` and negation:** the exact result.
- **`/`:** truncates toward zero (`Int.tdiv`, Erlang `div`). A zero divisor is
  `divZero`, the only Int error.
- **Comparison:** numeric.
- **No coercions.** Every operator is homogeneous; mixing types is the type
  error `mismatch`.
- **Literals:** non-negative (a minus is `neg`). Core takes any size; the
  lexer refuses one of more than 4300 digits (`Rt.max_int_digits/0`).
- **On the BEAM:** integers are bignums on every build, so the operators are
  Erlang's `+ − * div` as they are. Word size moves only the internal
  small/bignum boundary (2⁵⁹ on 64-bit), which no Int operation observes.
  The emulator refuses an integer wider than 4,194,240 bits (about 1.26
  million digits) with `system_limit`. That is a resource limit, like the
  worker's deadline and heap cap, not a result of the program. Stage 2 adds
  probes for these facts
  (`B-int-bignum`, `B-int-div` in `beam-assumptions.md`).

Source: `rt.ex` L137-155, less the `checked/1` range check that 2.0.0
drops; `lexer.ex` L112-121, less its literal limit.

## Literals

[T-Int] `Γ ⊢ n : Int`. since: 1.0.0

[T-Str] `Γ ⊢ s : String`. since: 1.0.0

[T-Bool] `Γ ⊢ b : Bool`. since: 1.0.0

[T-Unit] `Γ ⊢ unit : Unit`. since: 1.0.0
Source: `types/check.ex` L328-330, L409.

[E-Int] `ρ ⊢ n ⇓ int n`. since: 2.0.0
Source: `codegen/expr.ex` L151, for every literal.

[E-Str] `ρ ⊢ s ⇓ str s`. since: 1.0.0

[E-Bool] `ρ ⊢ b ⇓ bool b`. since: 1.0.0

[E-Unit] `ρ ⊢ unit ⇓ unit`. since: 1.0.0
Source: `codegen/expr.ex` L153-154, L286.

## Names and calls

[T-Var] `Γ(x) = τ ⟹ Γ ⊢ x : τ`; an unbound local is `unbound`. since: 1.0.0
Source: `types/check.ex` L223-235.

[T-Global] `g` is a def `(x₁ : τ₁, …) : τ ⟹ Γ ⊢ g : (τ₁, …) -> τ`. since: 1.0.0
Source: `types/check.ex` L290-306.

[T-CallDef] `g : (τ₁ … τₙ) -> τ`, `Γ ⊢ eᵢ : τᵢ ⟹ Γ ⊢ g(e₁ … eₙ) : τ`; a wrong count is `arity`, a wrong type `mismatch`. since: 1.0.0
Source: `types/check.ex` L507-544.

[T-App] `Γ ⊢ f : (τ₁ … τₙ) -> τ`, `Γ ⊢ eᵢ : τᵢ ⟹ Γ ⊢ f(e₁ … eₙ) : τ`; a callee of any other type is `not-a-function`. since: 1.0.0
Source: `types/check.ex` L507-544 (a call of a local).

[E-Var] `ρ(x) = v ⟹ ρ ⊢ x ⇓ v`; unbound is `stuck`. since: 1.0.0
Source: `codegen/expr.ex` L362, L378.

[E-Global] `ρ ⊢ g ⇓ defRef g`. since: 1.0.0
Source: `codegen/expr.ex` L382-397.

[E-CallDef] Evaluate the arguments left to right to `v₁ … vₙ`, then the body of `g` in the environment `x₁ ↦ v₁ … xₙ ↦ vₙ` (nothing else is in scope). The first error is the result. since: 1.0.0
Source: `codegen/expr.ex` L436-452, L14-21.

[E-App] Evaluate the callee, then the arguments left to right, then apply: a closure `closure ρ' (x : τ)* e` evaluates `e` in `ρ'` extended with the parameters; a `defRef g` calls `g` as [E-CallDef]; a `ctorRef O C k` builds `variant O C v₁ … vₖ`. A wrong arity or a callee that is no function is `stuck`. since: 1.0.0
Source: `codegen/expr.ex` L403-404.

## Functions

Functions are values. They are bound by `let`, passed as arguments,
returned, and held in tuples, lists, map values and deftype arguments
(`Option<(Int) -> Int>`), but not in model fields or variant arguments.

[T-Lam] Each parameter's type is well-formed, no name twice (`bad-name`), and `Γ, x₁ : τ₁ … ⊢ e : τ ⟹ Γ ⊢ fn (x₁ : τ₁ …) -> e : (τ₁ …) -> τ`. since: 1.0.0
Source: `types/check.ex` L461-472.

[E-Lam] `ρ ⊢ fn (x : τ)* -> e ⇓ closure ρ (x : τ)* e`: the closure captures the whole environment. since: 1.0.0
Source: `codegen/expr.ex` L247-251.

## Bindings

A block's statements lower to nested `let` and `;`; a rebinding in an inner
block shadows.

[T-Let] `Γ ⊢ e₁ : τ₁`, `Γ, x : τ₁ ⊢ e₂ : τ ⟹ Γ ⊢ let x = e₁ in e₂ : τ`. since: 1.1.0
Source: `types/check.ex` L688-709, less the function check (L697-706) that 1.1.0 drops.

[T-Seq] `Γ ⊢ e₁ : τ₁`, `Γ ⊢ e₂ : τ ⟹ Γ ⊢ e₁; e₂ : τ`. since: 1.0.0
Source: `types/check.ex` L683-686.

[E-Let] `ρ ⊢ e₁ ⇓ v`, `ρ, x ↦ v ⊢ e₂ ⇓ r ⟹ ρ ⊢ let x = e₁ in e₂ ⇓ r`; an error of `e₁` is the result. since: 1.0.0
Source: `codegen/expr.ex` L103-107.

[E-Seq] Evaluate `e₁` and drop its value (not its error), then `e₂`. since: 1.0.0
Source: `codegen/expr.ex` L95-109.

## Operators

Every surface operator lowers to a primitive: `+ − * /` to the Int
primitives, unary minus to `neg`, `not` to `not`, `++` to string
concatenation, `==` to `prim == [τ]`, and `a != b` to
`not (prim == [τ] (a, b))`. `and`/`or` are not primitives: they lower to a
`case` and short-circuit. All binary operators are left-associative; the
lowering keeps the parser's grouping.

[T-Prim] A primitive `p` with signature `∀ a₁ … aₖ. (σ₁ … σₙ) -> σ`, given `k` well-formed type arguments `τ̄`, and `Γ ⊢ eᵢ : σᵢ[τ̄/ā]` ⟹ `Γ ⊢ prim p [τ̄] (e₁ … eₙ) : σ[τ̄/ā]`. An unknown primitive is `unbound`. since: 1.0.0
Source: `types/check.ex` L383-415, L492-495.

[E-Prim] Evaluate the arguments left to right, then apply the primitive. since: 1.0.0
Source: `codegen/expr.ex` L191-203, L295-307.

The operators' signatures and behaviour:

[P-add] `+ : (Int, Int) -> Int`, exact (§ Numbers). since: 2.0.0

[P-sub] `- : (Int, Int) -> Int`, exact. since: 2.0.0

[P-mul] `* : (Int, Int) -> Int`, exact. since: 2.0.0

[P-div] `/ : (Int, Int) -> Int`, truncating; `divZero`. since: 2.0.0

[P-neg] `neg : (Int) -> Int`, exact. since: 2.0.0

[P-lt] `< : (Int, Int) -> Bool`. since: 1.0.0

[P-gt] `> : (Int, Int) -> Bool`. since: 1.0.0

[P-le] `<= : (Int, Int) -> Bool`. since: 1.0.0

[P-ge] `>= : (Int, Int) -> Bool`. since: 1.0.0

[P-concat] `++ : (String, String) -> String`. since: 1.0.0

[P-not] `not : (Bool) -> Bool`. since: 1.0.0

[P-eq] `== : ∀a. (a, a) -> Bool`: `Value.eq` (§ Equality and order). since: 1.0.0
Source: `rt.ex` L137-158, L169-183; `codegen/expr.ex` L297-307.

## Equality and order

**Equality** (`Value.eq`, `rt.ex` L169-244) is structural, with one rule for
functions: a closure equals nothing, itself included; a def taken as a value
equals only the same def; a constructor taken as a value equals only the same
constructor. Map equality ignores insertion order (core maps are sorted).

**Order** (`Value.cmp`, `rt.ex` L270-304, L416-507) is first by kind, Int <
String < Bool < Uuid < List < Map < tuple (Unit is the empty tuple) < record
< variant < function, then structurally: Int numerically; String and Uuid by
code point; `false < true`; lists, tuples and maps lexicographically (a map
as its sorted entries, an entry by key then value); a record by model name,
then its fields as sorted pairs; a variant by owner, then name, then
arguments. Only map keys are compared, and keys hold no functions, so the
order among functions is unspecified beyond their kind.

**The walk budget.** A value's weight is one step per node and one more per
64 bytes of a string; field and variant names cost nothing, and a closure is
one step (its environment is never walked). `==` on two values is `weight`
when both weigh more than 1,000,000 steps, unless one side is an Int or a
Bool, or both are strings, Uuids or functions. Inserting a key that is not an
Int or a Bool into a map of `n` keys is `weight` when its weight times
`⌈log₂(n + 1)⌉ + 1` is more than 1,000,000. Source: `rt.ex` L308-414.

## Collections

[T-Tuple] `Γ ⊢ eᵢ : τᵢ`, n ≥ 2 ⟹ `Γ ⊢ (e₁, …, eₙ) : (τ₁, …, τₙ)`. since: 1.0.0
Source: `types/check.ex` L378-381.

[T-List] `τ` well-formed, `Γ ⊢ eᵢ : τ` ⟹ `Γ ⊢ [e₁, …]τ : List τ`. since: 1.0.0
Source: `types/check.ex` L351-361.

[T-Map] `Map τₖ τᵥ` well-formed with data keys, `Γ ⊢ kᵢ : τₖ`, `Γ ⊢ vᵢ : τᵥ` ⟹ `Γ ⊢ %{k₁ => v₁, …} : Map τₖ τᵥ`. since: 1.0.0
Source: `types/check.ex` L363-376, L115-133.

[E-Tuple] Items left to right. since: 1.0.0
Source: `codegen/expr.ex` L182-183.

[E-List] Items left to right. since: 1.0.0
Source: `codegen/expr.ex` L163-167.

[E-Map] Each key, then its value, left to right; then the pairs are inserted in order, each key charged (§ Equality and order), a later duplicate key replacing an earlier one's value. since: 1.0.0
Source: `codegen/expr.ex` L169-180, `rt.ex` L376-381.

## Records

A model's fields hold data: no function anywhere in a field's type
(`invalid-model-field`). `id : Uuid` is identity, minted by the store: a
construction may leave it out, and the record then has no `id` field.

[T-Construct] `M` is a model (else `not-a-model`); every field set is declared (else `extra-field`) and set once (else `extra-field`); every declared field but `id : Uuid` is set (else `missing-field`); each value has its field's type ⟹ `Γ ⊢ %M{f₁: e₁, …} : M`. since: 1.0.0
Source: `types/check.ex` L420-436, L497-499, L647-670.

[T-Field] `Γ ⊢ e : M`, `M` a model (else `not-a-model`) with field `f : τ` (else `unknown-field`) ⟹ `Γ ⊢ e.f : τ`. since: 1.0.0
Source: `types/check.ex` L551-599.

[T-Update] `Γ ⊢ e : M`, and the fields set as in [T-Construct] but all optional ⟹ `Γ ⊢ %M{e | f₁: e₁, …} : M`. since: 1.0.0
Source: `types/check.ex` L439-450.

[E-Construct] Field values left to right; the record holds the fields set, sorted by name. since: 1.0.0
Source: `codegen/expr.ex` L212-216.

[E-Field] `ρ ⊢ e ⇓ record M fs` ⟹ `fs(f)`, or `noField` when the record lacks it (an `id` left out); any other value is `stuck`. since: 1.0.0
Source: `rt.ex` L518-525.

[E-Update] The base, then the field values left to right; the base's fields with those set. A base that is no record is `stuck`. since: 1.0.0
Source: `codegen/expr.ex` L218-222, `rt.ex` L528-529.

## Variants

A deftype's variant arguments hold data, as a model's fields do. `Option`
and `Result` are stdlib deftypes: `Option<T> = Some(T) | None` and
`Result<T, E> = Ok(T) | Err(E)`.

[T-Ctor] `O` is a deftype with parameters `ā` and variant `C(σ₁ … σₙ)` (else `unbound`), given as many well-formed type arguments `τ̄` (else `arity`), `Γ ⊢ eᵢ : σᵢ[τ̄/ā]` ⟹ `Γ ⊢ O.C[τ̄](e₁ … eₙ) : O τ̄`. A variant of no arguments is `O.C[τ̄]()`. since: 1.0.0
Source: `types/check.ex` L237-286, L507-527.

[T-CtorRef] As [T-Ctor], with `n ≥ 1` (a variant of no arguments is a value, not a function: `arity`) ⟹ `Γ ⊢ O.C[τ̄] : (σ₁[τ̄/ā] …) -> O τ̄`. since: 1.0.0
Source: `types/check.ex` L278-283.

[E-Ctor] Arguments left to right ⟹ `variant O C v₁ … vₙ`. since: 1.0.0
Source: `codegen/expr.ex` L409-410.

[E-CtorRef] `ρ ⊢ O.C ⇓ ctorRef O C n`, `n` the variant's arity. since: 1.0.0
Source: `codegen/expr.ex` L366-373, `rt.ex` L535-550.

## Case and patterns

```
p ::= _ | x | n | s | b | (p₁, …, pₙ) | Owner.C(p*)
```

[T-Case] `Γ ⊢ e : τ`, `τ` a deftype, a scalar (Int, String, Bool, Uuid) or a tuple (else `mismatch`); each arm's pattern binds `Γᵢ` against `τ`, no name twice in a pattern (`bad-name`), `Γ, Γᵢ ⊢ eᵢ : τ'` for one `τ'` (else `mismatch`); the arms are exhaustive ([T-Exhaustive]) ⟹ `Γ ⊢ case e of p₁ -> e₁ … : τ'`. since: 1.0.0
Source: `types/check.ex` L716-784, `types/patterns.ex` L347-355.

[T-Exhaustive] Some arm's pattern matches every value (`_`, a binder, or a tuple of those); or, on a deftype, every variant `C` has an arm `Owner.C(p…)` whose sub-patterns each match every value. Otherwise `non-exhaustive`. Deep tuple coverage (the surface checker's Maranget usefulness check) is not specified yet: on a tuple, an arm must match everything. since: 1.0.0
Source: `types/check.ex` L766-782, `types/patterns.ex` L165-213.

[T-PWild] `_` matches any `τ` and binds nothing. since: 1.0.0

[T-PVar] `x` matches any `τ` and binds `x : τ`. since: 1.0.0

[T-PInt] `n` matches `Int` (else `mismatch`). since: 1.0.0

[T-PStr] `s` matches `String`. since: 1.0.0

[T-PBool] `b` matches `Bool`. since: 1.0.0

[T-PTuple] `(p₁ … pₙ)` matches `(τ₁ … τₙ)`, each `pᵢ` against `τᵢ` (else `mismatch`). since: 1.0.0

[T-PVariant] `O.C(p₁ … pₙ)` matches `O τ̄` where `C(σ₁ … σₙ)` is a variant of `O`, each `pᵢ` against `σᵢ[τ̄/ā]`; another owner, an unknown variant, a wrong count or a scrutinee that is no deftype is `bad-pattern`. since: 1.0.0
Source: `types/patterns.ex` L90-215.

[E-Case] Evaluate the scrutinee, then try the arms top-down: the first whose pattern matches evaluates its body with the pattern's bindings added. No match is `noArm`. since: 1.0.0
Source: `codegen/expr.ex` L224-236, `rt.ex` L612.

Matching a value:

[E-PWild] `_` matches anything. since: 1.0.0

[E-PVar] `x` matches anything and binds it. since: 1.0.0

[E-PInt] `n` matches `int n`. since: 1.0.0

[E-PStr] `s` matches `str s`. since: 1.0.0

[E-PBool] `b` matches `bool b`. since: 1.0.0

[E-PTuple] `(p₁ … pₙ)` matches a tuple of `n` items, each `pᵢ` its item. since: 1.0.0

[E-PVariant] `O.C(p₁ … pₙ)` matches `variant O C v₁ … vₙ`, each `pᵢ` its argument. since: 1.0.0
Source: `codegen/expr.ex` L546-573.

## Programs

[T-Program] A program checks when: each deftype's parameters are distinct and its variant arguments are well-formed over them and hold data; each model's fields are well-formed and hold data; each def's parameter and return types are well-formed, its parameter names distinct, and its body has its return type with only its parameters in scope. since: 1.0.0
Source: `types/check/decl.ex` L83-125, L145-168.

An entry is a def of no parameters; running it is `[E-CallDef]` with no
arguments, with a fuel bound on evaluation depth.

## Lowering

What surface forms become (done by the lowering in a later phase):

| Surface | Core |
|---|---|
| `if c do a else b end` | `case c of true -> a; _ -> b` |
| `a and b` / `a or b` | `case a of true -> b; _ -> false` / `case a of true -> true; _ -> b` |
| `a != b` | `prim not (prim == [τ] (a, b))` |
| a block (`x = e` and `e` statements) | nested `let` / `;`, shadowing by fresh names |
| `(e : T)` | `e` |
| `not e`, `-e`, binary operators | `prim not`, `prim neg`, `prim +` … |
| a constructor used as a value | `ctorRef` |
| a lowercase dotted name `x.a.b` | nested `field` |

## Implementation limits

Bounds of the implementation, not rules of the language:

- The BEAM bounds a run by a 5,000 ms timeout and a heap limit
  (`exec/worker.ex`); the spec bounds evaluation depth by fuel.
- `Exec.Show` truncates at 64 levels or 10,000 nodes.
- A constructor of more than 8 arguments taken as a value is compiled as a
  closure, so on the BEAM it equals nothing (`rt.ex` L233-234); the spec says
  it equals the same constructor. See `CHANGES.md`.
