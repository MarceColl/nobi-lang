import Nobi

/-! `nobi-ref`: the reference implementation's command line. -/

def usage : String :=
  "usage: nobi-ref version"

def main (args : List String) : IO UInt32 := do
  match args with
  | ["version"] =>
    IO.println Nobi.specVersion
    return 0
  | _ =>
    IO.eprintln usage
    return 2
