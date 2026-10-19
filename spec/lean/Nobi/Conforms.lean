import Nobi.Prim

/-!
# Conformance

`spec/semantics.md`, § Values.

`Value.conforms P v τ`: `v` is a value of type `τ`. The runtime side of type
soundness (G3): every result of a well-typed expression must conform to its
static type. A function value conforms by its parameter types (and, for a
def or a constructor, its whole signature); a closure's body is not
re-checked here. A Cmd effect conforms by its name and argument count.
-/

namespace Nobi

/-- Whether `id : Uuid`, the one field a record may lack (the store mints it). -/
def isIdentity (f : String) (t : Ty) : Bool := f == "id" && t == .uuid

mutual
def Value.conforms (P : Prog) : Value → Ty → Bool
  | .int _, .int | .str _, .str | .bool _, .bool | .unit, .unit | .uuid _, .uuid => true
  | .tuple vs, .tuple ts => Value.conformsAll P vs ts
  | .list vs, .list t => Value.conformsEach P vs t
  | .map es, .map k v => Value.conformsPairs P es k v
  | .record m fs, .named n [] =>
    m == n &&
      match P.findModel m with
      | some d =>
        Value.conformsFields P fs d.fields &&
          d.fields.all (fun (f, t) => fs.any (·.1 == f) || isIdentity f t)
      | none => false
  | .variant o c vs, .named n targs =>
    o == n &&
      match P.findType o with
      | some d =>
        d.params.length == targs.length &&
          match d.variant? c with
          | some args => Value.conformsAll P vs (Ty.substList (d.params.zip targs) args)
          | none => false
      | none => false
  | .closure _ ps _, .arrow qs _ => ps.map (·.2) == qs
  | .defRef g, .arrow qs r =>
    match P.findDef g with
    | some d => d.params.map (·.2) == qs && d.ret == r
    | none => false
  | .primRef op targs, .arrow qs r =>
    match Prim.sig? op with
    | some s =>
      let σ := s.tparams.zip targs
      s.tparams.length == targs.length && Ty.substList σ s.params == qs && s.ret.subst σ == r
    | none => false
  | .cmdNone, .cmd _ => true
  | .cmdBatch cs, .cmd m => Value.conformsEach P cs (.cmd m)
  | .cmdEffect name _ args, .cmd _ =>
    match Prim.sig? name with
    | some s => name.startsWith "Cmd." && s.params.length == args.length
    | none => false
  | .variant "Html" "Text" [.str _], .html _ => true
  | .variant "Html" "Element" [.str _, .list attrs, .list children], .html m =>
    Value.conformsAttrs P attrs m && Value.conformsEach P children (.html m)
  | .ctorRef o c k, .arrow qs (.named n targs) =>
    o == n && k == qs.length &&
      match P.findType o with
      | some d =>
        d.params.length == targs.length &&
          match d.variant? c with
          | some args => Ty.substList (d.params.zip targs) args == qs
          | none => false
      | none => false
  | _, _ => false

def Value.conformsAll (P : Prog) : List Value → List Ty → Bool
  | [], [] => true
  | v :: vs, t :: ts => Value.conforms P v t && Value.conformsAll P vs ts
  | _, _ => false

def Value.conformsEach (P : Prog) : List Value → Ty → Bool
  | [], _ => true
  | v :: vs, t => Value.conforms P v t && Value.conformsEach P vs t

def Value.conformsPairs (P : Prog) : List (Value × Value) → Ty → Ty → Bool
  | [], _, _ => true
  | (k, v) :: es, tk, tv =>
    Value.conforms P k tk && Value.conforms P v tv && Value.conformsPairs P es tk tv

/-- An element's attributes: an event's value is a message (an `on-change`
handler a constructor of one String); any other attribute's a scalar. -/
def Value.conformsAttrs (P : Prog) : List Value → Ty → Bool
  | [], _ => true
  | .tuple [.str name, v] :: rest, m =>
    (if name == "on-change" then Value.conforms P v (.arrow [.str] m)
     else if name.startsWith "on-" then Value.conforms P v m
     else Value.conforms P v .int || Value.conforms P v .str || Value.conforms P v .bool ||
       Value.conforms P v .uuid) &&
      Value.conformsAttrs P rest m
  | _, _ => false

def Value.conformsFields (P : Prog) : List (String × Value) → List (String × Ty) → Bool
  | [], _ => true
  | (f, v) :: fs, decl =>
    match decl.lookup f with
    | some t => Value.conforms P v t && Value.conformsFields P fs decl
    | none => false
end

end Nobi
