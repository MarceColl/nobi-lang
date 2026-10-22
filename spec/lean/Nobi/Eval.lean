import Nobi.Conforms

/-!
# Evaluation

`spec/semantics.md`, every `[E-…]` rule. `eval P fuel ρ e` is big-step,
call-by-value and left to right: a call's callee before its arguments,
arguments, items, entries (key, then value) and fields in the order written
(`codegen/expr.ex` "Order of evaluation"). Each nested evaluation takes one
unit of fuel, so fuel bounds the depth of evaluation; running out is `fuel`,
an inconclusive result rather than an error of the program.

Calling a function takes one more unit (`applyFn`).

A value of the wrong shape for its rule (adding a Bool, reading a field of
an Int, calling an Int) is `stuck`, never a default value. The typing rules
make `stuck` and `noArm` unreachable (G3).
-/

namespace Nobi.Eval

abbrev RtM := Except RtErr

mutual
/-- The bindings `p` makes when it matches `v`, else `none`. -/
def matchPat : Pat → Value → Option (Env Value)
  | .wild, _ => some [] -- [E-PWild]
  | .var x, v => some [(x, v)] -- [E-PVar]
  | .int n, .int m => if n == m then some [] else none -- [E-PInt]
  | .str s, .str t => if s == t then some [] else none -- [E-PStr]
  | .bool b, .bool c => if b == c then some [] else none -- [E-PBool]
  | .tuple ps, .tuple vs => matchPats ps vs -- [E-PTuple]
  | .variant o c ps, .variant o' c' vs => -- [E-PVariant]
    if o == o' && c == c' then matchPats ps vs else none
  | _, _ => none

def matchPats : List Pat → List Value → Option (Env Value)
  | [], [] => some []
  | p :: ps, v :: vs => do
    let b ← matchPat p v
    let bs ← matchPats ps vs
    pure (b ++ bs)
  | _, _ => none
end

/-- The first arm whose pattern matches `v`: its bindings and its body. -/
def firstArm (v : Value) : List (Pat × Expr) → Option (Env Value × Expr)
  | [] => none
  | (p, body) :: rest =>
    match matchPat p v with
    | some b => some (b, body)
    | none => firstArm v rest

/-- Sets each field in turn: a later one replaces an earlier one. -/
def setFields (fs : List (String × Value)) (set : List (String × Value)) :
    List (String × Value) :=
  set.foldl (fun acc (f, v) => Value.setField f v acc) fs

mutual
/-- Applies a function value to evaluated arguments (a body runs with the
fuel left): a closure in its captured environment, a def, a constructor, or
a stdlib function. A wrong arity or a value that is no function is `stuck`. -/
def applyFn (P : Prog) : Nat → Value → List Value → RtM Value
  | 0, _, _ => .error .fuel
  | n + 1, f, args =>
    match f with
    | .closure ρ ps body =>
      if ps.length == args.length then eval P n ((ps.map (·.1)).zip args ++ ρ) body
      else .error .stuck
    | .defRef g =>
      match P.findDef g with
      | some d =>
        if d.params.length == args.length then eval P n ((d.params.map (·.1)).zip args) d.body
        else .error .stuck
      | none => .error .stuck
    | .ctorRef o c k => if k == args.length then pure (.variant o c args) else .error .stuck
    | .primRef op targs => Prim.apply P (applyFn P n) op targs args
    | _ => .error .stuck

def eval (P : Prog) : Nat → Env Value → Expr → RtM Value
  | 0, _, _ => .error .fuel
  | n + 1, ρ, e =>
    match e with
    | .int k => pure (.int k) -- [E-Int]
    | .str s => pure (.str s) -- [E-Str]
    | .bool b => pure (.bool b) -- [E-Bool]
    | .unit => pure .unit -- [E-Unit]
    | .var x => -- [E-Var]
      match ρ.lookup x with
      | some v => pure v
      | none => .error .stuck
    | .global g => if (P.findDef g).isSome then pure (.defRef g) else .error .stuck -- [E-Global]
    | .callDef g args => do -- [E-CallDef]
      let vs ← args.mapM (eval P n ρ)
      applyFn P n (.defRef g) vs
    | .app f args => do -- [E-App]
      let vf ← eval P n ρ f
      let vs ← args.mapM (eval P n ρ)
      applyFn P n vf vs
    | .lam ps body => pure (.closure ρ ps body) -- [E-Lam]
    | .letIn x bound body => do -- [E-Let]
      let v ← eval P n ρ bound
      eval P n ((x, v) :: ρ) body
    | .seq a b => do -- [E-Seq]
      let _ ← eval P n ρ a
      eval P n ρ b
    | .prim op targs args => do -- [E-Prim]
      let vs ← args.mapM (eval P n ρ)
      Prim.apply P (applyFn P n) op targs vs
    | .primRef op targs => -- [E-PrimRef]
      if (Prim.sig? op).isSome then pure (.primRef op targs) else .error .stuck
    | .tuple items => .tuple <$> items.mapM (eval P n ρ) -- [E-Tuple]
    | .list _ items => .list <$> items.mapM (eval P n ρ) -- [E-List]
    | .map _ _ entries => do -- [E-Map]
      let pairs ← entries.mapM fun en => do
        let k ← eval P n ρ en.1
        let v ← eval P n ρ en.2
        pure (k, v)
      .map <$> Value.mapFromList [] pairs
    | .construct m fields => do -- [E-Construct]
      let vs ← fields.mapM fun f => do pure (f.1, ← eval P n ρ f.2)
      pure (.record m (setFields [] vs))
    | .field r f => do -- [E-Field]
      match ← eval P n ρ r with
      | .record _ fs =>
        match fs.lookup f with
        | some v => pure v
        | none => .error .noField
      | _ => .error .stuck
    | .update _ base fields => do -- [E-Update]
      let vb ← eval P n ρ base
      let vs ← fields.mapM fun f => do pure (f.1, ← eval P n ρ f.2)
      match vb with
      | .record m fs => pure (.record m (setFields fs vs))
      | _ => .error .stuck
    | .ctor o c _ args => .variant o c <$> args.mapM (eval P n ρ) -- [E-Ctor]
    | .ctorRef o c _ => -- [E-CtorRef]
      match (P.findType o).bind (·.variant? c) with
      | some args => pure (.ctorRef o c args.length)
      | none => .error .stuck
    | .case s arms => do -- [E-Case]
      let v ← eval P n ρ s
      match firstArm v arms with
      | some (b, body) => eval P n (b ++ ρ) body
      | none => .error .noArm
    | .element _ tag attrs children => do -- [E-Element]
      let avs ← attrs.mapM fun a => do pure (a.1, ← eval P n ρ a.2)
      let cvs ← children.mapM (eval P n ρ)
      Prim.Html.element tag avs cvs
end

/-- The fuel `nobi-ref` and the tests run with. -/
def defaultFuel : Nat := 10000

/-- An entry: a def of no parameters, called. -/
def runEntry (P : Prog) (g : String) (fuel : Nat := defaultFuel) : RtM Value :=
  eval P fuel [] (.callDef g [])

end Nobi.Eval
