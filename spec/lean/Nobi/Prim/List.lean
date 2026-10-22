import Nobi.Prim.Ops

/-!
# List

`spec/semantics.md`, § Stdlib: List. `rt/stdlib.ex` L86-152. A function
argument is called on the items in order, and its first error is the
result.
-/

namespace Nobi.Prim.List

private def a : Ty := .var "a"
private def b : Ty := .var "b"

def sigs : List (String × Sig) :=
  [ ("List.map", { tparams := ["a", "b"], params := [.list a, .arrow [a] b], ret := .list b }),
    ("List.filter", { tparams := ["a"], params := [.list a, .arrow [a] .bool], ret := .list a }),
    ("List.append", { tparams := ["a"], params := [.list a, a], ret := .list a }),
    ("List.concat", { tparams := ["a"], params := [.list a, .list a], ret := .list a }),
    ("List.length", { tparams := ["a"], params := [.list a], ret := .int }),
    ("List.is_empty", { tparams := ["a"], params := [.list a], ret := .bool }),
    ("List.foldl", { tparams := ["a", "b"], params := [.list a, b, .arrow [a, b] b], ret := b }),
    ("List.sum", { params := [.list .int], ret := .int }),
    ("List.maximum", { params := [.list .int], ret := optT .int }),
    ("List.minimum", { params := [.list .int], ret := optT .int }),
    ("List.reverse", { tparams := ["a"], params := [.list a], ret := .list a }),
    ("List.member", { tparams := ["a"], params := [.list a, a], ret := .bool }),
    ("List.all", { tparams := ["a"], params := [.list a, .arrow [a] .bool], ret := .bool }),
    ("List.any", { tparams := ["a"], params := [.list a, .arrow [a] .bool], ret := .bool }),
    ("List.head", { tparams := ["a"], params := [.list a], ret := optT a }),
    ("List.take", { tparams := ["a"], params := [.list a, .int], ret := .list a }),
    ("List.drop", { tparams := ["a"], params := [.list a, .int], ret := .list a }),
    ("List.filter_map", { tparams := ["a", "b"], params := [.list a, .arrow [a] (optT b)], ret := .list b }),
    ("List.sort_by", { tparams := ["a"], params := [.list a, .arrow [a] .int], ret := .list a }) ]

section
variable (call : Value → List Value → Except RtErr Value) (f : Value)

def filterM : List Value → Except RtErr (List Value)
  | [] => .ok []
  | x :: xs => do
    let keep ← truth (← call f [x])
    let rest ← filterM xs
    pure (if keep then x :: rest else rest)

/-- Stops at the first item that decides, as `Enum.all?` does. -/
def allM : List Value → Except RtErr Bool
  | [] => .ok true
  | x :: xs => do if ← truth (← call f [x]) then allM xs else pure false

def anyM : List Value → Except RtErr Bool
  | [] => .ok false
  | x :: xs => do if ← truth (← call f [x]) then pure true else anyM xs

def filterMapM : List Value → Except RtErr (List Value)
  | [] => .ok []
  | x :: xs => do
    let r ← call f [x]
    let rest ← filterMapM xs
    match r with
    | .variant "Option" "Some" [y] => pure (y :: rest)
    | .variant "Option" "None" [] => pure rest
    | _ => .error .stuck
end

/-- By `==`, stopping at the first equal item. -/
def memberM (y : Value) : List Value → Except RtErr Bool
  | [] => .ok false
  | x :: xs => do if ← Value.eq x y then pure true else memberM y xs

def ints : List Value → Except RtErr (List Int) := List.mapM int'

def apply : Impl := fun _P call op _targs args =>
  match op, args with
  | "List.map", [.list xs, f] => some (.list <$> xs.mapM (call f [·])) -- [P-List.map]
  | "List.filter", [.list xs, f] => some (.list <$> filterM call f xs) -- [P-List.filter]
  | "List.append", [.list xs, x] => some (.ok (.list (xs ++ [x]))) -- [P-List.append]
  | "List.concat", [.list xs, .list ys] => some (.ok (.list (xs ++ ys))) -- [P-List.concat]
  | "List.length", [.list xs] => some (.ok (.int xs.length)) -- [P-List.length]
  | "List.is_empty", [.list xs] => some (.ok (.bool xs.isEmpty)) -- [P-List.is_empty]
  | "List.foldl", [.list xs, init, f] => -- [P-List.foldl]
    some (xs.foldlM (fun acc x => call f [x, acc]) init)
  | "List.sum", [.list xs] => -- [P-List.sum]
    some do
      let ns ← ints xs
      pure (.int (ns.foldl (· + ·) 0))
  | "List.maximum", [.list xs] => -- [P-List.maximum]
    some do
      let ns ← ints xs
      pure (option' ((ns.foldl (fun best n => some (match best with | some m => max m n | none => n)) none).map .int))
  | "List.minimum", [.list xs] => -- [P-List.minimum]
    some do
      let ns ← ints xs
      pure (option' ((ns.foldl (fun best n => some (match best with | some m => min m n | none => n)) none).map .int))
  | "List.reverse", [.list xs] => some (.ok (.list xs.reverse)) -- [P-List.reverse]
  | "List.member", [.list xs, y] => some (.bool <$> memberM y xs) -- [P-List.member]
  | "List.all", [.list xs, f] => some (.bool <$> allM call f xs) -- [P-List.all]
  | "List.any", [.list xs, f] => some (.bool <$> anyM call f xs) -- [P-List.any]
  | "List.head", [.list xs] => some (.ok (option' xs.head?)) -- [P-List.head]
  | "List.take", [.list xs, .int n] => some (.ok (.list (xs.take n.toNat))) -- [P-List.take]
  | "List.drop", [.list xs, .int n] => some (.ok (.list (xs.drop n.toNat))) -- [P-List.drop]
  | "List.filter_map", [.list xs, f] => some (.list <$> filterMapM call f xs) -- [P-List.filter_map]
  | "List.sort_by", [.list xs, f] => -- [P-List.sort_by]
    some do
      let keys ← xs.mapM fun x => do int' (← call f [x])
      let sorted := (keys.zip xs).mergeSort (fun p q => decide (p.1 ≤ q.1))
      pure (.list (sorted.map (·.2)))
  | _, _ => if (sigs.lookup op).isSome then some (.error .stuck) else none

end Nobi.Prim.List
