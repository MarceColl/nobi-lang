import Nobi

/-! At least one `#guard` per `[T-…]` and `[E-…]` rule, and per operator. -/

open Nobi

namespace Tests.Core

def shape : TypeDecl :=
  { name := "T.Shape", params := [],
    variants := [("Circle", [.int]), ("Rect", [.int, .int]), ("Dot", [])] }

def point : ModelDecl :=
  { name := "T.Point", fields := [("id", .uuid), ("x", .int), ("y", .int)] }

def shapeTy : Ty := .named "T.Shape" []
def pointTy : Ty := .named "T.Point" []
def optInt : Ty := .named "Option" [.int]

def prog : Prog :=
  { types := [shape], models := [point],
    defs := [
      { name := "T.area", params := [("s", shapeTy)], ret := .int,
        body := .case (.var "s") [
          (.variant "T.Shape" "Circle" [.var "r"], .prim "*" [] [.prim "*" [] [.int 3, .var "r"], .var "r"]),
          (.variant "T.Shape" "Rect" [.var "w", .var "h"], .prim "*" [] [.var "w", .var "h"]),
          (.variant "T.Shape" "Dot" [], .int 0)] },
      { name := "T.inc", params := [("x", .int)], ret := .int,
        body := .prim "+" [] [.var "x", .int 1] },
      { name := "T.twice", params := [("f", .arrow [.int] .int), ("x", .int)], ret := .int,
        body := .app (.var "f") [.app (.var "f") [.var "x"]] },
      { name := "T.loop", params := [("x", .int)], ret := .int,
        body := .callDef "T.loop" [.var "x"] } ] }

def ty (e : Expr) : Except TyErr Ty := Typing.typeOf prog [] e
def ev (e : Expr) : Except RtErr Value := Eval.eval prog 1000 [] e
def code (r : Except TyErr Ty) : String :=
  match r with
  | .error e => e.code
  | .ok _ => "ok"

def pt (x y : Int) : Expr := .construct "T.Point" [("x", .int x), ("y", .int y)]

-- The program itself checks.
#guard (Typing.checkProgram prog).toBool

-- [T-Int] [T-Str] [T-Bool] [T-Unit] / [E-Int] [E-Str] [E-Bool] [E-Unit]
#guard ty (.int 5) == .ok .int && ev (.int 5) == .ok (.int 5)
#guard ty (.str "猫") == .ok .str && ev (.str "猫") == .ok (.str "猫")
#guard ty (.bool true) == .ok .bool && ev (.bool true) == .ok (.bool true)
#guard ty .unit == .ok .unit && ev .unit == .ok .unit

-- [T-Var] [E-Var]: an unbound local is a type error.
#guard code (ty (.var "x")) == "unbound"
#guard Typing.typeOf prog [("x", .int)] (.var "x") == .ok .int
#guard Eval.eval prog 10 [("x", .int 2)] (.var "x") == .ok (.int 2)

-- [T-Global] [E-Global]: a def taken as a value.
#guard ty (.global "T.inc") == .ok (.arrow [.int] .int)
#guard ev (.global "T.inc") == .ok (.defRef "T.inc")

-- [T-CallDef] [E-CallDef]
#guard ty (.callDef "T.inc" [.int 1]) == .ok .int
#guard ev (.callDef "T.inc" [.int 1]) == .ok (.int 2)
#guard code (ty (.callDef "T.inc" [.str "1"])) == "mismatch"
#guard code (ty (.callDef "T.inc" [])) == "arity"
-- Recursion that never ends runs out of fuel: inconclusive, not an error of the program.
#guard ev (.callDef "T.loop" [.int 1]) == .error .fuel

-- [T-App] [E-App] [T-Lam] [E-Lam]: a closure, a def and a constructor as function values.
def incFn : Expr := .lam [("n", .int)] (.prim "+" [] [.var "n", .int 1])
#guard ty incFn == .ok (.arrow [.int] .int)
#guard ty (.callDef "T.twice" [incFn, .int 5]) == .ok .int
#guard ev (.callDef "T.twice" [incFn, .int 5]) == .ok (.int 7)
#guard ev (.callDef "T.twice" [.global "T.inc", .int 5]) == .ok (.int 7)
#guard ev (.app incFn [.int 1]) == .ok (.int 2)
#guard code (ty (.app (.int 1) [])) == "not-a-function"
#guard code (ty (.lam [("n", .int), ("n", .int)] (.var "n"))) == "bad-name"
-- A closure captures its environment.
#guard ev (.letIn "k" (.int 10) (.app (.lam [("n", .int)] (.prim "+" [] [.var "n", .var "k"])) [.int 1])) == .ok (.int 11)

