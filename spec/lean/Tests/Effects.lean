import Nobi

/-! `Cmd` and `Html` as data: `[T-PrimRef]`, `[E-PrimRef]`, `[T-Element]`,
`[E-Element]`, `[P-Cmd.none]`, `[P-Cmd.batch]`, `[P-Cmd.effect]`. -/

open Nobi

namespace Tests.Effects

def row : Ty := .named "E.Row" []
def msg : Ty := .named "E.Msg" []

def prog : Prog :=
  { models := [{ name := "E.Row", fields := [("id", .uuid), ("n", .int)] }],
    types := [{ name := "E.Msg", params := [], variants := [("Got", [.uuid]), ("Typed", [.str]), ("Go", [])] }] }

def ty (e : Expr) : Except TyErr Ty := Typing.typeOf prog [] e
def ev (e : Expr) : Except RtErr Value := Eval.eval prog 100 [] e
def code (e : Expr) : String :=
  match ty e with
  | .error err => err.code
  | .ok _ => "ok"

def got : Expr := .ctorRef "E.Msg" "Got" []
def go : Expr := .ctor "E.Msg" "Go" [] []
def insert : Expr :=
  .prim "Cmd.store.insert" [row, msg] [.construct "E.Row" [("n", .int 1)], got]

-- [P-Cmd.none] [P-Cmd.batch]: a batch holds commands as given.
#guard ty (.prim "Cmd.none" [msg] []) == .ok (.cmd msg)
#guard ev (.prim "Cmd.none" [msg] []) == .ok .cmdNone
#guard ev (.prim "Cmd.batch" [msg] [.list (.cmd msg) [.prim "Cmd.none" [msg] [], insert]]) ==
  .ok (.cmdBatch [.cmdNone, .cmdEffect "Cmd.store.insert" (some "E.Row")
    [.record "E.Row" [("n", .int 1)], .ctorRef "E.Msg" "Got" 1]])
-- [P-Cmd.effect]: a store effect names its model, its first type argument;
-- other effects name none. Nothing runs.
#guard ty insert == .ok (.cmd msg)
#guard ev (.prim "Cmd.time.now" [msg] [.lam [("t", .int)] go]) matches .ok (.cmdEffect "Cmd.time.now" none [_])
#guard code (.prim "Cmd.store.list" [.int, msg] [.lam [("rs", .list .int)] go]) == "not-a-model"
-- Commands compare structurally: none < batch < effect.
#guard ev (.prim "==" [.cmd msg] [.prim "Cmd.none" [msg] [], .prim "Cmd.none" [msg] []]) == .ok (.bool true)
#guard Value.cmp .cmdNone (.cmdBatch []) == .lt
#guard Value.cmp (.cmdBatch []) (.cmdEffect "Cmd.time.now" none []) == .lt
-- A Cmd is not data: no map key holds one.
#guard code (.map (.cmd msg) .int []) == "non-data-map-key"
#guard code (.list (.cmd (.map (.arrow [.int] .int) .int)) []) == "non-data-map-key"

-- [T-PrimRef] [E-PrimRef]
#guard ty (.primRef "List.length" [.int]) == .ok (.arrow [.list .int] .int)
#guard ev (.app (.primRef "List.length" [.int]) [.list .int [.int 1]]) == .ok (.int 1)
#guard code (.primRef "Nope.nope" []) == "unbound"
-- A store form taken as a value is a closure on the BEAM: it equals nothing.
#guard ev (.prim "==" [.arrow [.uuid] msg] [.primRef "Cmd.store.insert" [row, msg], .primRef "Cmd.store.insert" [row, msg]]) == .ok (.bool false)

-- [T-Element] [E-Element]: attributes, then children, left to right; children
-- spliced (lists flattened, scalars as text).
def view : Expr :=
  .element msg "form" [("class", .str "f"), ("on-submit", go)] [
    .str "hi",
    .int 3,
    .list (.html msg) [.element msg "input" [("on-change", .ctorRef "E.Msg" "Typed" [])] []]]
def text (x : String) : Value := .variant "Html" "Text" [.str x]
#guard ty view == .ok (.html msg)
#guard ev view == .ok (.variant "Html" "Element" [.str "form",
  .list [.tuple [.str "class", .str "f"], .tuple [.str "on-submit", .variant "E.Msg" "Go" []]],
  .list [text "hi", text "3",
    .variant "Html" "Element" [.str "input",
      .list [.tuple [.str "on-change", .ctorRef "E.Msg" "Typed" 1]], .list []]]])
#guard (ev view).toOption.map (·.conforms prog (.html msg)) == some true
#guard code (.element msg "div" [("on-input", go)] []) == "bad-event"
#guard code (.element msg "div" [("on-submit", go)] []) == "bad-event"
#guard code (.element msg "div" [("on-change", .ctorRef "E.Msg" "Typed" [])] []) == "bad-event"
#guard code (.element msg "input" [("on-change", got)] []) == "bad-event"
#guard code (.element msg "div" [("on-click", .int 1)] []) == "bad-event"
#guard code (.element msg "div" [("title", .list .int [])] []) == "mismatch"
#guard code (.element msg "div" [] [.bool true]) == "mismatch"

end Tests.Effects
