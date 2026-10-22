import Nobi.Conforms

/-!
# Typing

`spec/semantics.md`, every `[T-…]` rule. `typeOf P Γ e` is algorithmic and
syntax-directed: one match arm per rule, each tagged with the rule's name.
Error codes are the surface checker's (`types/check.ex`), so a rejection can
be compared with the Elixir checker's.
-/

namespace Nobi.Typing

/-- A typing context: the innermost binding of a name comes first. -/
abbrev Ctx := List (String × Ty)

abbrev TyM := Except TyErr

def fail {α : Type} (code msg : String) : TyM α := .error ⟨code, msg⟩

def show' (t : Ty) : String := toString (repr t)

/-! ## Types written in a program -/

mutual
/-- Every name in `t` resolves, with as many arguments as it declares;
`tps` are the type parameters in scope (a deftype's, else none). -/
def wf (P : Prog) (tps : List String) : Ty → TyM Unit
  | .int | .str | .bool | .unit | .uuid => pure ()
  | .var x => if tps.contains x then pure () else fail "unbound" s!"unknown type variable `{x}`"
  | .tuple ts => wfList P tps ts
  | .list t => wf P tps t
  | .map k v => do wf P tps k; wf P tps v
  | .arrow ps r => do wfList P tps ps; wf P tps r
  | .cmd m | .html m => wf P tps m
  | .named n args => do
    match P.findType n, P.findModel n with
    | some d, _ =>
      unless d.params.length == args.length do
        fail "arity" s!"type `{n}` expects {d.params.length} parameter(s), got {args.length}"
    | none, some _ =>
      unless args.isEmpty do fail "arity" s!"model `{n}` takes no parameters"
    | none, none => fail "unbound" s!"unknown type `{n}`"
    wfList P tps args

def wfList (P : Prog) (tps : List String) : List Ty → TyM Unit
  | [] => pure ()
  | t :: ts => do wf P tps t; wfList P tps ts
end

/-- For each deftype, whether each of its parameters reaches a `Map` key. -/
abbrev KeyReach := List (String × List Bool)

/-- What `R` says of `m`'s parameters, if it has one flag per argument in
`args`; else nothing is passed on (an arity error reports that). -/
def KeyReach.flags (R : KeyReach) (m : String) (args : List Ty) : List Bool :=
  let fs := (R.lookup m).getD []
  if fs.length == args.length then fs else []

mutual
/-- Whether parameter `x` reaches a key in `t`: it occurs inside a `Map`'s
key, or inside an argument to a parameter that reaches one (per `R`). -/
def reachesKey (R : KeyReach) (x : String) : Ty → Bool
  | .map k v => k.mentions x || reachesKey R x v
  | .tuple ts => reachesKeyList R x [] ts
  | .list t => reachesKey R x t
  | .arrow ps r => reachesKeyList R x [] ps || reachesKey R x r
  | .named m args => reachesKeyList R x (R.flags m args) args
  | .cmd m | .html m => reachesKey R x m
  | _ => false

/-- `reachesKey` over `ts`, where `fs` flags the ones passed to a parameter
that reaches a key. -/
def reachesKeyList (R : KeyReach) (x : String) : List Bool → List Ty → Bool
  | _, [] => false
  | fs, t :: ts =>
    (fs.headD false && t.mentions x) || reachesKey R x t || reachesKeyList R x fs.tail ts
end

/-- The least fixpoint of `reachesKey` over every deftype of `P`, as
`types/keys.ex` settles it. Each round before the fixpoint turns at least
one flag on, so one round per parameter is enough. -/
def keyReach (P : Prog) : KeyReach :=
  let ds := P.types ++ stdTypes
  let step (R : KeyReach) : KeyReach :=
    ds.map fun d => (d.name, d.params.map fun x => d.variants.any (·.2.any (reachesKey R x)))
  let rounds := (ds.map (·.params.length)).sum
  Nat.repeat step rounds (ds.map fun d => (d.name, d.params.map fun _ => false))

mutual
/-- Every `Map` key type in `t` is data, including keys a deftype's
parameter reaches (`types/keys.ex`). -/
def keysOk (R : KeyReach) : Ty → Bool
  | .map k v => !k.hasFn && keysOk R k && keysOk R v
  | .tuple ts => keysOkList R ts
  | .list t => keysOk R t
  | .arrow ps r => keysOkList R ps && keysOk R r
  | .named m args =>
    keysOkList R args && ((R.flags m args).zip args).all fun (f, a) => !f || !a.hasFn
  | .cmd m | .html m => keysOk R m
  | _ => true

def keysOkList (R : KeyReach) : List Ty → Bool
  | [] => true
  | t :: ts => keysOk R t && keysOkList R ts
end

/-- A type written in a program: well-formed, and its map keys are data. -/
def annot (P : Prog) (tps : List String) (t : Ty) : TyM Unit := do
  wf P tps t
  unless keysOk (keyReach P) t do
    fail "non-data-map-key" s!"the type `{show' t}` holds a `Map` whose key is not data"

/-- Arguments against parameters: as many, each of its parameter's type. -/
def expectArgs (what : String) (ps ts : List Ty) : TyM Unit := do
  unless ps.length == ts.length do
    fail "arity" s!"`{what}` expects {ps.length} argument(s), got {ts.length}"
  for (p, t) in ps.zip ts do
    unless p == t do fail "mismatch" s!"`{what}`: expected {show' p}, got {show' t}"

def expect (what : String) (want got : Ty) : TyM Unit :=
  unless want == got do fail "mismatch" s!"{what}: expected {show' want}, got {show' got}"

/-- No name twice. -/
def distinct (code what : String) : List String → TyM Unit
  | [] => pure ()
  | x :: xs => do
    if xs.contains x then fail code s!"`{x}` is already bound in {what}"
    distinct code what xs

def lookupVariant (P : Prog) (o c : String) : TyM (TypeDecl × List Ty) :=
  match P.findType o with
  | some d =>
    match d.variant? c with
    | some args => pure (d, args)
    | none => fail "unbound" s!"`{o}` has no variant `{c}`"
  | none => fail "unbound" s!"unknown type `{o}`"

/-- The fields a construction or an update sets: each declared, each once. -/
def checkFieldNames (m : String) (d : ModelDecl) (names : List String) : TyM Unit := do
  for f in names do
    unless (d.fields.lookup f).isSome do fail "extra-field" s!"model `{m}` has no field `{f}`"
  distinct "extra-field" s!"`%{m}\{…}`" names

/-- A primitive's signature, given as many well-formed type arguments as it
takes; a store form's first one must be a model. -/
def primSig (P : Prog) (op : String) (targs : List Ty) : TyM Prim.Sig := do
  let some s := Prim.sig? op | fail "unbound" s!"`{op}` is no primitive"
  unless s.tparams.length == targs.length do
    fail "arity" s!"`{op}` takes {s.tparams.length} type argument(s), got {targs.length}"
  for t in targs do annot P [] t
  if s.store then
    match targs with
    | .named m [] :: _ =>
      if (P.findModel m).isNone then fail "not-a-model" s!"`{op}` works on a model, got `{m}`"
    | t :: _ => fail "not-a-model" s!"`{op}` works on a model, got {show' t}"
    | [] => pure ()
  pure s

/-- A JSX attribute `name = e`, `e : t`, on a `tag` element sending `m`
(`types/jsx_app.ex`): an event's value is a message of type `m` (a deftype
value); `on-change`'s is a constructor of one String building an `m`; any
other attribute's is a scalar. -/
def checkAttr (P : Prog) (m : Ty) (tag name : String) (e : Expr) (t : Ty) : TyM Unit := do
  if name.startsWith "on-" then
    let event := String.ofList (name.toList.drop 3)
    match Prim.Html.events.lookup event with
    | none => fail "bad-event" s!"on-{event} is not an event Nobi wires"
    | some (some tags) =>
      unless tags.contains tag do fail "bad-event" s!"on-{event} does not work on a <{tag}>"
    | some none => pure ()
    if event == "change" then
      match e, t with
      | .ctorRef .., .arrow [.str] r => expect "on-change" m r
      | _, _ => fail "bad-event" "on-change needs an unapplied 1-argument String constructor"
    else
      match t with
      | .named n _ =>
        if (P.findType n).isNone then fail "bad-event" s!"on-{event} needs a message value"
        expect s!"on-{event}" m t
      | _ => fail "bad-event" s!"on-{event} needs a message value (a variant), got {show' t}"
  else
    unless t == .int || t == .str || t == .bool || t == .uuid do
      fail "mismatch" s!"attribute `{name}` must be a scalar, got {show' t}"

