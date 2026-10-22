import Nobi

/-!
Hand-translated corpus programs: `test/fixtures/nobi/counter.nobi` and
`split.nobi`, as the lowering would write them, checked against the answers
in `test/fixtures/nobi/eval/corpus.json` and the files' own `deftest`s
(`always` is outside core, so each assertion is an entry here).
-/

open Nobi

namespace Tests.Corpus

def v (x : String) : Expr := .var x
def i (n : Int) : Expr := .int n
def s (x : String) : Expr := .str x
def p (op : String) (targs : List Ty) (args : List Expr) : Expr := .prim op targs args
/-- `if c do a else b end`, as lowered. -/
def ifE (c a b : Expr) : Expr := .case c [(.bool true, a), (.wild, b)]
def text (x : String) : Value := .variant "Html" "Text" [.str x]
def el (tag : String) (attrs : List (String × Value)) (children : List Value) : Value :=
  .variant "Html" "Element" [.str tag, .list (attrs.map fun a => .tuple [.str a.1, a.2]), .list children]

/-! ## counter.nobi -/

def model : Ty := .named "Counter.Model" []
def msg : Ty := .named "Counter.Msg" []
def count : Expr := .field (v "model") "count"
def setCount (e : Expr) : Expr := .update "Counter.Model" (v "model") [("count", e)]
def cmdNone : Expr := p "Cmd.none" [msg] []
def m (c : String) (args : List Expr := []) : Expr := .ctor "Counter.Msg" c [] args

def counter : Prog :=
  { models := [{ name := "Counter.Model", fields := [("count", .int)] }],
    types := [{ name := "Counter.Msg", params := [],
                variants := [("Increment", []), ("Decrement", []), ("Add", [.int])] }],
    defs := [
      { name := "Counter.init", params := [], ret := .tuple [model, .cmd msg],
        body := .tuple [.construct "Counter.Model" [("count", i 0)], cmdNone] },
      { name := "Counter.update", params := [("msg", msg), ("model", model)], ret := .tuple [model, .cmd msg],
        body :=
          .letIn "next" (.case (v "msg") [
            (.variant "Counter.Msg" "Increment" [], setCount (p "+" [] [count, i 1])),
            (.variant "Counter.Msg" "Decrement" [],
              ifE (p ">" [] [count, i 0]) (setCount (p "-" [] [count, i 1])) (v "model")),
            (.variant "Counter.Msg" "Add" [.var "n"],
              ifE (p ">=" [] [p "+" [] [count, v "n"], i 0]) (setCount (p "+" [] [count, v "n"])) (v "model"))])
          (.tuple [v "next", cmdNone]) },
      { name := "Counter.view", params := [("model", model)], ret := .html msg,
        body := .element msg "div" [("class", s "counter")] [
          .element msg "button" [("on-click", m "Decrement")] [s "-"],
          .element msg "span" [] [count],
          .element msg "button" [("on-click", m "Increment")] [s "+"],
          .element msg "button" [("on-click", m "Add" [i 10])] [s "+10"]] },
      { name := "Counter.e_init", params := [], ret := .tuple [model, .cmd msg],
        body := .callDef "Counter.init" [] },
      { name := "Counter.e_update", params := [], ret := .tuple [model, .cmd msg],
        body := .callDef "Counter.update" [m "Decrement", .construct "Counter.Model" [("count", i 95)]] },
      { name := "Counter.e_view", params := [], ret := .html msg,
        body := .callDef "Counter.view" [.construct "Counter.Model" [("count", i 2)]] }] }

def countRec (n : Int) : Value := .record "Counter.Model" [("count", .int n)]
def msgV (c : String) (args : List Value := []) : Value := .variant "Counter.Msg" c args

#guard (Typing.checkProgram counter).toBool
#guard Eval.runEntry counter "Counter.e_init" == .ok (.tuple [countRec 0, .cmdNone])
#guard Eval.runEntry counter "Counter.e_update" == .ok (.tuple [countRec 94, .cmdNone])
#guard Eval.runEntry counter "Counter.e_view" == .ok
  (el "div" [("class", .str "counter")] [
    el "button" [("on-click", msgV "Decrement")] [text "-"],
    el "span" [] [text "2"],
    el "button" [("on-click", msgV "Increment")] [text "+"],
    el "button" [("on-click", msgV "Add" [.int 10])] [text "+10"]])
#guard (Eval.runEntry counter "Counter.e_view").toOption.map (·.conforms counter (.html msg)) == some true

/-! ## split.nobi (its pure defs and their tests) -/

def expense : Ty := .named "Split.Expense" []
def expenses : Ty := .list expense
def fnE (body : Expr) : Expr := .lam [("e", expense)] body

