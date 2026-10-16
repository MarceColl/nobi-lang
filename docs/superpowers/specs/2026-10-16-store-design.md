# Store: persistent app data — design

It builds on SQLite everywhere (`2026-10-16-sqlite-design.md`), deployments (piece 5) and the Elm effects runtime. Terms are defined in `docs/GLOSSARY.md`.

## Goal

Yabu apps persist data through `Cmd.store.*`. Rows belong to a **deployment**: each deployment has its own SQLite file with one table per model. Models evolve protobuf-style, add-only, and the checker enforces it at promotion. Read-modify-write is a pure transaction closure that runs atomically.

## Decisions (Marce)

- **Data is owned by the deployment.** A pin or rollback changes code, not data; staging and prod never share rows.
- **Storage:** one SQLite file per deployment (`.kinoko/data/<deployment>.db`), one table per model, real columns.
- **Evolution is protobuf-like and add-only.** An existing field never changes type and is never removed. A new field is either `Option<T>` (old rows read `None`) or mandatory with an explicit default (`replies : Int = 0`).
  - **Defaults apply only when decoding old rows.** Construction still lists every field.
- **`tx` takes a closure only.** The list form is dropped.
- **Querying in this piece:** `list`, `get`, and reads inside `tx`. There is no query language yet.

## Language

### Stored models

A **stored model** is a `defmodel` with an `id : Uuid` field. Only stored models can go through `Cmd.store.*` or `Tx`; anything else gets the checker error `"not-stored"`. Code never writes `id`: `insert` mints it, and a constructed value's `id` is ignored on insert.

### Field defaults

```
defmodel Forum.Post do
  id : Uuid
  title : String
  replies : Int = 0
  pinned : Bool = false
  tags : List<String> = []
end
```

- **Syntax:** `name : Type = <constant>`. A constant is a literal, a list or map of constants, a tuple of constants, a variant constructor applied to constants, or `Option.None` / `Option.Some(constant)`. Calls and references to other symbols are not allowed (`"bad-default"`).
- **Type:** the default is type-checked against the field's type.
- **Signature:** the model signature becomes `{:model, [{field, type, default | :none}]}`. Format and CID include defaults.

### Model evolution rule (checked at promotion)

For each stored model in a patch, compare it with the model's **latest committed version**:
- every existing field keeps exactly its type (`"model-evolution"`: "Forum.Post.title was String, cannot become Int; add a new field instead");
- no existing field is removed (`"model-evolution"`: "…cannot remove Forum.Post.title; leave it in place");
- every new field is `Option<…>` or has a default (`"model-evolution"`: "…new field replies : Int needs a default (replies : Int = 0) or an Option type").

Changing or adding a default on an existing field is allowed. The first commit of a model is unconstrained.

The rule reads the committed signature through the salsa memo like any other dependency, so a check stays incremental. It runs inside `Lang.Universe`'s promotion and stays pure.

### `Cmd.store` (types unchanged except `tx` and `Tx.delete`)

```
Cmd.store.insert(row : M, fn (id : Uuid) -> msg end)
Cmd.store.list(fn (rows : List<M>) -> msg end)            -- M from the callback type
Cmd.store.get(id : Uuid, fn (row : Option<M>) -> msg end)
Cmd.store.update(id : Uuid, row : M, fn (id : Uuid) -> msg end)   -- whole-row replace, last write wins
Cmd.store.delete(id : Uuid, fn (row : Option<M>) -> msg end)      -- returns the deleted row
Cmd.store.tx(fn (s : Store) -> (List<Tx.Op>, r) end,
             fn (result : Result<(List<Uuid>, r), String>) -> msg end)

Store.get(s, id : Uuid) : Option<M>       -- M from the expected type, like store.get
Store.list(s) : List<M>
Tx.insert(row : M) : Tx.Op
Tx.update(id : Uuid, row : M) : Tx.Op
Tx.delete(Model, id : Uuid) : Tx.Op       -- names the stored model (needs a table); was Tx.delete(row)
```

- **A failed operation** (store unavailable, schema error) delivers no message and shows the host's error banner. `tx` instead reports through its `Err` result.

## Runtime

### `Kinoko.Data`: per-deployment storage (outside `lib/kinoko/lang`)

- **One SQLite file per deployment,** opened lazily as an Ecto dynamic repo (`Kinoko.Data.Repo`) under a `DynamicSupervisor`, and registered by deployment name.
  - WAL mode, `busy_timeout` 5000 ms.
  - The file is created on first use.
