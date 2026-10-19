import Nobi.Value

/-!
# Operators

`spec/semantics.md`, § Operators and § Equality and order. Surface operators
lower to `prim` with these names: `+ - * /` and `neg` on Int (checked i64,
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
  | "+", [.int a, .int b] => some (.int <$> I64.add a b) -- [P-add]
  | "-", [.int a, .int b] => some (.int <$> I64.sub a b) -- [P-sub]
  | "*", [.int a, .int b] => some (.int <$> I64.mul a b) -- [P-mul]
  | "/", [.int a, .int b] => some (.int <$> I64.div a b) -- [P-div]
  | "neg", [.int a] => some (.int <$> I64.neg a) -- [P-neg]
  | "<", [.int a, .int b] => some (.ok (.bool (decide (a < b)))) -- [P-lt]
  | ">", [.int a, .int b] => some (.ok (.bool (decide (a > b)))) -- [P-gt]
  | "<=", [.int a, .int b] => some (.ok (.bool (decide (a ≤ b)))) -- [P-le]
  | ">=", [.int a, .int b] => some (.ok (.bool (decide (a ≥ b)))) -- [P-ge]
  | "++", [.str a, .str b] => some (.ok (.str (a ++ b))) -- [P-concat]
  | "not", [.bool b] => some (.ok (.bool !b)) -- [P-not]
  | "==", [a, b] => some (.bool <$> Value.eq a b) -- [P-eq]
  | op, _ => if (opSigs.lookup op).isSome then some (.error .stuck) else none

end Nobi.Prim
