import Nobi.Prim.Ops

/-!
# Primitives

Every primitive core can name: its signature (for `[T-Prim]`) and its
behaviour (for `[E-Prim]`). `call` applies a function value; the evaluator
passes it in, so a higher-order primitive can call back with the fuel left.
-/

namespace Nobi.Prim

/-- Every primitive's signature, by name. -/
def sigs : List (String × Sig) := opSigs

def sig? (op : String) : Option Sig := sigs.lookup op

/-- `op` applied to its evaluated arguments. An unknown primitive is `stuck`
(the typing rules reject it first). -/
def apply (_P : Prog) (_call : Value → List Value → Except RtErr Value)
    (op : String) (_targs : List Ty) (args : List Value) : Except RtErr Value :=
  match applyOp op args with
  | some r => r
  | none => .error .stuck

end Nobi.Prim
