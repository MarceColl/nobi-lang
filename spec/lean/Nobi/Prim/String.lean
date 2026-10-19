import Nobi.Prim.Ops

/-!
# String

`spec/semantics.md`, § Stdlib: String. `rt/stdlib.ex` L154-290. A string is
a sequence of code points: lengths, slices, splits and reversals count code
points, never bytes or graphemes.
-/

namespace Nobi.Prim.Str

def sigs : List (String × Sig) :=
  [ ("String.length", { params := [.str], ret := .int }),
    ("String.concat", { params := [.str, .str], ret := .str }),
    ("String.from_int", { params := [.int], ret := .str }),
    ("String.to_int", { params := [.str], ret := optT .int }),
    ("String.is_empty", { params := [.str], ret := .bool }),
    ("String.reverse", { params := [.str], ret := .str }),
    ("String.trim", { params := [.str], ret := .str }),
    ("String.to_upper", { params := [.str], ret := .str }),
    ("String.to_lower", { params := [.str], ret := .str }),
    ("String.contains", { params := [.str, .str], ret := .bool }),
    ("String.starts_with", { params := [.str, .str], ret := .bool }),
    ("String.split", { params := [.str, .str], ret := .list .str }),
    ("String.join", { params := [.list .str, .str], ret := .str }),
    ("String.slice", { params := [.str, .int, .int], ret := .str }) ]

/-- Strict decimal: an optional `-`, then one or more ASCII digits, within
i64. Past 19 significant digits nothing fits. -/
def toInt (s : String) : Option Int :=
  let cs := s.toList
  let (neg, ds) := match cs with
    | '-' :: rest => (true, rest)
    | _ => (false, cs)
  if ds.isEmpty || !ds.all Char.isDigit then none
  else
    let sig := ds.dropWhile (· == '0')
    if sig.length > 19 then none
    else
      let n : Int := sig.foldl (fun acc c => acc * 10 + (c.toNat - '0'.toNat)) 0
      let v := if neg then -n else n
      if I64.inRange v then some v else none

/-- Unicode's White_Space property, as `String.trim` strips it. -/
def whitespace : List Nat :=
  [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680] ++
    (List.range 11).map (0x2000 + ·) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

def isWhitespace (c : Char) : Bool := whitespace.contains c.toNat

def trim (s : String) : String :=
  String.ofList ((s.toList.dropWhile isWhitespace).reverse.dropWhile isWhitespace).reverse

/-- Whether `sub` occurs in `cs`; the empty string occurs in every string. -/
def isInfix (sub : List Char) : List Char → Bool
  | [] => sub.isEmpty
  | c :: cs => sub.isPrefixOf (c :: cs) || isInfix sub cs

/-- The pieces of `cs` between non-overlapping occurrences of `sep` (not
empty), left to right, empty pieces kept. `cur` is the piece so far,
reversed. -/
def splitOn (sep : List Char) (cs : List Char) (cur : List Char := []) : List (List Char) :=
  match cs with
  | [] => [cur.reverse]
  | c :: rest =>
    if sep.isPrefixOf (c :: rest) then cur.reverse :: splitOn sep (rest.drop (sep.length - 1))
    else splitOn sep rest (c :: cur)
termination_by cs.length
decreasing_by all_goals simp_wf; all_goals (try simp [List.length_drop]); all_goals omega

def split (s sep : String) : List String :=
  if sep.isEmpty then s.toList.map (String.singleton ·)
  else (splitOn sep.toList s.toList).map String.ofList

/-- The code points from `from` up to `to`: a negative start is the start, a
negative end counts back from the end, both stop at the ends. -/
def slice (s : String) (from_ to : Int) : String :=
  let cs := s.toList
  let len : Int := cs.length
  let start := max from_ 0 |> min len
  let stop := if to < 0 then max (len + to) 0 else min to len
  if start ≥ stop then "" else String.ofList ((cs.drop start.toNat).take (stop - start).toNat)

def strings : List Value → Except RtErr (List String) :=
  List.mapM fun
    | .str s => .ok s
    | _ => .error .stuck

def apply : Impl := fun _P _call op _targs args =>
  match op, args with
  | "String.length", [.str s] => some (.ok (.int s.length)) -- [P-String.length]
  | "String.concat", [.str a, .str b] => some (.ok (.str (a ++ b))) -- [P-String.concat]
  | "String.from_int", [.int n] => some (.ok (.str (toString n))) -- [P-String.from_int]
  | "String.to_int", [.str s] => some (.ok (option' ((toInt s).map .int))) -- [P-String.to_int]
  | "String.is_empty", [.str s] => some (.ok (.bool s.isEmpty)) -- [P-String.is_empty]
  | "String.reverse", [.str s] => some (.ok (.str (String.ofList s.toList.reverse))) -- [P-String.reverse]
  | "String.trim", [.str s] => some (.ok (.str (trim s))) -- [P-String.trim]
  | "String.to_upper", [.str s] => some (.ok (.str (String.ofList (s.toList.map Char.toUpper)))) -- [P-String.to_upper]
  | "String.to_lower", [.str s] => some (.ok (.str (String.ofList (s.toList.map Char.toLower)))) -- [P-String.to_lower]
  | "String.contains", [.str s, .str sub] => some (.ok (.bool (isInfix sub.toList s.toList))) -- [P-String.contains]
  | "String.starts_with", [.str s, .str p] => some (.ok (.bool (p.toList.isPrefixOf s.toList))) -- [P-String.starts_with]
  | "String.split", [.str s, .str sep] => some (.ok (.list ((split s sep).map .str))) -- [P-String.split]
  | "String.join", [.list parts, .str sep] => -- [P-String.join]
    some do pure (.str (sep.intercalate (← strings parts)))
  | "String.slice", [.str s, .int a, .int b] => some (.ok (.str (slice s a b))) -- [P-String.slice]
  | _, _ => if (sigs.lookup op).isSome then some (.error .stuck) else none

end Nobi.Prim.Str
