/-!
# Core syntax

The core language that surface Nobi lowers to (`spec/semantics.md`, § Types
and the sections after it). Every binder carries its type and every
polymorphic constructor or primitive carries its type arguments, so typing is
syntax-directed: no unification, no inference.
-/

namespace Nobi

/-- Types. A deftype or a model is `named` with its type arguments (`[]` for
a model or a deftype without parameters). `var` is a deftype's parameter and
appears only inside a deftype's variants. -/
inductive Ty where
  | int
  | str
  | bool
  | unit
  | uuid
  | tuple (items : List Ty)
  | list (elem : Ty)
  | map (key val : Ty)
  | arrow (params : List Ty) (ret : Ty)
  | named (name : String) (args : List Ty)
  | var (name : String)
  /-- `Cmd<m>`: an effect, as data, whose callbacks build an `m`. -/
  | cmd (msg : Ty)
  /-- `Html<m>`: markup whose events send an `m`. -/
  | html (msg : Ty)
  deriving Repr, BEq, Inhabited

/-- Case patterns. A variant pattern names its owner, as in `Option.Some(x)`. -/
inductive Pat where
  | wild
  | var (x : String)
  | int (n : Int)
  | str (s : String)
  | bool (b : Bool)
  | tuple (items : List Pat)
  | variant (owner ctor : String) (args : List Pat)
  deriving Repr, BEq, Inhabited

/-- Core expressions. -/
inductive Expr where
  | int (n : Int)
  | str (s : String)
  | bool (b : Bool)
  | unit
  /-- A local: a parameter, a `let` or a pattern binder. -/
  | var (x : String)
  /-- A def of the program taken as a value. -/
  | global (g : String)
  /-- A direct call of a def of the program. -/
  | callDef (g : String) (args : List Expr)
  /-- A call of a function value (a function-typed local or parameter). -/
  | app (fn : Expr) (args : List Expr)
  | lam (params : List (String × Ty)) (body : Expr)
  | letIn (x : String) (bound body : Expr)
  | seq (first rest : Expr)
  /-- An operator or stdlib function, with its type arguments. -/
  | prim (op : String) (targs : List Ty) (args : List Expr)
  /-- A stdlib function taken as a value, with its type arguments. -/
  | primRef (op : String) (targs : List Ty)
  | tuple (items : List Expr)
  | list (elem : Ty) (items : List Expr)
  | map (key val : Ty) (entries : List (Expr × Expr))
  | construct (model : String) (fields : List (String × Expr))
  | field (record : Expr) (name : String)
  | update (model : String) (base : Expr) (fields : List (String × Expr))
  /-- A variant built: `Owner.Ctor(args)`, with the deftype's type arguments. -/
  | ctor (owner ctor : String) (targs : List Ty) (args : List Expr)
  /-- A constructor of one or more arguments taken as a value. -/
  | ctorRef (owner ctor : String) (targs : List Ty)
  /-- Arms are tried top-down. -/
  | case (scrut : Expr) (arms : List (Pat × Expr))
  /-- A JSX element sending `msg`: attributes in order (an event is named
  `on-<event>`, a text attribute is a string literal), then children (a text
  child is a string literal, a nested element an `element`). -/
  | element (msg : Ty) (tag : String) (attrs : List (String × Expr)) (children : List Expr)
  deriving Repr, BEq, Inhabited

/-- A `deftype`: its parameters and its variants' argument types. -/
structure TypeDecl where
  name : String
  params : List String
  variants : List (String × List Ty)
  deriving Repr, BEq, Inhabited

/-- A `defmodel`: its fields and their types. -/
structure ModelDecl where
  name : String
  fields : List (String × Ty)
  deriving Repr, BEq, Inhabited

/-- A `def`: annotated parameters and return type, monomorphic. -/
structure Def where
  name : String
  params : List (String × Ty)
  ret : Ty
  body : Expr
  deriving Repr, BEq, Inhabited

/-- A program: what one image holds. -/
structure Prog where
  types : List TypeDecl := []
  models : List ModelDecl := []
  defs : List Def := []
  deriving Repr, BEq, Inhabited

