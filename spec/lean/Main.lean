import Nobi
import Lean.Data.Json

/-! `nobi-ref`: the reference implementation's command line. -/

open Lean (Json)
open Nobi

def usage : String :=
  "usage: nobi-ref version | prims"

/-- A type in the shape `Nobi.Lang.Types.Stdlib.signatures/0` writes it:
`{"named": n}`, `{"applied": [n, [t…]]}`, `{"var": a}`, `{"tuple": [t…]}`,
`{"arrow": [[t…], t]}`. -/
partial def tyJson : Ty → Json
  | .int => Json.mkObj [("named", "Int")]
  | .str => Json.mkObj [("named", "String")]
  | .bool => Json.mkObj [("named", "Bool")]
  | .unit => Json.mkObj [("named", "Unit")]
  | .uuid => Json.mkObj [("named", "Uuid")]
  | .tuple ts => Json.mkObj [("tuple", Json.arr (ts.map tyJson).toArray)]
  | .list t => applied "List" [t]
  | .map k v => applied "Map" [k, v]
  | .cmd m => applied "Cmd" [m]
  | .html m => applied "Html" [m]
  | .arrow ps r => Json.mkObj [("arrow", Json.arr #[Json.arr (ps.map tyJson).toArray, tyJson r])]
  | .named n [] => Json.mkObj [("named", n)]
  | .named n args => applied n args
  | .var a => Json.mkObj [("var", a)]
where
  applied (n : String) (args : List Ty) : Json :=
    Json.mkObj [("applied", Json.arr #[n, Json.arr (args.map tyJson).toArray])]

/-- Every stdlib primitive: its name and signature, for the coverage test. -/
def primsJson : Json :=
  Json.arr <| Prim.stdlibSigs.toArray.map fun (name, s) =>
    Json.mkObj [("name", name),
      ("type", Json.mkObj [("params", Json.arr (s.params.map tyJson).toArray), ("ret", tyJson s.ret)])]

def main (args : List String) : IO UInt32 := do
  match args with
  | ["version"] =>
    IO.println Nobi.specVersion
    return 0
  | ["prims"] =>
    IO.println primsJson.compress
    return 0
  | _ =>
    IO.eprintln usage
    return 2
