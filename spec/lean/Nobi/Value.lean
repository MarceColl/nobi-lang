import Nobi.Syntax
import Nobi.Num.Int

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
  deriving Repr, BEq, Inhabited

namespace Value

def isFn : Value → Bool
  | .closure .. | .defRef _ | .ctorRef .. => true
  | _ => false

/-! ## Weight

A value's weight is what walking it whole costs (`rt.ex` `weight/2`): one
step per node, a string one more per 64 bytes. Record field names and
variant names cost nothing. A closure is one step: its environment is never
walked. -/

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
    | _ => acc + 1

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
value equals only the same def; a constructor only the same constructor. -/

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
variant < function. Unit is the empty tuple. -/
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
  | .closure .. | .defRef _ | .ctorRef .. => 9

def fnRank : Value → Nat
  | .defRef _ => 1
  | .ctorRef .. => 2
  | _ => 0

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
  | a, b => (compare a.rank b.rank).then (compare a.fnRank b.fnRank)

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

/-! ## Conformance

`Value.conforms P v τ`: `v` is a value of type `τ`. The runtime side of type
soundness (G3): every result of a well-typed expression must conform to its
static type. A function value conforms by its parameter types (and, for a
def or a constructor, its whole signature); a closure's body is not
re-checked here. -/

/-- Whether `id : Uuid`, the one field a record may lack (the store mints it). -/
def isIdentity (f : String) (t : Ty) : Bool := f == "id" && t == .uuid

mutual
def Value.conforms (P : Prog) : Value → Ty → Bool
  | .int _, .int | .str _, .str | .bool _, .bool | .unit, .unit | .uuid _, .uuid => true
  | .tuple vs, .tuple ts => Value.conformsAll P vs ts
  | .list vs, .list t => Value.conformsEach P vs t
  | .map es, .map k v => Value.conformsPairs P es k v
  | .record m fs, .named n [] =>
    m == n &&
      match P.findModel m with
      | some d =>
        Value.conformsFields P fs d.fields &&
          d.fields.all (fun (f, t) => fs.any (·.1 == f) || isIdentity f t)
      | none => false
  | .variant o c vs, .named n targs =>
    o == n &&
      match P.findType o with
      | some d =>
        d.params.length == targs.length &&
          match d.variant? c with
          | some args => Value.conformsAll P vs (Ty.substList (d.params.zip targs) args)
          | none => false
      | none => false
  | .closure _ ps _, .arrow qs _ => ps.map (·.2) == qs
  | .defRef g, .arrow qs r =>
    match P.findDef g with
    | some d => d.params.map (·.2) == qs && d.ret == r
    | none => false
  | .ctorRef o c k, .arrow qs (.named n targs) =>
    o == n && k == qs.length &&
      match P.findType o with
      | some d =>
        d.params.length == targs.length &&
          match d.variant? c with
          | some args => Ty.substList (d.params.zip targs) args == qs
          | none => false
      | none => false
  | _, _ => false

def Value.conformsAll (P : Prog) : List Value → List Ty → Bool
  | [], [] => true
  | v :: vs, t :: ts => Value.conforms P v t && Value.conformsAll P vs ts
  | _, _ => false

def Value.conformsEach (P : Prog) : List Value → Ty → Bool
  | [], _ => true
  | v :: vs, t => Value.conforms P v t && Value.conformsEach P vs t

def Value.conformsPairs (P : Prog) : List (Value × Value) → Ty → Ty → Bool
  | [], _, _ => true
  | (k, v) :: es, tk, tv =>
    Value.conforms P k tk && Value.conforms P v tv && Value.conformsPairs P es tk tv

def Value.conformsFields (P : Prog) : List (String × Value) → List (String × Ty) → Bool
  | [], _ => true
  | (f, v) :: fs, decl =>
    match decl.lookup f with
    | some t => Value.conforms P v t && Value.conformsFields P fs decl
    | none => false
end

end Nobi
