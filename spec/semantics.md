# Nobi core semantics

The rules of Nobi's core language: its types, how each expression is typed
(`Γ ⊢ e : τ`) and how it evaluates (`ρ ⊢ e ⇓ r`). The executable form of
every rule is in `spec/lean/`. Each rule has a name such as `[E-Case]`, and
that name tags exactly one match arm in the Lean code.

Surface Nobi lowers to this core: `if`, `and`/`or`, `!=`, blocks, annotations
and JSX become the forms below. What core leaves out is listed in
`spec/excluded.json`.

## Types

## Values

## Numbers

## Literals

## Names and calls

## Functions

## Bindings

## Operators

## Equality and order

## Collections

## Records

## Variants

## Case and patterns

## Programs

## Implementation limits