-- [T-Let] [E-Let]: shadowing, and a local may hold a function.
#guard ev (.letIn "x" (.int 1) (.letIn "x" (.int 2) (.var "x"))) == .ok (.int 2)
#guard ty (.letIn "x" (.int 1) (.var "x")) == .ok .int
#guard ty (.letIn "f" incFn (.app (.var "f") [.int 1])) == .ok .int
#guard ev (.letIn "f" incFn (.app (.var "f") [.int 1])) == .ok (.int 2)

-- [T-Seq] [E-Seq]: the first value is dropped, its error is not.
#guard ty (.seq (.str "a") (.int 1)) == .ok .int
#guard ev (.seq (.str "a") (.int 1)) == .ok (.int 1)
#guard ev (.seq (.prim "/" [] [.int 1, .int 0]) (.int 1)) == .error .divZero

-- [T-Prim] [E-Prim] and every operator: [P-add] [P-sub] [P-mul] [P-div] [P-neg]
-- [P-lt] [P-gt] [P-le] [P-ge] [P-concat] [P-not] [P-eq]
#guard ev (.prim "+" [] [.int 2, .int 3]) == .ok (.int 5)
#guard ev (.prim "-" [] [.int 2, .int 3]) == .ok (.int (-1))
#guard ev (.prim "*" [] [.int 2, .int 3]) == .ok (.int 6)
#guard ev (.prim "/" [] [.int 7, .int 2]) == .ok (.int 3)
#guard ev (.prim "neg" [] [.int 2]) == .ok (.int (-2))
#guard ev (.prim "<" [] [.int 2, .int 3]) == .ok (.bool true)
#guard ev (.prim ">" [] [.int 2, .int 3]) == .ok (.bool false)
#guard ev (.prim "<=" [] [.int 3, .int 3]) == .ok (.bool true)
#guard ev (.prim ">=" [] [.int 2, .int 3]) == .ok (.bool false)
#guard ev (.prim "++" [] [.str "ab", .str "c"]) == .ok (.str "abc")
#guard ev (.prim "not" [] [.bool true]) == .ok (.bool false)
#guard ty (.prim "==" [.str] [.str "a", .str "a"]) == .ok .bool
#guard ev (.prim "==" [.str] [.str "a", .str "a"]) == .ok (.bool true)
#guard code (ty (.prim "==" [.str] [.str "a", .int 1])) == "mismatch"
#guard code (ty (.prim "==" [] [.str "a", .str "a"])) == "arity"
#guard code (ty (.prim "nope" [] [])) == "unbound"
#guard code (ty (.prim "++" [] [.int 1, .int 2])) == "mismatch"

-- Equality is structural; maps compare by content; a closure equals nothing,
-- itself included; a def equals only itself.
#guard ev (.prim "==" [.list .int] [.list .int [.int 1, .int 2], .list .int [.int 1, .int 2]]) == .ok (.bool true)
#guard ev (.prim "==" [.map .int .str]
    [.map .int .str [(.int 2, .str "b"), (.int 1, .str "a")],
     .map .int .str [(.int 1, .str "a"), (.int 2, .str "b")]]) == .ok (.bool true)
#guard ev (.prim "==" [.arrow [.int] .int] [incFn, incFn]) == .ok (.bool false)
#guard ev (.prim "==" [.arrow [.int] .int] [.global "T.inc", .global "T.inc"]) == .ok (.bool true)
#guard ev (.prim "==" [.arrow [.int] .int] [.global "T.inc", incFn]) == .ok (.bool false)
#guard ev (.prim "==" [.arrow [.int] optInt] [.ctorRef "Option" "Some" [.int], .ctorRef "Option" "Some" [.int]]) == .ok (.bool true)

-- The walk budget: `x20` shares its halves, so it is 21 nodes in memory but
-- weighs over 4 million steps; comparing it is `weight`, as on the BEAM.
def heavy (k : Nat) (body : Expr) : Expr :=
  .letIn "x0" (.list .int [.int 1, .int 1]) ((List.range k).foldr
    (fun i acc => .letIn s!"x{i + 1}" (.list .int [.var s!"x{i}", .var s!"x{i}"]) acc) body)
#guard ev (heavy 20 (.prim "==" [.int] [.var "x20", .var "x20"])) == .error .weight
#guard ev (heavy 5 (.prim "==" [.int] [.var "x5", .var "x5"])) == .ok (.bool true)

