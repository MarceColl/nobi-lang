import Nobi

/-! § Numbers, Int: the G2 table's Int rows. -/

open Nobi Nobi.I64

/-- Evaluates a closed expression in the empty program. -/
private def ev (e : Expr) : Except RtErr Value := Eval.eval {} Eval.defaultFuel [] e

private def op (o : String) (a b : Int) : Expr := .prim o [] [.int a, .int b]

-- Domain: [-2^63, 2^63).
#guard minI64 == -(2 ^ 63) && maxI64 == 2 ^ 63 - 1
#guard checked maxI64 == .ok maxI64
#guard checked minI64 == .ok minI64
#guard checked (maxI64 + 1) == .error .overflow
#guard checked (minI64 - 1) == .error .overflow

-- `+ - *` and negation: the exact result, then the range check.
#guard ev (op "+" maxI64 1) == .error .overflow
#guard ev (op "+" maxI64 0) == .ok (.int maxI64)
#guard ev (.prim "-" [] [.prim "neg" [] [.int maxI64], .int 1]) == .ok (.int minI64)
#guard ev (.prim "-" [] [.prim "-" [] [.prim "neg" [] [.int maxI64], .int 1], .int 1]) == .error .overflow
#guard ev (op "*" 4611686018427387904 2) == .error .overflow
#guard ev (op "*" (-4611686018427387904) 2) == .ok (.int minI64)
#guard neg minI64 == .error .overflow
#guard neg maxI64 == .ok (-maxI64)

-- `/` truncates toward zero, in all four sign combinations.
#guard ev (op "/" 7 2) == .ok (.int 3)
#guard ev (op "/" (-7) 2) == .ok (.int (-3))
#guard ev (op "/" 7 (-2)) == .ok (.int (-3))
#guard ev (op "/" (-7) (-2)) == .ok (.int 3)
-- A zero divisor is `divZero`; `minI64 / -1` is 2^63, which overflows.
#guard ev (op "/" 1 0) == .error .divZero
#guard ev (op "/" 0 0) == .error .divZero
#guard div minI64 (-1) == .error .overflow
#guard div minI64 1 == .ok minI64

-- A literal outside the range is `overflow` (the lexer refuses one above
-- `maxI64`, so only core can write it).
#guard ev (.int (maxI64 + 1)) == .error .overflow

-- Comparison is numeric.
#guard ev (op "<" minI64 maxI64) == .ok (.bool true)
#guard ev (op ">=" 3 3) == .ok (.bool true)
#guard ev (op ">" (-1) 0) == .ok (.bool false)
#guard ev (op "<=" 2 1) == .ok (.bool false)

-- Left to right: of two errors, the left one is the result.
#guard ev (.prim "+" [] [op "/" 1 0, op "+" maxI64 1]) == .error .divZero
#guard ev (.prim "+" [] [op "+" maxI64 1, op "/" 1 0]) == .error .overflow

-- Mixing is a type error: there are no implicit coercions.
#guard (Typing.typeOf {} [] (.prim "+" [] [.int 1, .str "1"])).toBool == false