/-- The stdlib's deftypes (`types/stdlib.ex`). -/
def stdTypes : List TypeDecl :=
  [ { name := "Option", params := ["T"], variants := [("Some", [.var "T"]), ("None", [])] },
    { name := "Result", params := ["T", "E"], variants := [("Ok", [.var "T"]), ("Err", [.var "E"])] } ]

namespace Prog

def findType (P : Prog) (n : String) : Option TypeDecl :=
  (P.types ++ stdTypes).find? (·.name == n)

def findModel (P : Prog) (n : String) : Option ModelDecl :=
  P.models.find? (·.name == n)

def findDef (P : Prog) (n : String) : Option Def :=
  P.defs.find? (·.name == n)

end Prog

/-- A deftype's variant: its argument types. -/
def TypeDecl.variant? (d : TypeDecl) (c : String) : Option (List Ty) :=
  d.variants.lookup c

mutual
/-- `t` with each deftype parameter replaced by what `σ` maps it to. -/
def Ty.subst (σ : List (String × Ty)) : Ty → Ty
  | .var x => (σ.lookup x).getD (.var x)
  | .tuple ts => .tuple (Ty.substList σ ts)
  | .list t => .list (Ty.subst σ t)
  | .map k v => .map (Ty.subst σ k) (Ty.subst σ v)
  | .arrow ps r => .arrow (Ty.substList σ ps) (Ty.subst σ r)
  | .named n args => .named n (Ty.substList σ args)
  | .cmd m => .cmd (Ty.subst σ m)
  | .html m => .html (Ty.subst σ m)
  | t => t

def Ty.substList (σ : List (String × Ty)) : List Ty → List Ty
  | [] => []
  | t :: ts => Ty.subst σ t :: Ty.substList σ ts
end

mutual
/-- Whether a value of `t` can hold something that is not data: a function,
a `Cmd` or `Html`, anywhere in it. Models and deftypes hold none of their own
(their fields and variant arguments are data), so only their type arguments
count. -/
def Ty.hasFn : Ty → Bool
  | .arrow _ _ | .cmd _ | .html _ => true
  | .tuple ts => Ty.hasFnList ts
  | .list t => Ty.hasFn t
  | .map k v => Ty.hasFn k || Ty.hasFn v
  | .named _ args => Ty.hasFnList args
  | _ => false

def Ty.hasFnList : List Ty → Bool
  | [] => false
  | t :: ts => Ty.hasFn t || Ty.hasFnList ts
end

mutual
/-- Whether deftype parameter `x` occurs in `t`. -/
def Ty.mentions (x : String) : Ty → Bool
  | .var y => x == y
  | .tuple ts => Ty.mentionsList x ts
  | .list t => Ty.mentions x t
  | .map k v => Ty.mentions x k || Ty.mentions x v
  | .arrow ps r => Ty.mentionsList x ps || Ty.mentions x r
  | .named _ args => Ty.mentionsList x args
  | .cmd m | .html m => Ty.mentions x m
  | _ => false

def Ty.mentionsList (x : String) : List Ty → Bool
  | [] => false
  | t :: ts => Ty.mentions x t || Ty.mentionsList x ts
end

/-- Runtime errors (`spec/semantics.md`, § Values). `stuck` is a value of the
wrong shape for its rule; `noArm` a `case` no arm matched. Both are
unreachable from a well-typed program. `fuel` is running out of fuel, which
counts as inconclusive. -/
inductive RtErr where
  | divZero
  | noField
  | noArm
  | weight
  | fuel
  | stuck
  deriving Repr, BEq, Inhabited

/-- Type errors, by the surface checker's error code. -/
structure TyErr where
  code : String
  msg : String
  deriving Repr, BEq, Inhabited

instance {ε α : Type} [BEq ε] [BEq α] : BEq (Except ε α) where
  beq
    | .ok a, .ok b => a == b
    | .error a, .error b => a == b
    | _, _ => false

end Nobi