-- [T-Tuple] [E-Tuple]
#guard ty (.tuple [.int 1, .str "a"]) == .ok (.tuple [.int, .str])
#guard ev (.tuple [.int 1, .str "a"]) == .ok (.tuple [.int 1, .str "a"])
#guard code (ty (.tuple [.int 1])) == "mismatch"

-- [T-List] [E-List]
#guard ty (.list .int []) == .ok (.list .int)
#guard ev (.list .int [.int 1, .int 2]) == .ok (.list [.int 1, .int 2])
#guard code (ty (.list .int [.str "a"])) == "mismatch"

-- [T-Map] [E-Map]: keys in value order, a later duplicate key wins, keys are data.
#guard ty (.map .int .str []) == .ok (.map .int .str)
#guard ev (.map .int .str [(.int 3, .str "c"), (.int 1, .str "a"), (.int 3, .str "z")]) ==
  .ok (.map [(.int 1, .str "a"), (.int 3, .str "z")])
#guard ev (.map .str .int [(.str "b", .int 1), (.str "a", .int 2)]) ==
  .ok (.map [(.str "a", .int 2), (.str "b", .int 1)])
#guard code (ty (.map (.arrow [.int] .int) .int [])) == "non-data-map-key"
#guard code (ty (.map .int (.arrow [.int] .int) [])) == "ok"

-- A key reached through deftype parameters, at any depth: `K0<a>` puts `a`
-- in a key, and each `Ki<a>` passes `a` to `K(i-1)`. `R<a>` recurs.
def keyChain (n : Nat) : Prog :=
  { types :=
      { name := "R", params := ["a"], variants := [("R", [.named "R" [.var "a"], .list (.var "a")])] } ::
      (List.range (n + 1)).map fun i =>
        if i == 0 then { name := "K0", params := ["a"], variants := [("K", [.map (.var "a") .int])] }
        else { name := s!"K{i}", params := ["a"], variants := [("K", [.named s!"K{i - 1}" [.var "a"]])] } }
def annotCode (P : Prog) (t : Ty) : String :=
  match Typing.annot P [] t with
  | .error e => e.code
  | .ok _ => "ok"
#guard annotCode (keyChain 0) (.named "K0" [.arrow [.int] .int]) == "non-data-map-key"
#guard annotCode (keyChain 40) (.named "K40" [.arrow [.int] .int]) == "non-data-map-key"
#guard annotCode (keyChain 40) (.named "K40" [.int]) == "ok"
#guard annotCode (keyChain 0) (.named "R" [.arrow [.int] .int]) == "ok"
#guard annotCode (keyChain 0) (.named "R" [.map (.arrow [.int] .int) .int]) == "non-data-map-key"

-- [T-Construct] [E-Construct]: `id : Uuid` may be left out, and is then absent.
#guard ty (pt 1 2) == .ok pointTy
#guard ev (pt 1 2) == .ok (.record "T.Point" [("x", .int 1), ("y", .int 2)])
#guard code (ty (.construct "T.Point" [("x", .int 1)])) == "missing-field"
#guard code (ty (.construct "T.Point" [("x", .int 1), ("y", .int 2), ("z", .int 3)])) == "extra-field"
#guard code (ty (.construct "T.Point" [("x", .int 1), ("y", .int 2), ("x", .int 3)])) == "extra-field"
#guard code (ty (.construct "T.Point" [("x", .str "1"), ("y", .int 2)])) == "mismatch"
#guard code (ty (.construct "T.Nope" [])) == "not-a-model"

-- [T-Field] [E-Field]
#guard ty (.field (pt 1 2) "y") == .ok .int
#guard ev (.field (pt 1 2) "y") == .ok (.int 2)
#guard ty (.field (pt 1 2) "id") == .ok .uuid
#guard ev (.field (pt 1 2) "id") == .error .noField
#guard code (ty (.field (pt 1 2) "z")) == "unknown-field"
#guard code (ty (.field (.int 1) "x")) == "not-a-model"

-- [T-Update] [E-Update]
#guard ty (.update "T.Point" (pt 1 2) [("y", .int 5)]) == .ok pointTy
#guard ev (.update "T.Point" (pt 1 2) [("y", .int 5)]) == .ok (.record "T.Point" [("x", .int 1), ("y", .int 5)])
#guard code (ty (.update "T.Point" (.int 1) [])) == "mismatch"

