import Nobi.Value

/-!
# Operators

`spec/semantics.md`, § Operators and § Equality and order. Surface operators
lower to `prim` with these names: `+ - * /` and `neg` on Int (exact,
§ Numbers), `< > <= >=` on Int, `++` on String, `not` on Bool, and `==` at
any type. `!=`, `and` and `or` are not primitives: `!=` lowers to
`not (== …)`, `and`/`or` to a `case` (they short-circuit).
-/

namespace Nobi.Prim

/-- A primitive's signature: its type parameters, parameter types and result. -/
structure Sig where
  tparams : List String := []
  params : List Ty
  ret : Ty
  deriving Repr, BEq

def opSigs : List (String × Sig) :=
  [ ("+", { params := [.int, .int], ret := .int }),
    ("-", { params := [.int, .int], ret := .int }),
    ("*", { params := [.int, .int], ret := .int }),
    ("/", { params := [.int, .int], ret := .int }),
    ("neg", { params := [.int], ret := .int }),
    ("<", { params := [.int, .int], ret := .bool }),
    (">", { params := [.int, .int], ret := .bool }),
    ("<=", { params := [.int, .int], ret := .bool }),
    (">=", { params := [.int, .int], ret := .bool }),
    ("++", { params := [.str, .str], ret := .str }),
    ("not", { params := [.bool], ret := .bool }),
    ("==", { tparams := ["a"], params := [.var "a", .var "a"], ret := .bool }) ]

/-- An operator applied to its evaluated arguments; `none` for a name that is
no operator. A value of the wrong shape is `stuck`. -/
def applyOp : String → List Value → Option (Except RtErr Value)
  | "+", [.int a, .int b] => some (.ok (.int (a + b))) -- [P-add]
  | "-", [.int a, .int b] => some (.ok (.int (a - b))) -- [P-sub]
  | "*", [.int a, .int b] => some (.ok (.int (a * b))) -- [P-mul]
  | "/", [.int a, .int b] => -- [P-div]
    some (if b == 0 then .error .divZero else .ok (.int (Int.tdiv a b)))
  | "neg", [.int a] => some (.ok (.int (-a))) -- [P-neg]
  | "<", [.int a, .int b] => some (.ok (.bool (decide (a < b)))) -- [P-lt]
  | ">", [.int a, .int b] => some (.ok (.bool (decide (a > b)))) -- [P-gt]
  | "<=", [.int a, .int b] => some (.ok (.bool (decide (a ≤ b)))) -- [P-le]
  | ">=", [.int a, .int b] => some (.ok (.bool (decide (a ≥ b)))) -- [P-ge]
  | "++", [.str a, .str b] => some (.ok (.str (a ++ b))) -- [P-concat]
  | "not", [.bool b] => some (.ok (.bool !b)) -- [P-not]
  | "==", [a, b] => some (.bool <$> Value.eq a b) -- [P-eq]
  | op, _ => if (opSigs.lookup op).isSome then some (.error .stuck) else none

end Nobi.Prim
