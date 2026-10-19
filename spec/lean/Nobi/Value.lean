import Nobi.Syntax

/-!
# Values, equality and order

`spec/semantics.md`, § Values and § Equality and order.
-/

namespace Nobi

/-- An environment: the innermost binding of a name comes first. -/
abbrev Env (α : Type) := List (String × α)

/-- Runtime values. A map's entries are sorted by `Value.cmp` with unique
keys; a record's fields are sorted by name. `closure` captures its whole
environment. -/
inductive Value where
  | int (n : Int)
  | str (s : String)
  | bool (b : Bool)
  | unit
  | uuid (s : String)
  | tuple (items : List Value)
  | list (items : List Value)
  | map (entries : List (Value × Value))
  | record (model : String) (fields : List (String × Value))
  | variant (owner ctor : String) (args : List Value)
  | closure (env : List (String × Value)) (params : List (String × Ty)) (body : Expr)
  | defRef (g : String)
  | ctorRef (owner ctor : String) (arity : Nat)
  /-- A stdlib function taken as a value. -/
  | primRef (op : String) (targs : List Ty)
  /-- `Cmd` values: data, nothing runs. A batch holds Cmd values; an effect
  names its stdlib function, the stored model a store effect works on, and
  its arguments, callbacks as the functions they are. -/
  | cmdNone
  | cmdBatch (cmds : List Value)
  | cmdEffect (name : String) (model : Option String) (args : List Value)
  deriving Repr, BEq, Inhabited

namespace Value

def isFn : Value → Bool
  | .closure .. | .defRef _ | .ctorRef .. | .primRef .. => true
  | _ => false

/-! ## Weight

A value's weight is what walking it whole costs (`rt.ex` `weight/2`): one
step per node, a string one more per 64 bytes. Record field names and
variant names cost nothing. A closure is one step: its environment is never
walked. A `Cmd` is one step plus its effects' arguments. -/

/-- The most steps one walk may take. -/
def budget : Nat := 1000000

mutual
/-- `acc` plus `v`'s weight, stopping once it reaches `cap`. -/
def weightAcc (cap : Nat) : Value → Nat → Nat
  | v, acc =>
    if acc ≥ cap then acc else
    match v with
    | .str s => acc + 1 + s.utf8ByteSize / 64
    | .tuple xs => weightList cap xs (acc + 1)
    | .list xs => weightList cap xs (acc + 1)
    | .map es => weightPairs cap es (acc + 1)
    | .record _ fs => weightFields cap fs (acc + 1)
    | .variant _ _ xs => weightList cap xs (acc + 1)
    | .cmdBatch cs => weightBareList cap cs (acc + 1)
    | .cmdEffect _ _ xs => weightList cap xs (acc + 1)
    | _ => acc + 1

/-- A command inside a batch is held bare: it costs only its arguments. -/
def weightBare (cap : Nat) : Value → Nat → Nat
  | .cmdBatch cs, acc => weightBareList cap cs acc
  | .cmdEffect _ _ xs, acc => weightList cap xs acc
  | _, acc => acc

def weightBareList (cap : Nat) : List Value → Nat → Nat
  | [], acc => acc
  | c :: cs, acc => weightBareList cap cs (weightBare cap c acc)

def weightList (cap : Nat) : List Value → Nat → Nat
  | [], acc => acc
  | x :: xs, acc => weightList cap xs (weightAcc cap x acc)

def weightPairs (cap : Nat) : List (Value × Value) → Nat → Nat
  | [], acc => acc
  | (k, v) :: es, acc => weightPairs cap es (weightAcc cap v (weightAcc cap k acc))

def weightFields (cap : Nat) : List (String × Value) → Nat → Nat
  | [], acc => acc
  | (_, v) :: fs, acc => weightFields cap fs (weightAcc cap v acc)
end

/-- `v`'s weight, or `budget + 1` when it is more than the budget. -/
def weight (v : Value) : Nat := min (weightAcc (budget + 1) v 0) (budget + 1)

