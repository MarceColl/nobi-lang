import Nobi

/-! § Numbers, Int: the G2 table's Int rows. -/

open Nobi

/-- Evaluates a closed expression in the empty program. -/
private def ev (e : Expr) : Except RtErr Value := Eval.eval {} Eval.defaultFuel [] e

private def op (o : String) (a b : Int) : Expr := .prim o [] [.int a, .int b]

-- Domain: every integer. What was i64's edge is an ordinary value.
#guard ev (op "+" (2 ^ 63 - 1) 1) == .ok (.int (2 ^ 63))
#guard ev (op "-" (-(2 ^ 63)) 1) == .ok (.int (-(2 ^ 63) - 1))
#guard ev (op "*" (2 ^ 63) (2 ^ 63)) == .ok (.int (2 ^ 126))
#guard ev (.prim "neg" [] [.int (-(2 ^ 63))]) == .ok (.int (2 ^ 63))
#guard ev (.int (2 ^ 200)) == .ok (.int (2 ^ 200))

-- `/` truncates toward zero, in all four sign combinations.
#guard ev (op "/" 7 2) == .ok (.int 3)
#guard ev (op "/" (-7) 2) == .ok (.int (-3))
#guard ev (op "/" 7 (-2)) == .ok (.int (-3))
#guard ev (op "/" (-7) (-2)) == .ok (.int 3)
#guard ev (op "/" (-(2 ^ 63)) (-1)) == .ok (.int (2 ^ 63))
-- A zero divisor is `divZero`, the only Int error.
#guard ev (op "/" 1 0) == .error .divZero
#guard ev (op "/" 0 0) == .error .divZero

-- Comparison is numeric.
#guard ev (op "<" (-(2 ^ 100)) (2 ^ 100)) == .ok (.bool true)
#guard ev (op ">=" 3 3) == .ok (.bool true)
#guard ev (op ">" (-1) 0) == .ok (.bool false)
#guard ev (op "<=" 2 1) == .ok (.bool false)
#guard ev (op "==" (2 ^ 64) (2 ^ 64)) == .ok (.bool true)

-- Left to right: of two errors, the left one is the result.
#guard ev (.prim "+" [] [op "/" 1 0, .prim "neg" [] [.str "x"]]) == .error .divZero
#guard ev (.prim "+" [] [.prim "neg" [] [.str "x"], op "/" 1 0]) == .error .stuck

-- Mixing is a type error: there are no implicit coercions.
#guard (Typing.typeOf {} [] (.prim "+" [] [.int 1, .str "1"])).toBool == false
