import Nobi.Prim.Ops

/-!
# Cmd

`spec/semantics.md`, § Stdlib: Cmd. `rt.ex` L564-583, `rt/stdlib.ex`
L357-374. A `Cmd` is data: building one runs nothing. An effect holds its
stdlib name, the stored model a store effect works on (its first type
argument, a model), and its arguments in order, callbacks as the functions
they are. `Cmd.store.tx` is outside core (`spec/excluded.json`).
-/

namespace Nobi.Prim.Cmd

private def a : Ty := .var "a"
private def b : Ty := .var "b"

def sigs : List (String × Sig) :=
  [ ("Cmd.none", { tparams := ["a"], params := [], ret := .cmd a }),
    ("Cmd.batch", { tparams := ["a"], params := [.list (.cmd a)], ret := .cmd a }),
    ("Cmd.store.insert", { tparams := ["a", "b"], params := [a, .arrow [.uuid] b], ret := .cmd b, store := true }),
    ("Cmd.store.list", { tparams := ["a", "b"], params := [.arrow [.list a] b], ret := .cmd b, store := true }),
    ("Cmd.store.get", { tparams := ["a", "b"], params := [.uuid, .arrow [optT a] b], ret := .cmd b, store := true }),
    ("Cmd.store.update", { tparams := ["a", "b"], params := [.uuid, a, .arrow [.uuid] b], ret := .cmd b, store := true }),
    ("Cmd.store.delete", { tparams := ["a", "b"], params := [.uuid, .arrow [optT a] b], ret := .cmd b, store := true }),
    ("Cmd.time.now", { tparams := ["a"], params := [.arrow [.int] a], ret := .cmd a }),
    ("Cmd.random.int", { tparams := ["a"], params := [.int, .int, .arrow [.int] a], ret := .cmd a }),
    ("Cmd.blob.put", { tparams := ["a"], params := [.str, .str, .arrow [.str] a], ret := .cmd a }),
    ("Cmd.blob.get", { tparams := ["a"], params := [.str, .arrow [optT .str] a], ret := .cmd a }),
    ("Cmd.blob.list", { tparams := ["a"], params := [.str, .arrow [.list .str] a], ret := .cmd a }),
    ("Cmd.blob.delete", { tparams := ["a"], params := [.str, .arrow [.str] a], ret := .cmd a }),
    ("Cmd.ai.generate", { tparams := ["a"], params := [.str, .str, .arrow [.str] a], ret := .cmd a }) ]

def isCmd : Value → Bool
  | .cmdNone | .cmdBatch _ | .cmdEffect .. => true
  | _ => false

/-- The stored model a store form's type arguments name. -/
def storeModel : List Ty → Option String
  | .named m [] :: _ => some m
  | _ => none

def apply : Impl := fun _P _call op targs args =>
  match op, args with
  | "Cmd.none", [] => some (.ok .cmdNone) -- [P-Cmd.none]
  | "Cmd.batch", [.list cs] => -- [P-Cmd.batch]
    some (if cs.all isCmd then .ok (.cmdBatch cs) else .error .stuck)
  | _, _ =>
    match sigs.lookup op with
    | some s =>
      -- [P-Cmd.effect]
      if s.params.length == args.length then
        some (.ok (.cmdEffect op (if s.store then storeModel targs else none) args))
      else some (.error .stuck)
    | none => none

end Nobi.Prim.Cmd
