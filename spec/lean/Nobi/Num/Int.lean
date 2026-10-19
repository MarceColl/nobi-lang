import Nobi.Syntax

/-!
# Int: checked i64 arithmetic

`spec/semantics.md`, § Numbers. An Int is a mathematical integer in
`[-2^63, 2^63)`. Every operation computes the exact result over `Int` and
fails with `overflow` when it leaves that range (`rt.ex` `checked/1`). `/`
truncates toward zero (`Int.tdiv`, Erlang `div`), so `minI64 / -1` overflows.
-/

namespace Nobi.I64

def minI64 : Int := -9223372036854775808
def maxI64 : Int := 9223372036854775807

def inRange (n : Int) : Bool := minI64 ≤ n && n ≤ maxI64

/-- `n` if it is an i64, else `overflow`. -/
def checked (n : Int) : Except RtErr Int :=
  if inRange n then .ok n else .error .overflow

def add (a b : Int) : Except RtErr Int := checked (a + b)
def sub (a b : Int) : Except RtErr Int := checked (a - b)
def mul (a b : Int) : Except RtErr Int := checked (a * b)
def neg (a : Int) : Except RtErr Int := checked (-a)

/-- Truncating division; `b = 0` is `divZero`. -/
def div (a b : Int) : Except RtErr Int :=
  if b == 0 then .error .divZero else checked (Int.tdiv a b)

end Nobi.I64