-- [T-Ctor] [E-Ctor]: explicit type arguments.
#guard ty (.ctor "Option" "Some" [.int] [.int 1]) == .ok optInt
#guard ev (.ctor "Option" "Some" [.int] [.int 1]) == .ok (.variant "Option" "Some" [.int 1])
#guard ty (.ctor "Option" "None" [.str] []) == .ok (.named "Option" [.str])
#guard code (ty (.ctor "Option" "Some" [.str] [.int 1])) == "mismatch"
#guard code (ty (.ctor "Option" "Some" [] [.int 1])) == "arity"
#guard code (ty (.ctor "Option" "Nope" [.int] [])) == "unbound"

-- [T-CtorRef] [E-CtorRef]
#guard ty (.ctorRef "T.Shape" "Rect" []) == .ok (.arrow [.int, .int] shapeTy)
#guard ev (.ctorRef "T.Shape" "Rect" []) == .ok (.ctorRef "T.Shape" "Rect" 2)
#guard ev (.app (.ctorRef "T.Shape" "Rect" []) [.int 2, .int 3]) == .ok (.variant "T.Shape" "Rect" [.int 2, .int 3])
#guard code (ty (.ctorRef "T.Shape" "Dot" [])) == "arity"

-- [T-Case] [E-Case] and the pattern rules [T-PWild] [T-PVar] [T-PInt] [T-PStr]
-- [T-PBool] [T-PTuple] [T-PVariant] / [E-PWild] [E-PVar] [E-PInt] [E-PStr]
-- [E-PBool] [E-PTuple] [E-PVariant]: arms are tried top-down.
#guard ev (.callDef "T.area" [.ctor "T.Shape" "Rect" [] [.int 2, .int 3]]) == .ok (.int 6)
#guard ev (.callDef "T.area" [.ctor "T.Shape" "Circle" [] [.int 2]]) == .ok (.int 12)
#guard ev (.callDef "T.area" [.ctor "T.Shape" "Dot" [] []]) == .ok (.int 0)
def intCase (n : Int) : Expr :=
  .case (.int n) [(.int 1, .str "one"), (.int 1, .str "uno"), (.var "k", .str "other")]
#guard ty (intCase 1) == .ok .str
#guard ev (intCase 1) == .ok (.str "one")
#guard ev (intCase 7) == .ok (.str "other")
#guard ev (.case (.str "b") [(.str "a", .int 1), (.wild, .int 2)]) == .ok (.int 2)
#guard ev (.case (.bool false) [(.bool true, .int 1), (.wild, .int 0)]) == .ok (.int 0)
#guard ev (.case (.tuple [.int 1, .ctor "Option" "Some" [.int] [.int 2]])
    [(.tuple [.wild, .variant "Option" "None" []], .int 0),
     (.tuple [.var "a", .variant "Option" "Some" [.var "b"]], .prim "+" [] [.var "a", .var "b"]),
     (.wild, .int (-1))]) == .ok (.int 3)
-- A scalar needs a final `_` or binder; so does a tuple (deep coverage is not specified).
#guard code (ty (.case (.bool true) [(.bool true, .int 1), (.bool false, .int 0)])) == "non-exhaustive"
#guard code (ty (.case (.tuple [.int 1, .int 2]) [(.tuple [.int 1, .wild], .int 1)])) == "non-exhaustive"
-- A deftype is covered variant by variant, shallowly.
#guard code (ty (.case (.ctor "Option" "None" [.int] [])
    [(.variant "Option" "Some" [.int 1], .int 1), (.variant "Option" "None" [], .int 0)])) == "non-exhaustive"
#guard ty (.case (.ctor "Option" "None" [.int] [])
    [(.variant "Option" "Some" [.var "x"], .var "x"), (.variant "Option" "None" [], .int 0)]) == .ok .int
#guard code (ty (.case (.ctor "Option" "None" [.int] []) [(.variant "Result" "Ok" [.wild], .int 0), (.wild, .int 1)])) == "bad-pattern"
#guard code (ty (.case (.int 1) [(.str "a", .int 0), (.wild, .int 1)])) == "mismatch"
#guard code (ty (.case (.list .int []) [(.wild, .int 1)])) == "mismatch"
#guard code (ty (.case (.int 1) [(.wild, .int 1), (.wild, .str "a")])) == "mismatch"
#guard code (ty (.case (.tuple [.int 1, .int 2]) [(.tuple [.var "a", .var "a"], .int 1)])) == "bad-name"

-- `stuck` is reachable only from ill-typed input: the same term is rejected by
-- `typeOf` and stuck in `eval`.
def illTyped : Expr := .prim "+" [] [.bool true, .int 1]
#guard code (ty illTyped) == "mismatch"
#guard ev illTyped == .error .stuck
#guard code (ty (.field (.int 1) "x")) == "not-a-model" && ev (.field (.int 1) "x") == .error .stuck
#guard code (ty (.app (.int 1) [])) == "not-a-function" && ev (.app (.int 1) []) == .error .stuck
-- Likewise `noArm`: a case no arm matches is not exhaustive.
def partialCase : Expr := .case (.int 3) [(.int 1, .int 1)]
#guard code (ty partialCase) == "non-exhaustive"
#guard ev partialCase == .error .noArm