- **Table per model:**
  - **Name mapping:** the symbol, lowercased, with `.` replaced by `__` (`Forum.Post` → `forum__post`), quoted. Anything outside `[a-z0-9_]` falls back to `m_<first 12 hex of sha256(symbol)>`, recorded in a `_kinoko_tables(symbol, table)` meta table.
  - **Columns:**
    - `id TEXT PRIMARY KEY` (canonical Uuid) and `_seq INTEGER` (insertion order);
    - `Int` and `Bool` → `INTEGER`, `String` and `Uuid` → `TEXT`;
    - `Option<scalar>` → the scalar's column type, nullable;
    - everything else (lists, maps, tuples, nested models, variants, `Option` of a compound) → `TEXT` holding canonical JSON (`Rt.Json`).
    - Column names are the field names, quoted.
- **Schema sync:**
  - Before the first store operation on a model under a given image, `Data.ensure(deployment, model, signature)` creates the table, or runs `ALTER TABLE ADD COLUMN` (with `DEFAULT` for defaulted scalars) for any field the table lacks.
  - It is cached per `(deployment, model, signature hash)`.
  - It never drops or alters columns. Older code reading a table with extra columns ignores them.
- **Decoding** is type-directed by the model signature of the image running the read. A column that is absent or NULL for a non-Option field takes the field's default (for rows written before the field existed). A value that can't be decoded is an error, never a silent wrong value.
- **`list`** is capped at 10,000 rows (`"too-many-rows"` error above that) and ordered by `_seq`.

### Transactions

- **The `tx` coordinator** is a short-lived process. It opens `BEGIN IMMEDIATE` on the deployment's file; SQLite then serializes writers, so concurrent transactions cannot conflict.
- **The body** runs in an Exec worker. The `Store` handle it receives is a runtime value. `Store.get`/`Store.list` send read requests to the coordinator, which runs them inside the open transaction, and reply. This lives in `Kinoko.Exec.Hooks`/`Kinoko.Data`, like the `always` hook; `Kinoko.Lang` stays pure.
- **After the body:**
  - the coordinator applies the returned ops in order, inserts minting ids, then commits, and replies `Ok((inserted_ids, r))`;
  - any error (body crash, timeout, a decode failure or `SQLITE_BUSY` after retries) rolls back and replies `Err(message)`;
  - `SQLITE_BUSY` is retried up to 3 times. That is safe, because the body is pure.

### Hosting

- **DeploymentLive** lowers `Cmd.store.*` to `Fx.task` effects that call `Kinoko.Data`, with the deployment's name. The callback is applied through `Universe.apply` as before.
- **The data's owner** is the deployment, whatever commit it serves, so pinned and following deployments use the same file.
- **The REPL and `Universe.eval`** have no deployment. There, store effects stay "not available" unless one is named (`Y.use_deployment(name)`), which is out of scope.

### Console

`/_/d/:name` shows the deployment's models: row counts and the table schema.

## Out of scope

- A query language, filters or indexes beyond the primary key and `_seq`.
- `blob` and `ai` effects.
- Data copy on fork.
- Data migrations beyond add-only.
- Multi-node.

## Testing

- **Language:**
  - defaults parse, format and get a CID, and are type-checked;
  - `"bad-default"` for non-constants;
  - `"not-stored"` for a model without `id`;
  - the evolution rule: retype, remove and a new non-defaulted field are refused; `Option` and defaulted fields are accepted; the first commit is unconstrained; a default change is accepted;
  - the signature change ripples correctly (the oracle stays green).
- **Data:**
  - create and sync tables, and add-column evolution;
  - rows written under v1 read under v2 with defaults;
  - Option and NULL;
  - compound JSON round-trip;
  - the list cap;
  - name mapping, including the hash fallback;
  - separate files per deployment.
- **Tx:**
  - the read-modify-write closure is atomic under concurrent callers (for example 20 concurrent increments end at 20);
  - a body crash rolls back;
  - a timeout rolls back;
  - inserted ids are returned in order.
- **End to end:** the forum fixture gains real data, with posts created through the UI and readable at `/post/:id`. A deployment pinned back to an older commit still reads data written by newer code (extra columns ignored).

## Done when

The tests pass, `mix precommit` is green, and the forum creates and lists posts on the dev server.
