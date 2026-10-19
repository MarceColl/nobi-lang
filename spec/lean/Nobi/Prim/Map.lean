import Nobi.Prim.Ops

/-!
# Map

`spec/semantics.md`, § Stdlib: Map. `rt/stdlib.ex` L315-347. A map's entries
are kept in `Value.cmp` order, which is the order `keys`, `values` and
`to_list` give. Every path that looks a key up charges it first, as a map
literal's keys are (`Value.chargeInsertion`).
-/

namespace Nobi.Prim.Map

private def k : Ty := .var "k"
private def v : Ty := .var "v"

def sigs : List (String × Sig) :=
  [ ("Map.get", { tparams := ["k", "v"], params := [.map k v, k], ret := optT v }),
    ("Map.put", { tparams := ["k", "v"], params := [.map k v, k, v], ret := .map k v }),
    ("Map.delete", { tparams := ["k", "v"], params := [.map k v, k], ret := .map k v }),
    ("Map.has_key", { tparams := ["k", "v"], params := [.map k v, k], ret := .bool }),
    ("Map.size", { tparams := ["k", "v"], params := [.map k v], ret := .int }),
    ("Map.keys", { tparams := ["k", "v"], params := [.map k v], ret := .list k }),
    ("Map.values", { tparams := ["k", "v"], params := [.map k v], ret := .list v }),
    ("Map.to_list", { tparams := ["k", "v"], params := [.map k v], ret := .list (.tuple [k, v]) }),
    ("Map.from_list", { tparams := ["k", "v"], params := [.list (.tuple [k, v])], ret := .map k v }) ]

def find (key : Value) (es : List (Value × Value)) : Option Value :=
  (es.find? fun e => Value.cmp e.1 key == .eq).map (·.2)

def pairs : List Value → Except RtErr (List (Value × Value)) :=
  List.mapM fun
    | .tuple [a, b] => .ok (a, b)
    | _ => .error .stuck

/-- Charges `key` against a map of `es`, then runs `k`. -/
def charged (key : Value) (es : List (Value × Value)) (r : Except RtErr Value) :
    Option (Except RtErr Value) :=
  some do
    Value.chargeInsertion key es.length
    r

def apply : Impl := fun _P _call op _targs args =>
  match op, args with
  | "Map.get", [.map es, key] => charged key es (.ok (option' (find key es))) -- [P-Map.get]
  | "Map.put", [.map es, key, x] => charged key es (.ok (.map (Value.mapInsert key x es))) -- [P-Map.put]
  | "Map.delete", [.map es, key] => -- [P-Map.delete]
    charged key es (.ok (.map (es.filter fun e => Value.cmp e.1 key != .eq)))
  | "Map.has_key", [.map es, key] => charged key es (.ok (.bool (find key es).isSome)) -- [P-Map.has_key]
  | "Map.size", [.map es] => some (.ok (.int es.length)) -- [P-Map.size]
  | "Map.keys", [.map es] => some (.ok (.list (es.map (·.1)))) -- [P-Map.keys]
  | "Map.values", [.map es] => some (.ok (.list (es.map (·.2)))) -- [P-Map.values]
  | "Map.to_list", [.map es] => some (.ok (.list (es.map fun e => .tuple [e.1, e.2]))) -- [P-Map.to_list]
  | "Map.from_list", [.list xs] => -- [P-Map.from_list]
    some do
      let ps ← pairs xs
      .map <$> Value.mapFromList [] ps
  | _, _ => if (sigs.lookup op).isSome then some (.error .stuck) else none

end Nobi.Prim.Map
