# Spec changes

Each entry names its spec version and its class:

- **patch:** spec text only, behaviour unchanged.
- **minor:** compatible. Every program accepted at the previous version is
  accepted with the same types and gives the same result on every entry.
- **major:** anything else. It needs a migration or an explicit sign-off
  that lists the programs it breaks.

Triaged disagreements between the spec and the implementation are recorded
here too, each with its verdict.

## 1.0.0 (initial)

Class: initial. The language as on main at
[`dc8b886`](https://github.com/MarceColl/nobi-lang/commit/dc8b8862ef16b245a51aeb6561fe5e8bf7cdab93).