def split : Prog :=
  { models := [{ name := "Split.Expense",
                 fields := [("id", .uuid), ("payer", .str), ("what", .str), ("cents", .int)] }],
    defs := [
      { name := "Split.payers", params := [("expenses", expenses)], ret := .list .str,
        body := p "List.foldl" [expense, .list .str] [v "expenses", .list .str [],
          .lam [("e", expense), ("acc", .list .str)]
            (ifE (p "List.member" [.str] [v "acc", .field (v "e") "payer"])
              (v "acc") (p "List.append" [.str] [v "acc", .field (v "e") "payer"]))] },
      { name := "Split.total", params := [("expenses", expenses)], ret := .int,
        body := p "List.sum" [] [p "List.map" [expense, .int] [v "expenses", fnE (.field (v "e") "cents")]] },
      { name := "Split.paid_by", params := [("expenses", expenses), ("who", .str)], ret := .int,
        body := .callDef "Split.total" [p "List.filter" [expense] [v "expenses",
          fnE (p "==" [.str] [.field (v "e") "payer", v "who"])]] },
      { name := "Split.balance", params := [("expenses", expenses), ("who", .str)], ret := .int,
        body :=
          .letIn "share" (p "/" [] [.callDef "Split.total" [v "expenses"],
              p "List.length" [.str] [.callDef "Split.payers" [v "expenses"]]])
          (p "-" [] [v "share", .callDef "Split.paid_by" [v "expenses", v "who"]]) },
      { name := "Split.money", params := [("cents", .int)], ret := .str,
        body :=
          .letIn "sign" (ifE (p "<" [] [v "cents", i 0]) (s "-") (s ""))
          (.letIn "n" (ifE (p "<" [] [v "cents", i 0]) (p "-" [] [i 0, v "cents"]) (v "cents"))
          (.letIn "whole" (p "/" [] [v "n", i 100])
          (.letIn "rest" (p "-" [] [v "n", p "*" [] [v "whole", i 100]])
          (.letIn "pad" (ifE (p "<" [] [v "rest", i 10]) (s "0") (s ""))
          (p "++" [] [p "++" [] [p "++" [] [p "++" [] [v "sign", p "String.from_int" [] [v "whole"]],
            s "."], v "pad"], p "String.from_int" [] [v "rest"]]))))) }] }

def ex (payer what : String) (cents : Int) : Expr :=
  .construct "Split.Expense" [("payer", s payer), ("what", s what), ("cents", i cents)]
def trip : Expr :=
  .list expense [ex "ana" "lift pass" 6000, ex "bo" "fondue" 3000, ex "ana" "wax" 1200]

def run (e : Expr) : Except RtErr Value := Eval.eval split 1000 [] e
def typed (e : Expr) (t : Ty) : Bool := Typing.typeOf split [] e == .ok t

#guard (Typing.checkProgram split).toBool
-- corpus.json calls
#guard run (.callDef "Split.payers" [.list expense []]) == .ok (.list [])
#guard run (.callDef "Split.total" [.list expense []]) == .ok (.int 0)
#guard run (.callDef "Split.paid_by" [.list expense [], s "猫"]) == .ok (.int 0)
#guard run (.callDef "Split.balance" [.list expense [], s "猫"]) == .error .divZero
#guard run (.callDef "Split.money" [i 2]) == .ok (.str "0.02")
-- deftest Split.money_prints_cents
#guard run (.callDef "Split.money" [i 0]) == .ok (.str "0.00")
#guard run (.callDef "Split.money" [i 5]) == .ok (.str "0.05")
#guard run (.callDef "Split.money" [i 250]) == .ok (.str "2.50")
#guard run (.callDef "Split.money" [i 1234]) == .ok (.str "12.34")
#guard run (.callDef "Split.money" [p "-" [] [i 0, i 250]]) == .ok (.str "-2.50")
#guard run (.callDef "Split.money" [p "-" [] [i 0, i 5]]) == .ok (.str "-0.05")
-- deftest Split.splits_what_was_paid
#guard typed (.callDef "Split.total" [trip]) .int
#guard run (.callDef "Split.total" [trip]) == .ok (.int 10200)
#guard run (.callDef "Split.payers" [trip]) == .ok (.list [.str "ana", .str "bo"])
#guard run (.callDef "Split.paid_by" [trip, s "ana"]) == .ok (.int 7200)
#guard run (.callDef "Split.balance" [trip, s "ana"]) == .ok (.int (-2100))
#guard run (.callDef "Split.balance" [trip, s "bo"]) == .ok (.int 2100)
-- deftest Split.handles_an_empty_trip
#guard run (.callDef "Split.money" [.callDef "Split.total" [.list expense []]]) == .ok (.str "0.00")

end Tests.Corpus
