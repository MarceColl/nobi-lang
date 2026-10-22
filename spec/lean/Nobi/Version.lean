/-!
# Spec version

The language version this specification describes. `Tests/Version.lean`
checks that it matches `spec/lean/VERSION`, the file CI and `spec/CHANGES.md`
read.
-/

namespace Nobi

/-- The spec version, as in `VERSION`. -/
def specVersion : String := "2.0.0"

end Nobi
