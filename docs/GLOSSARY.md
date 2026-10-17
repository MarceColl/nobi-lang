# Nobi glossary

## Language

- **Nobi**: the whole system: the language, the code store, the runtime, and the tools agents use.
- **Nobi**: the language. Elixir-flavoured syntax and Elm-style apps; statically typed; every name fully qualified.
- **Symbol**: a name in the system, as in Elixir: `Counter.update`, `Counter.Msg.Add`. Symbols refer to each other by name, never by hash.
- **Declaration**: a top-level statement that defines a symbol and relates it to something. It is one of `def`, `defmodel`, `deftype`, `defapp` or `deftest`, and it is the unit the code store holds and versions.
- **Canonical text**: what the formatter prints for a declaration. It is the stored form; whitespace never changes it.
- **CID**: a declaration's identity, `sha256("yabu/1\n" <> canonical text)` (`yabu` is the language's former name, kept so stored CIDs stay valid). The same content always gives the same CID.
- **Signature**: what other declarations see of a declaration: a def's parameter and return types, a model's fields, a type's variants.
- **Deps**: the symbols a declaration's check consulted.
- **Typed tree**: a checked declaration, with a type and a resolution on every node. Codegen consumes it.

## Code store

- **Patch**: the unit of change. A set of declarations plus removals (**tombstones**), under an id the agent or human chooses.
- **Stage**: submit a patch. It either **promotes** or stays **staged**.
- **Verdict**: the answer to a stage: `promoted [ids]`, or `staged [reasons]`.
- **Reason**: why a staged patch cannot promote: `{symbol, code, message}`.
- **Promote**: the largest set of staged patches that typecheck together with committed code joins committed code, atomically.
- **Commit**: one promotion. It records which patch ids promoted and what each did to each symbol (`live cid` or `gone`).
- **History**: the append-only list of commits.
- **Committed code**: history replayed, giving symbol → CID.
- **Universe**: a named code state: history and staged patches. Branches are universes: `main`, `feature-x`.
  - A universe stores symbol → CID references only. The definitions live in the CAS.
  - **Fork** starts a universe from another's history.
  - **Merge** stages one universe's committed code into another as a patch; conflicts come back as reasons.
  - `Nobi.Universe` is the system's interface to universes: list, create, stage, read, eval, call, test. It is the only thing callers use.
  - The in-memory value is `Nobi.Lang.Universe`, which is internal.
  - **Degraded**: a universe whose committed code no longer typechecks when it boots (the checker changed under stored code). It opens anyway, with committed code kept as stored and the failing symbols and reasons recorded: reading, staging and unstaging work, but nothing runs (`eval`, `call` and `test` answer `degraded`) until a patch that makes the whole image typecheck promotes. `Nobi.Universe.health/1` (MCP `health`, `Y.health()`) reports it. Only type errors degrade; corrupt storage (a CAS row missing, text that does not parse) still refuses to boot.
- **CodeDb**: the process that keeps one universe alive (`Nobi.CodeDb`, a PersistentElmGenServer). It serializes check, promote and persist for that universe.
  - It is an implementation detail of `Nobi.Universe`, which starts it on demand when a universe isn't running and routes to it.
  - Its `update/2` just applies `Nobi.Lang` to the universe it holds.
- **CAS**: the content-addressed store, a global, append-only `declarations(cid, text)` table shared by every universe. It has no process: writes are concurrent and idempotent.
- **Salsa / memo**: the incremental type-check cache inside a universe. It is derived and never persisted.

## Execution

- **Image**: the compiled form of one committed code state: one BEAM module, named by the **image hash** (a hash of the sorted symbol → CID pairs). Identical code gives the same image; each commit gives a new one.
- **Exec**: runs an image: `call` a def, `eval` an expression, `test` a deftest. Every run happens in a bounded **worker** with a timeout and a heap limit, and the worker is killed if its caller dies.
- **Rt**: the runtime support that generated code calls: the stdlib, checked arithmetic, equality and JSON.

## Apps and runtime

- **App** (`defapp`): one Elm loop. **Model** is its state, **Msg** its events, and `init`, `update` and `view` its functions.
- **Cmd / effect**: an effect described as data, which the host performs. The result comes back as a Msg.
- **Html**: what `view` returns: JSX as a value.
- **ElmGenServer / ElmLiveView**: Elixir processes running the same pure loop.
  - **Runtime** is their shared core.
  - **Timeline** is the record of each message, the effects it started, and the state it produced.
- **PersistentElmGenServer**: an ElmGenServer whose **durable** state is written to SQLite under a **key** before each step's effects run.

## System

- **Route table** (`defroutes`): a symbol mapping URL path patterns to apps (`"/post/:id" -> Forum.Post`). `:name` params are typed Int, String or Uuid and become the target app's `init` arguments; an app opens another with `Cmd.navigate(App, args…)`.
- **Deployment**: a named, served view of a universe: a **route table** to serve, following the universe's head or pinned to a commit, and the hosts that reach it. Reached through `Nobi.Deployment`.
- **Routing table**: the `deployments` table, which maps a request's host to a deployment (in dev and test, `<name>.localhost` reaches deployment `<name>` unlisted).
- **Console**: Nobi's own UI under `/_` (`/_/u/:universe`, `/_/d/:name`). It reads universes and deployments directly; it is never served through a deployment.
- **MCP**: the protocol agents use to drive universes, through `Nobi.Universe`. The **REPL** (`Y.…` in iex) is the human front end to the same operations.
- **Deploy**: send a universe's code to a remote **endpoint** as source plus CIDs. The remote compares CIDs and rebuilds only what is new.
- **Rollback**: load an older commit's image.
- **Oracle / goldens**: the TS and Rust answers the port is tested against.
