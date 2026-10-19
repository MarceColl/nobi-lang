import Nobi.Prim.Ops
import Nobi.Prim.List
import Nobi.Prim.String
import Nobi.Prim.Option
import Nobi.Prim.Map
import Nobi.Prim.Uuid
import Nobi.Prim.Cmd
import Nobi.Prim.Html

/-!
# Primitives

Every primitive core can name: its signature (for `[T-Prim]`) and its
behaviour (for `[E-Prim]`). `call` applies a function value; the evaluator
passes it in, so a higher-order primitive calls back with the fuel left.
-/

namespace Nobi.Prim

/-- The stdlib functions, in module order. -/
def stdlibSigs : List (String × Sig) :=
  List.sigs ++ Str.sigs ++ Opt.sigs ++ Map.sigs ++ Uuid.sigs ++ Cmd.sigs

/-- Every primitive's signature, by name: the operators, then the stdlib. -/
def sigs : List (String × Sig) := opSigs ++ stdlibSigs

def sig? (op : String) : Option Sig := sigs.lookup op

def impls : List Impl :=
  [List.apply, Str.apply, Opt.apply, Map.apply, Uuid.apply, Cmd.apply]

/-- `op` applied to its evaluated arguments. An unknown primitive is `stuck`
(the typing rules reject it first). -/
def apply (P : Prog) (call : Value → List Value → Except RtErr Value)
    (op : String) (targs : List Ty) (args : List Value) : Except RtErr Value :=
  match applyOp op args with
  | some r => r
  | none =>
    match impls.findSome? (fun impl => impl P call op targs args) with
    | some r => r
    | none => .error .stuck

end Nobi.Prim