/-! ## Equality

Structural. A closure equals nothing, itself included; a def taken as a
value equals only the same def; a constructor only the same constructor; a
stdlib function only the same function, except a store form, which is
built as a closure (`codegen/expr.ex` `store_value/3`) and equals nothing. -/

/-- The stdlib functions that work on a stored model. -/
def isStoreForm (op : String) : Bool :=
  ["Cmd.store.insert", "Cmd.store.list", "Cmd.store.get", "Cmd.store.update",
    "Cmd.store.delete"].contains op

mutual
def same : Value → Value → Bool
  | .int a, .int b => a == b
  | .str a, .str b => a == b
  | .bool a, .bool b => a == b
  | .unit, .unit => true
  | .uuid a, .uuid b => a == b
  | .tuple xs, .tuple ys => sameList xs ys
  | .list xs, .list ys => sameList xs ys
  | .map xs, .map ys => samePairs xs ys
  | .record m fs, .record n gs => m == n && sameFields fs gs
  | .variant o c xs, .variant p d ys => o == p && c == d && sameList xs ys
  | .defRef f, .defRef g => f == g
  | .ctorRef o c k, .ctorRef p d j => o == p && c == d && k == j
  | .primRef o _, .primRef p _ => o == p && !isStoreForm o
  | .cmdNone, .cmdNone => true
  | .cmdBatch xs, .cmdBatch ys => sameList xs ys
  | .cmdEffect n m xs, .cmdEffect o p ys => n == o && m == p && sameList xs ys
  | _, _ => false

def sameList : List Value → List Value → Bool
  | [], [] => true
  | x :: xs, y :: ys => same x y && sameList xs ys
  | _, _ => false

def samePairs : List (Value × Value) → List (Value × Value) → Bool
  | [], [] => true
  | (k, v) :: xs, (l, w) :: ys => same k l && same v w && samePairs xs ys
  | _, _ => false

def sameFields : List (String × Value) → List (String × Value) → Bool
  | [], [] => true
  | (f, v) :: xs, (g, w) :: ys => f == g && same v w && sameFields xs ys
  | _, _ => false
end

/-- Pairs `==` compares without walking them: an Int or a Bool on either
side, two strings, two Uuids or two functions. -/
def uncharged : Value → Value → Bool
  | .int _, _ | .bool _, _ | _, .int _ | _, .bool _ => true
  | .str _, .str _ | .uuid _, .uuid _ => true
  | a, b => a.isFn && b.isFn

/-- `==`: `weight` when both sides weigh more than the budget. -/
def eq (a b : Value) : Except RtErr Bool :=
  if uncharged a b then .ok (same a b)
  else if min a.weight b.weight > budget then .error .weight
  else .ok (same a b)

/-! ## Order

First by kind, then structurally (`rt.ex` `compare/2`). Only map keys are
ever compared, and keys hold no functions, so the order among functions is
unspecified beyond their kind: closures, then defs, then constructors. -/

/-- Kind ranks: Int < String < Bool < Uuid < List < Map < tuple < record <
variant < function < Cmd. Unit is the empty tuple. -/
def rank : Value → Nat
  | .int _ => 0
  | .str _ => 1
  | .bool _ => 2
  | .uuid _ => 3
  | .list _ => 4
  | .map _ => 5
  | .tuple _ | .unit => 6
  | .record .. => 7
  | .variant .. => 8
  | .closure .. | .defRef _ | .ctorRef .. | .primRef .. => 9
  | .cmdNone | .cmdBatch _ | .cmdEffect .. => 10

