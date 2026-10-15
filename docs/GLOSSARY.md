# Kinoko glossary

## Language

- **Kinoko**: the whole system: the language, the code store, the runtime, and the tools agents use.
- **Yabu**: the language. Elixir-flavoured syntax and Elm-style apps; statically typed; every name fully qualified.
- **Symbol**: a name in the system, as in Elixir: `Counter.update`, `Counter.Msg.Add`. Symbols refer to each other by name, never by hash.
- **Declaration**: a top-level statement that defines a symbol and relates it to something. It is one of `def`, `defmodel`, `deftype`, `defapp` or `deftest`, and it is the unit the code store holds and versions.
- **Canonical text**: what the formatter prints for a declaration. It is the stored form; whitespace never changes it.
- **CID**: a declaration's identity, `sha256("yabu/1\n" <> canonical text)`. The same content always gives the same CID.
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
  - `Kinoko.Universe` is the system's interface to universes: list, create, stage, read, eval, call, test. It is the only thing callers use.
  - The in-memory value is `Kinoko.Lang.Universe`, which is internal.
- **CodeDb**: the process that keeps one universe alive (`Kinoko.CodeDb`, a PersistentElmGenServer). It serializes check, promote and persist for that universe.
  - It is an implementation detail of `Kinoko.Universe`, which starts it on demand when a universe isn't running and routes to it.
  - Its `update/2` just applies `Kinoko.Lang` to the universe it holds.
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
- **PersistentElmGenServer**: an ElmGenServer whose **durable** state is written to Postgres under a **key** before each step's effects run.

## System

- **MCP**: the protocol agents use to drive universes, through `Kinoko.Universe`. The **REPL** (`Y.…` in iex) is the human front end to the same operations.
- **Deploy**: send a universe's code to a remote **endpoint** as source plus CIDs. The remote compares CIDs and rebuilds only what is new.
- **Rollback**: load an older commit's image.
- **Oracle / goldens**: the TS and Rust answers the port is tested against.
