import Nobi.Prim.Ops

/-! # Uuid

`spec/semantics.md`, § Stdlib: Uuid. `rt/stdlib.ex` L393-407. -/

namespace Nobi.Prim.Uuid

def sigs : List (String × Sig) :=
  [ ("Uuid.to_string", { params := [.uuid], ret := .str }),
    ("Uuid.parse", { params := [.str], ret := optT .uuid }) ]

def isHex (c : Char) : Bool := c.isDigit || ('a' ≤ c && c ≤ 'f')

/-- `8-4-4-4-12` lowercase hex digits. -/
def canonical (cs : List Char) : Bool :=
  cs.length == 36 &&
    (cs.zipIdx.all fun (c, i) => if [8, 13, 18, 23].contains i then c == '-' else isHex c)

/-- A UUID in any case, kept lowercase. Only ASCII letters change case: no
other character lowercases to a hex digit. -/
def parse (s : String) : Option String :=
  let down := s.toList.map Char.toLower
  if canonical down then some (String.ofList down) else none

def apply : Impl := fun _P _call op _targs args =>
  match op, args with
  | "Uuid.to_string", [.uuid s] => some (.ok (.str s)) -- [P-Uuid.to_string]
  | "Uuid.parse", [.str s] => some (.ok (option' ((parse s).map .uuid))) -- [P-Uuid.parse]
  | _, _ => if (sigs.lookup op).isSome then some (.error .stuck) else none

end Nobi.Prim.Uuid
