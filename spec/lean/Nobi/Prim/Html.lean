import Nobi.Prim.Ops

/-!
# Html

`spec/semantics.md`, § Html. An element is the variant
`Html.Element(tag, attrs, children)`, its attributes `(name, value)` pairs
(an event named `on-<event>`), and text is `Html.Text(text)` (`rt.ex`
L585-609). JSX is the only way to build one.
-/

namespace Nobi.Prim.Html

/-- The events the renderer wires, and the tags each works on (`none`: any). -/
def events : List (String × Option (List String)) :=
  [ ("click", none), ("blur", none), ("focus", none), ("keydown", none), ("keyup", none),
    ("submit", some ["form"]), ("change", some ["input", "textarea", "select"]) ]

def text (s : String) : Value := .variant "Html" "Text" [.str s]

mutual
/-- A child as the element holds it: Html as itself, a list's items in its
place (at any depth), a String as text, an Int, a Bool or a Uuid as its
text. Anything else is `stuck`. -/
def splice : Value → Except RtErr (List Value)
  | .variant "Html" c xs => .ok [.variant "Html" c xs]
  | .list xs => spliceList xs
  | .str s => .ok [text s]
  | .int n => .ok [text (toString n)]
  | .bool b => .ok [text (if b then "true" else "false")]
  | .uuid s => .ok [text s]
  | _ => .error .stuck

def spliceList : List Value → Except RtErr (List Value)
  | [] => .ok []
  | x :: xs => do
    let a ← splice x
    let b ← spliceList xs
    pure (a ++ b)
end

def element (tag : String) (attrs : List (String × Value)) (children : List Value) :
    Except RtErr Value := do
  let cs ← spliceList children
  pure (.variant "Html" "Element"
    [.str tag, .list (attrs.map fun a => .tuple [.str a.1, a.2]), .list cs])

end Nobi.Prim.Html