/-- Within functions: closures, then defs (the stdlib's among them), then
constructors. Within Cmds: none, then batch, then effect. -/
def subRank : Value → Nat
  | .defRef _ | .primRef .. | .cmdBatch _ => 1
  | .ctorRef .. | .cmdEffect .. => 2
  | _ => 0

/-- A store effect's model: none before some. -/
def cmpModel : Option String → Option String → Ordering
  | none, none => .eq
  | none, some _ => .lt
  | some _, none => .gt
  | some a, some b => compare a b

mutual
def cmp : Value → Value → Ordering
  | .int a, .int b => compare a b
  | .str a, .str b => compare a b
  | .bool a, .bool b => compare a b
  | .uuid a, .uuid b => compare a b
  | .list xs, .list ys => cmpList xs ys
  | .map xs, .map ys => cmpPairs xs ys
  | .tuple xs, .tuple ys => cmpList xs ys
  | .unit, .unit => .eq
  | .unit, .tuple _ => .lt
  | .tuple _, .unit => .gt
  | .record m fs, .record n gs => (compare m n).then (cmpFields fs gs)
  | .variant o c xs, .variant p d ys => (compare o p).then ((compare c d).then (cmpList xs ys))
  | .defRef f, .defRef g => compare f g
  | .ctorRef o c k, .ctorRef p d j => (compare o p).then ((compare c d).then (compare k j))
  | .primRef o _, .primRef p _ => compare o p
  | .cmdBatch xs, .cmdBatch ys => cmpList xs ys
  | .cmdEffect n m xs, .cmdEffect o p ys =>
    (compare n o).then ((cmpModel m p).then (cmpList xs ys))
  | a, b => (compare a.rank b.rank).then (compare a.subRank b.subRank)

def cmpList : List Value → List Value → Ordering
  | [], [] => .eq
  | [], _ :: _ => .lt
  | _ :: _, [] => .gt
  | x :: xs, y :: ys => (cmp x y).then (cmpList xs ys)

def cmpPairs : List (Value × Value) → List (Value × Value) → Ordering
  | [], [] => .eq
  | [], _ :: _ => .lt
  | _ :: _, [] => .gt
  | (k, v) :: xs, (l, w) :: ys => (cmp k l).then ((cmp v w).then (cmpPairs xs ys))

def cmpFields : List (String × Value) → List (String × Value) → Ordering
  | [], [] => .eq
  | [], _ :: _ => .lt
  | _ :: _, [] => .gt
  | (f, v) :: xs, (g, w) :: ys => (compare f g).then ((cmp v w).then (cmpFields xs ys))
end

/-! ## Maps and records -/

/-- The least `k` with `2^k ≥ n`. -/
def ceilLog2 (n : Nat) : Nat := if n ≤ 1 then 0 else Nat.log2 (n - 1) + 1

/-- Hashing `key` into a map of `len` keys compares it with up to
`⌈log2(len + 1)⌉ + 1` keys; past the budget that is `weight`. An Int or Bool
key costs nothing. -/
def chargeInsertion (key : Value) (len : Nat) : Except RtErr Unit :=
  match key with
  | .int _ | .bool _ => .ok ()
  | _ => if key.weight * (ceilLog2 (len + 1) + 1) > budget then .error .weight else .ok ()

/-- `es` with `k` set to `v`, in key order. -/
def mapInsert (k v : Value) : List (Value × Value) → List (Value × Value)
  | [] => [(k, v)]
  | (k', v') :: rest =>
    match cmp k k' with
    | .lt => (k, v) :: (k', v') :: rest
    | .eq => (k, v) :: rest
    | .gt => (k', v') :: mapInsert k v rest

/-- A map literal's pairs, in order: each key charged, a later key's value
replacing an earlier one's. -/
def mapFromList : List (Value × Value) → List (Value × Value) → Except RtErr (List (Value × Value))
  | acc, [] => .ok acc
  | acc, (k, v) :: rest => do
    chargeInsertion k acc.length
    mapFromList (mapInsert k v acc) rest

/-- `fs` with field `f` set to `v`, in name order. -/
def setField (f : String) (v : Value) : List (String × Value) → List (String × Value)
  | [] => [(f, v)]
  | (g, w) :: rest =>
    match compare f g with
    | .lt => (f, v) :: (g, w) :: rest
    | .eq => (f, v) :: rest
    | .gt => (g, w) :: setField f v rest

end Value

end Nobi
