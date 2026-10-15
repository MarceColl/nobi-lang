# CodeDb, CAS and MCP — design (piece 3)

Piece 3 of 7. It builds on piece 1 (`Kinoko.Lang`), piece 4 (`Kinoko.Exec`) and piece 2 (`PersistentElmGenServer`). Terms are defined in `docs/GLOSSARY.md`.

## Goal

Universes become the system's single point of interaction. A named universe (`"main"` by default) is owned by one **CodeDb** process, persisted, and reached by the REPL and by agents over **MCP** through the same functions. Declaration text lives in a global, process-free **CAS**. A universe stores only symbol → CID.

## Rules (from Marce, binding)

- `Kinoko.CodeDb` is the only place anything interacts with a universe. `Kinoko.Lang` becomes internal (CodeDb's pure core). `Kinoko.Exec` takes images, not universes.
- A universe stores only symbol → CID references: commits and staged patches. Definitions live in the CAS.
- The CAS is not serialized: plain functions over the Repo, callable from any process.
- Every derived computation (type checks, signatures) goes through salsa.

## Out of scope

- Fork and merge (piece 6). Every function already takes the universe name.
- Running apps or sending them messages (piece 5).
- Auth: the MCP endpoint is local-only, because the dev endpoint binds 127.0.0.1.
- A persisted build cache (see Later).
- Image eviction across universes. Images stay cached by hash, as today.

## Shape

```
REPL (Y.*) ──┐                 caller process                          CodeDb "main" (PersistentElmGenServer)
MCP /mcp  ───┼─▶ CodeDb.stage(u, id, src):                             update({:stage, id, entries}, universe)
             │     parse → canonical text → cid   (pure)                 └─ Lang: salsa check + promote (pure)
             │     Cas.put(texts)                  (Repo, concurrent)   durable: %{commits, staged} (symbol→cid only)
             │     GenServer.call({:stage, id, [{sym, cid, decl}]})  ─▶  written before the reply (piece 2)
             └─▶ CodeDb.eval(u, src):
                   {sigs, committed} = call(:snapshot)  ─────────────▶  read-only call
                   check expr against sigs             (pure, caller)
                   Exec.load(committed) → image        (cached by image hash)
                   Exec worker runs it                 (bounded, caller-owned)
```

## Components

### `Kinoko.Cas` (new, `lib/kinoko/cas.ex`)

- **Table:** `declarations(cid text primary key, text text not null, inserted_at timestamptz not null default now())`. It is append-only and global. Nothing is ever garbage-collected for now.
- `put([{cid, text}])` inserts with `on_conflict: :nothing`. It is idempotent and needs no process.
- `get([cid]) :: %{cid => text}`. Missing CIDs are simply absent from the result.
- **Writes happen before the universe references them**, so a crash leaves at worst an unreferenced row, never a dangling reference.

### `Kinoko.Lang` (changed: internal, text-free universe)

- **No `texts` field.** `Lang.Universe` drops its `texts` map. Canonical text is derived on demand with `Format.decl(decl)`, and `read` formats the committed or staged declaration.
- **`restore`** becomes `restore(commits, staged, decls)`, where `decls :: %{cid => decl}` is the parsed declarations for every CID referenced. It replays the commits, rebuilds committed code, then restages the staged patches in their original order. It returns `{:ok, u} | {:error, [reason]}`.
- **`stage_entries(u, id, entries)`** stages already-parsed entries, `{:live, decl}` or `{:gone, symbol}`. The string-taking `Lang.stage/4` stays for internal tests only.
- **`durable(u) :: %{commits: [commit], staged: [{id, [{symbol, cid | :gone}]}]}`**: the symbol → CID projection only. Staged patches keep their staging order.
- The moduledoc states that `Kinoko.Lang` is internal and that callers use `Kinoko.CodeDb`.

### `Kinoko.CodeDb` (new, `lib/kinoko/code_db.ex`, plus `code_db/server.ex`)

- **Process:** a `PersistentElmGenServer` under `Kinoko.Elm.Supervisor`, keyed `"universe:" <> name`. It starts lazily on first use, through `whereis` or else `start/3`.
- **`durable/1` = `Lang.durable/1`.**
  - `encode` is `term_to_binary(durable, compressed: 6)`.
  - `decode` uses `binary_to_term(.., [:safe])`, collects every CID referenced, calls `Cas.get`, parses each text, and calls `Lang.restore`. A missing CID or a parse failure raises with the CID, so the boot refuses.
  - The salsa memo is never persisted; it refills lazily.
- **Messages:** the server's `update/2` is pure and only applies `Lang`:
  - `{:stage, id, entries}`, `{:unstage, id}`;
  - read requests: `:symbols`, `{:read, symbol}`, `:staged`, `:history`, `:snapshot`.

  `:snapshot` returns `%{committed: %{symbol => %{cid, typed, signature}}, signatures: sigs}`, everything a caller needs to type-check an expression and build an image.
- **Public API.** Every function takes the universe name first, default `"main"`:

  ```elixir
  CodeDb.stage(universe \\ "main", id, source, opts \\ [remove: [symbol]]) :: {:promoted, [id]} | {:staged, [reason]}
  CodeDb.unstage(universe, id) :: :ok | :not_found
  CodeDb.staged(universe)   :: [%{id, source, reasons}]
  CodeDb.read(universe, symbol) :: {:ok, text} | :error
  CodeDb.symbols(universe)  :: [%{symbol, cid, signature}]
  CodeDb.history(universe)  :: [commit]
  CodeDb.eval(universe, expr_source, opts) :: {:ok, value, type} | {:error, reason}
  CodeDb.call(universe, symbol, args, opts) :: {:ok, value} | {:error, reason}
  CodeDb.test(universe, symbol, opts) :: :ok | {:error, reason}
  ```

- **`stage` runs its first half in the caller**, then calls the server:
  1. parse, canonicalize and hash, with no server involved;
  2. `Cas.put`;
  3. `GenServer.call({:stage, id, entries})`.

  A parse error returns `{:staged, [parse reason]}`, and the server unstages a previous patch under that id, which is piece 1's ruling.
- **`eval`, `call` and `test`** fetch `:snapshot`, then type-check and run in the caller through `Exec`. The server is never blocked by evaluation.
- **Image memoization** stays content-keyed: Exec's image cache by image hash is the memo, so an unchanged committed state never recompiles, in any universe. This is not a per-CodeDb salsa query, because the image is already a pure function of the committed CIDs, which is exactly what its key is.

### `Kinoko.Exec` (changed)

- `load`, `call`, `eval` and `test` take a committed map or an image, never a universe.
- `eval` takes the signatures for checking: `Exec.eval(snapshot, source, opts)`.
- Moduledoc: hosts reach it through CodeDb.

### `Kinoko.Repl` (changed)

The Agent is gone. `Y.*` calls `Kinoko.CodeDb` on `"main"`, or another universe via `Y.use(name)`. Your session state survives restarts, and agents see the same `main`.

### MCP (new, `lib/kinoko_web/controllers/mcp_controller.ex` plus `lib/kinoko_web/mcp/*`)

- **Transport:** `POST /mcp`, JSON-RPC 2.0 over the streamable-HTTP MCP transport, with plain JSON responses and no SSE. It goes through a new `:mcp` pipeline that accepts JSON and skips CSRF.
- **Methods:**
  - `initialize`, returning protocol version, server info, a `tools` capability, and `instructions`;
  - `notifications/initialized`, answered with 202 and an empty body;
  - `tools/list`, `tools/call` and `ping`.
- **Tools.** Each has a JSON schema and an optional `universe` argument, default `"main"`:
  - `stage_patch`: `id`, `source`, optional `remove`;
  - `unstage`: `id`;
  - `list_staged`;
  - `read`: `symbol`;
  - `symbols`;
  - `eval`: `expression`;
  - `test`: `symbol`;
  - `history`.

  Each one maps onto one `CodeDb` function. Results are text content, readable by agents, and a promotion and a staging read differently. A tool error is `isError: true` with the reasons.
- **Instructions:** adapted from the TS MCP's server instructions. They cover the syntax you cannot guess, the stage → read verdict → restage loop, and "a patch replaces the declarations it names whole". The stdlib list is generated from `Rt.Stdlib`, so it never drifts.
- **Robustness:** malformed JSON gives `-32700`; unknown methods `-32601`; invalid params `-32602`. A tool that raises becomes `isError: true`, never a 500.

## Durability and concurrency

- **CAS writes** are concurrent and idempotent, with no process.
- **CodeDb serializes** check, promote and persist only. Parsing and the CAS writes happen in callers, and evaluation happens in callers' Exec workers.
- **A crash between `Cas.put` and the stage** leaves only unreferenced CAS rows.
- **A timed-out stage call** has an unknown outcome (piece 2's at-most-once). Agents restage the same id, which is idempotent by design.

## Later (recorded, not built)

- **Persisted build cache:** a content-keyed table for signatures (keyed by CID) and check results (keyed by CID plus the hash of the signatures consulted). It would need no process and no invalidation, would be shared across universes and deploys, and would make forks start warm. Build it when a measured boot is slow.
- **A shared, lock-free cache of parsed declarations by CID** (ETS), for the same reason.
- **Fork and merge** (piece 6), **image eviction**, and **auth** for non-local MCP.

## Testing

- **CAS:** put is idempotent, `get` returns only the CIDs that exist, and concurrent puts of the same CID both succeed.
- **Lang:** `durable` holds only symbol → CID; `restore(commits, staged, decls)` round-trips (committed code, staged patches and reasons all equal) and refuses a missing CID; `read` and `staged` render through `Format`; all existing piece-1 tests stay green.
- **CodeDb:**
  - stage, promote and read;
  - a broken patch is staged with reasons, fixed, then promoted;
  - a restart keeps both commits and staged patches, and the memo refills;
  - two universes are independent;
  - a parse error never calls the server, which a trace or counter asserts;
  - `eval`, `call` and `test` work against the current commit, while a long eval doesn't block a concurrent stage;
  - no text in the persisted row: decode the stored binary and assert there is no `text` or `decl`.
- **MCP**, driven through `Phoenix.ConnTest` POSTs:
  - the handshake;
  - `tools/list` shape;
  - each tool's happy path and error path;
  - malformed JSON;
  - an unknown method;
  - a raising tool becomes `isError`.

  Plus one end-to-end script that drives the counter corpus through `/mcp` like an agent would.
- **REPL:** the walkthrough runs on CodeDb, and a restart in the middle of a session keeps the state.

## Done when

The tests above pass, `mix precommit` is green, an MCP client configured with `http://127.0.0.1:4000/mcp` can stage and evaluate the counter app, and `docs/GLOSSARY.md` gains **CAS**.