/-! ## Patterns -/

mutual
/-- The bindings a pattern makes, matched against a value of type `t`. -/
def bindPat (P : Prog) : Ty → Pat → TyM Ctx
  | _, .wild => pure [] -- [T-PWild]
  | t, .var x => pure [(x, t)] -- [T-PVar]
  | t, .int _ => do expect "pattern" t .int; pure [] -- [T-PInt]
  | t, .str _ => do expect "pattern" t .str; pure [] -- [T-PStr]
  | t, .bool _ => do expect "pattern" t .bool; pure [] -- [T-PBool]
  | t, .tuple ps => -- [T-PTuple]
    match t with
    | .tuple ts =>
      if ts.length == ps.length then bindPats P ts ps
      else fail "mismatch" s!"expected {show' t}, got a tuple of {ps.length}"
    | _ => fail "mismatch" s!"expected {show' t}, got a tuple pattern"
  | t, .variant o c ps => -- [T-PVariant]
    match t with
    | .named n targs => do
      unless n == o do fail "bad-pattern" s!"pattern `{o}.{c}` does not belong to `{n}`"
      let some d := P.findType o | fail "bad-pattern" s!"`{o}` is not a deftype"
      let some args := d.variant? c | fail "bad-pattern" s!"`{o}` has no variant `{c}`"
      unless args.length == ps.length do
        fail "bad-pattern" s!"pattern `{o}.{c}` expects {args.length} argument(s), got {ps.length}"
      bindPats P (Ty.substList (d.params.zip targs) args) ps
    | _ => fail "bad-pattern" s!"pattern `{o}.{c}` cannot match a value of type {show' t}"