-- `Value.conforms`: results have their static type.
#guard (ev (pt 1 2)).toOption.map (·.conforms prog pointTy) == some true
#guard (ev (.ctor "Option" "Some" [.int] [.int 1])).toOption.map (·.conforms prog optInt) == some true
#guard (ev (.ctor "Option" "Some" [.int] [.int 1])).toOption.map (·.conforms prog (.named "Option" [.str])) == some false
#guard (ev (.global "T.inc")).toOption.map (·.conforms prog (.arrow [.int] .int)) == some true
#guard (ev (.map .int .str [(.int 1, .str "a")])).toOption.map (·.conforms prog (.map .int .str)) == some true

/-! ## Hand-translated corpus: `test/fixtures/nobi/counter.nobi`

`Counter.update`'s model, as core (its `Cmd.none()` is a stdlib primitive,
added with the stdlib; `always` is outside core). Answers from
`test/fixtures/nobi/eval/corpus.json`. -/

def counterModel : ModelDecl := { name := "Counter.Model", fields := [("count", .int)] }
def counterMsg : TypeDecl :=
  { name := "Counter.Msg", params := [], variants := [("Increment", []), ("Decrement", []), ("Add", [.int])] }
def modelTy : Ty := .named "Counter.Model" []
def count : Expr := .field (.var "model") "count"
def setCount (e : Expr) : Expr := .update "Counter.Model" (.var "model") [("count", e)]
/-- `if c do a else b end`, as lowered. -/
def ifE (c a b : Expr) : Expr := .case c [(.bool true, a), (.wild, b)]

def counterNext : Def :=
  { name := "Counter.next", params := [("msg", .named "Counter.Msg" []), ("model", modelTy)], ret := modelTy,
    body := .case (.var "msg") [
      (.variant "Counter.Msg" "Increment" [], setCount (.prim "+" [] [count, .int 1])),
      (.variant "Counter.Msg" "Decrement" [],
        ifE (.prim ">" [] [count, .int 0]) (setCount (.prim "-" [] [count, .int 1])) (.var "model")),
      (.variant "Counter.Msg" "Add" [.var "n"],
        ifE (.prim ">=" [] [.prim "+" [] [count, .var "n"], .int 0])
          (setCount (.prim "+" [] [count, .var "n"])) (.var "model"))] }

def msg (c : String) (args : List Expr := []) : Expr := .ctor "Counter.Msg" c [] args
def model (n : Int) : Expr := .construct "Counter.Model" [("count", .int n)]
def step (m : Expr) (s : Expr) : Expr := .callDef "Counter.next" [m, s]

def counter : Prog :=
  { types := [counterMsg], models := [counterModel],
    defs := [counterNext,
      -- calls: Counter.update(Decrement, %{count: 95}) → count 94
      { name := "Counter.e0", params := [], ret := modelTy, body := step (msg "Decrement") (model 95) },
      -- steps: Increment, Increment, Add(5), Decrement from init → 1, 2, 7, 6
      { name := "Counter.e1", params := [], ret := .list modelTy,
        body :=
          .letIn "s1" (step (msg "Increment") (model 0))
          (.letIn "s2" (step (msg "Increment") (.var "s1"))
          (.letIn "s3" (step (msg "Add" [.int 5]) (.var "s2"))
          (.letIn "s4" (step (msg "Decrement") (.var "s3"))
          (.list modelTy [.var "s1", .var "s2", .var "s3", .var "s4"])))) },
      -- Decrement at zero keeps the model; Add of a negative past zero too.
      { name := "Counter.e2", params := [], ret := .tuple [modelTy, modelTy],
        body := .tuple [step (msg "Decrement") (model 0), step (msg "Add" [.int (-3)]) (model 2)] }] }

def countRec (n : Int) : Value := .record "Counter.Model" [("count", .int n)]

#guard (Typing.checkProgram counter).toBool
#guard Eval.runEntry counter "Counter.e0" == .ok (countRec 94)
#guard Eval.runEntry counter "Counter.e1" == .ok (.list [countRec 1, countRec 2, countRec 7, countRec 6])
#guard Eval.runEntry counter "Counter.e2" == .ok (.tuple [countRec 0, countRec 2])

end Tests.Core
