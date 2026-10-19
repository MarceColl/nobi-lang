import Tests

/-!
`lake test`'s driver. Importing `Tests` means every `#guard` held when it was
built; what is left are the checks that read files, run on every call so a
cached build cannot skip them.
-/

/-- The package root: the binary is `<root>/.lake/build/bin/spec-tests`. -/
def packageRoot : IO System.FilePath := do
  let app ← IO.appPath
  match app.parent.bind (·.parent) |>.bind (·.parent) |>.bind (·.parent) with
  | some root => return root
  | none => throw <| IO.userError s!"cannot find the package root from {app}"

def checkVersion (root : System.FilePath) : IO Bool := do
  let file := (← IO.FS.readFile (root / "VERSION")).trimAscii.toString
  if file == Nobi.specVersion then
    IO.println s!"ok: VERSION is {file}"
    return true
  IO.eprintln s!"FAIL: VERSION says {file}, Nobi.specVersion says {Nobi.specVersion}"
  return false

/-- `scripts/rule-names.sh`: rule names in `spec/semantics.md` and the Lean tags agree. -/
def checkRuleNames (root : System.FilePath) : IO Bool := do
  let out ← IO.Process.output { cmd := (root / "scripts" / "rule-names.sh").toString }
  IO.print out.stdout
  IO.eprint out.stderr
  return out.exitCode == 0

def main : IO UInt32 := do
  let root ← packageRoot
  let version ← checkVersion root
  let rules ← checkRuleNames root
  return if version && rules then 0 else 1