def bindPats (P : Prog) : List Ty → List Pat → TyM Ctx
  | t :: ts, p :: ps => do
    let b ← bindPat P t p
    let bs ← bindPats P ts ps
    pure (b ++ bs)
  | _, _ => pure []
end

mutual
/-- Matches every value: `_`, a binder, or a tuple of those. -/
def Pat.coversAll : Pat → Bool
  | .wild | .var _ => true
  | .tuple ps => Pat.coversAllList ps
  | _ => false

def Pat.coversAllList : List Pat → Bool
  | [] => true
  | p :: ps => Pat.coversAll p && Pat.coversAllList ps
end

mutual
def Pat.binders : Pat → List String
  | .var x => [x]
  | .tuple ps => Pat.bindersList ps
  | .variant _ _ ps => Pat.bindersList ps
  | _ => []

def Pat.bindersList : List Pat → List String
  | [] => []
  | p :: ps => Pat.binders p ++ Pat.bindersList ps
end

/-- Covers every value of variant `c`: `Owner.c(p…)` with each `p` covering all. -/
def coversVariant (c : String) : Pat → Bool
  | .variant _ c' ps => c' == c && Pat.coversAllList ps
  | _ => false

/-- Exhaustiveness, shallow (`types/patterns.ex`): some arm covers every
value, or (on a deftype) every variant is covered by an arm of its own.
Deep tuple coverage is not specified: on a tuple, an arm must cover all. -/
def exhaustive (P : Prog) (t : Ty) (pats : List Pat) : TyM Unit :=
  -- [T-Exhaustive]
  if pats.any Pat.coversAll then pure ()
  else
    match t with
    | .named n _ =>
      match P.findType n with
      | some d =>
        let missing := d.variants.filter fun v => !pats.any (coversVariant v.1)
        unless missing.isEmpty do
          fail "non-exhaustive"
            s!"case on `{n}` is not exhaustive — missing: {", ".intercalate (missing.map (·.1))}"
      | none => fail "non-exhaustive" s!"case on `{n}` is not exhaustive"
    | _ => fail "non-exhaustive" "case on a scalar or a tuple needs an arm that matches everything"

