import Nobi.Prim.Ops

/-! # Option

`spec/semantics.md`, § Stdlib: Option. `rt/stdlib.ex` L292-313. -/

namespace Nobi.Prim.Opt

private def a : Ty := .var "a"
private def b : Ty := .var "b"

def sigs : List (String × Sig) :=
  [ ("Option.with_default", { tparams := ["a"], params := [optT a, a], ret := a }),
    ("Option.map", { tparams := ["a", "b"], params := [optT a, .arrow [a] b], ret := optT b }),
    ("Option.and_then", { tparams := ["a", "b"], params := [optT a, .arrow [a] (optT b)], ret := optT b }) ]

def apply : Impl := fun _P call op _targs args =>
  match op, args with
  | "Option.with_default", [.variant "Option" "Some" [x], _] => some (.ok x) -- [P-Option.with_default]
  | "Option.with_default", [.variant "Option" "None" [], d] => some (.ok d)
  | "Option.map", [.variant "Option" "Some" [x], f] => some (some' <$> call f [x]) -- [P-Option.map]
  | "Option.map", [.variant "Option" "None" [], _] => some (.ok none')
  | "Option.and_then", [.variant "Option" "Some" [x], f] => some (call f [x]) -- [P-Option.and_then]
  | "Option.and_then", [.variant "Option" "None" [], _] => some (.ok none')
  | _, _ => if (sigs.lookup op).isSome then some (.error .stuck) else none

end Nobi.Prim.Opt