/-- What a `case` may take apart: a deftype, a scalar (Int, String, Bool,
Uuid) or a tuple. -/
def caseable (P : Prog) : Ty → Bool
  | .named n _ => (P.findType n).isSome
  | .int | .str | .bool | .uuid | .tuple _ => true
  | _ => false

/-! ## Expressions -/

/-- The type of `e`. -/
def typeOf (P : Prog) (Γ : Ctx) : Expr → TyM Ty
  | .int _ => pure .int -- [T-Int]
  | .str _ => pure .str -- [T-Str]
  | .bool _ => pure .bool -- [T-Bool]
  | .unit => pure .unit -- [T-Unit]
  | .var x => -- [T-Var]
    match Γ.lookup x with
    | some t => pure t
    | none => fail "unbound" s!"`{x}` is not bound"
  | .global g => -- [T-Global]
    match P.findDef g with
    | some d => pure (.arrow (d.params.map (·.2)) d.ret)
    | none => fail "unbound" s!"`{g}` is not defined"
  | .callDef g args => do -- [T-CallDef]
    let some d := P.findDef g | fail "unbound" s!"`{g}` is not defined"
    let ts ← args.mapM (typeOf P Γ)
    expectArgs g (d.params.map (·.2)) ts
    pure d.ret
  | .app f args => do -- [T-App]
    let tf ← typeOf P Γ f
    let ts ← args.mapM (typeOf P Γ)
    match tf with
    | .arrow ps r => do expectArgs "the function" ps ts; pure r
    | t => fail "not-a-function" s!"not callable (type {show' t})"
  | .lam ps body => do -- [T-Lam]
    for p in ps do annot P [] p.2
    distinct "bad-name" "this fn" (ps.map (·.1))
    let r ← typeOf P (ps.reverse ++ Γ) body
    pure (.arrow (ps.map (·.2)) r)
  | .letIn x e body => do -- [T-Let]
    let t ← typeOf P Γ e
    typeOf P ((x, t) :: Γ) body
  | .seq a b => do -- [T-Seq]
    let _ ← typeOf P Γ a
    typeOf P Γ b
  | .prim op targs args => do -- [T-Prim]
    let s ← primSig P op targs
    let ts ← args.mapM (typeOf P Γ)
    let σ := s.tparams.zip targs
    expectArgs op (Ty.substList σ s.params) ts
    pure (s.ret.subst σ)
  | .primRef op targs => do -- [T-PrimRef]
    let s ← primSig P op targs
    let σ := s.tparams.zip targs
    pure (.arrow (Ty.substList σ s.params) (s.ret.subst σ))
  | .tuple items => do -- [T-Tuple]
    unless items.length ≥ 2 do fail "mismatch" "a tuple has two or more items"
    let ts ← items.mapM (typeOf P Γ)
    pure (.tuple ts)
  | .list t items => do -- [T-List]
    annot P [] t
    let ts ← items.mapM (typeOf P Γ)
    for u in ts do expect "list item" t u
    pure (.list t)
  | .map k v entries => do -- [T-Map]
    annot P [] (.map k v)
    let ts ← entries.mapM fun e => do
      let tk ← typeOf P Γ e.1
      let tv ← typeOf P Γ e.2
      pure (tk, tv)
    for (tk, tv) in ts do
      expect "map key" k tk
      expect "map value" v tv
    pure (.map k v)
  | .construct m fields => do -- [T-Construct]
    let some d := P.findModel m | fail "not-a-model" s!"`{m}` is not a model"
    checkFieldNames m d (fields.map (·.1))
    for (f, t) in d.fields do
      unless isIdentity f t || fields.any (·.1 == f) do
        fail "missing-field" s!"`%{m}\{…}` is missing field `{f}`"
    let ts ← fields.mapM fun f => do pure (f.1, ← typeOf P Γ f.2)
    for (f, t) in ts do
      if let some want := d.fields.lookup f then expect s!"field `{f}`" want t
    pure (.named m [])
  | .field e f => do -- [T-Field]
    match ← typeOf P Γ e with
    | .named m [] =>
      match P.findModel m with
      | some d =>
        match d.fields.lookup f with
        | some t => pure t
        | none => fail "unknown-field" s!"model `{m}` has no field `{f}`"
      | none => fail "not-a-model" s!"`{m}` is not a model"
    | t => fail "not-a-model" s!"field access `.{f}` needs a model, got {show' t}"
  | .update m base fields => do -- [T-Update]
    let some d := P.findModel m | fail "not-a-model" s!"`{m}` is not a model"
    let tb ← typeOf P Γ base
    expect "updated record" (.named m []) tb
    checkFieldNames m d (fields.map (·.1))
    let ts ← fields.mapM fun f => do pure (f.1, ← typeOf P Γ f.2)
    for (f, t) in ts do
      if let some want := d.fields.lookup f then expect s!"field `{f}`" want t
    pure (.named m [])
  | .ctor o c targs args => do -- [T-Ctor]
    let (d, vargs) ← lookupVariant P o c
    unless d.params.length == targs.length do
      fail "arity" s!"`{o}` takes {d.params.length} type argument(s), got {targs.length}"
    for t in targs do annot P [] t
    let ts ← args.mapM (typeOf P Γ)
    expectArgs s!"{o}.{c}" (Ty.substList (d.params.zip targs) vargs) ts
    pure (.named o targs)
  | .ctorRef o c targs => do -- [T-CtorRef]
    let (d, vargs) ← lookupVariant P o c
    unless d.params.length == targs.length do
      fail "arity" s!"`{o}` takes {d.params.length} type argument(s), got {targs.length}"
    if vargs.isEmpty then fail "arity" s!"`{o}.{c}` takes no arguments: it is a value"
    for t in targs do annot P [] t
    pure (.arrow (Ty.substList (d.params.zip targs) vargs) (.named o targs))
  | .case s arms => do -- [T-Case]
    let ts ← typeOf P Γ s
    unless caseable P ts do
      fail "mismatch" s!"case scrutinee must be a variant type, a scalar or a tuple, got {show' ts}"
    let bodies ← arms.mapM fun a => do
      let bs ← bindPat P ts a.1
      distinct "bad-name" "this pattern" (Pat.binders a.1)
      typeOf P (bs ++ Γ) a.2
    exhaustive P ts (arms.map (·.1))
    match bodies with
    | [] => fail "non-exhaustive" "a case needs an arm"
    | t :: rest => do
      for u in rest do expect "case arm" t u
      pure t
  | .element m tag attrs children => do -- [T-Element]
    annot P [] m
    let ats ← attrs.mapM fun a => do pure (a.1, a.2, ← typeOf P Γ a.2)
    for (name, e, t) in ats do checkAttr P m tag name e t
    let cts ← children.mapM (typeOf P Γ)
    for t in cts do
      unless t == .str || t == .int || t == .html m || t == .list (.html m) do
        fail "mismatch" s!"a JSX child must be Html, String, Int or a List of Html, got {show' t}"
    pure (.html m)
decreasing_by
  all_goals first
    | decreasing_tactic
    | (rename_i h; have := List.sizeOf_lt_of_mem h; cases ‹_ × _›; simp_all; omega)

/-! ## Programs -/

/-- A field or variant argument holds data: no function anywhere in it. -/
def dataField (where_ : String) (t : Ty) : TyM Unit :=
  if t.hasFn then fail "invalid-model-field" s!"{where_} cannot hold a function"
  else pure ()

/-- Every declaration's rules, then every def's body against its signature. -/
def checkProgram (P : Prog) : TyM Unit := do
  -- [T-Program]
  for d in P.types do
    distinct "bad-name" s!"the parameters of `{d.name}`" d.params
    for (c, args) in d.variants do
      for a in args do
        annot P d.params a
        dataField s!"variant `{d.name}.{c}`" a
  for m in P.models do
    for (f, t) in m.fields do
      annot P [] t
      dataField s!"model field `{f}`" t
  for d in P.defs do
    for p in d.params do annot P [] p.2
    annot P [] d.ret
    distinct "bad-name" s!"the parameters of `{d.name}`" (d.params.map (·.1))
    let t ← typeOf P d.params.reverse d.body
    expect s!"the body of `{d.name}`" d.ret t

end Nobi.Typing
