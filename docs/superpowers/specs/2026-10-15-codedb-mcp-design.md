# Universe, CodeDb, CAS and MCP — design (piece 3)

Piece 3 of 7. It builds on piece 1 (`Nobi.Lang`), piece 4 (`Nobi.Exec`) and piece 2 (`PersistentElmGenServer`). Terms are defined in `docs/GLOSSARY.md`.

## Goal

Universes become the system's single point of interaction. **`Nobi.Universe`** is the interface: list, create, stage, read, eval, call and test any named universe (`"main"` by default). The REPL and agents over **MCP** use only it. Behind it, each running universe is kept alive by one **CodeDb** process, which Universe starts on demand and routes to. Declaration text lives in a global, process-free **CAS**. A universe stores only symbol → CID.

## Rules (from Marce, binding)

- `Nobi.Universe` is the only place anything interacts with a universe. CodeDb is its implementation detail. `Nobi.Lang` becomes internal (CodeDb's pure core). `Nobi.Exec` takes images, not universes.
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
MCP /mcp  ───┼─▶ Universe.stage(u, id, src):                           update({:stage, id, entries}, universe)
             │     parse → canonical text → cid   (pure)                 └─ Lang: salsa check + promote (pure)
             │     Cas.put(texts)                  (Repo, concurrent)   durable: %{commits, staged} (symbol→cid only)
             │     GenServer.call({:stage, id, [{sym, cid, decl}]})  ─▶  written before the reply (piece 2)
             └─▶ Universe.eval(u, src):
                   {sigs, committed} = call(:snapshot)  ─────────────▶  read-only call
                   check expr against sigs             (pure, caller)
                   Exec.load(committed) → image        (cached by image hash)
                   Exec worker runs it                 (bounded, caller-owned)
```

## Components

### `Nobi.Cas` (new, `lib/nobi/cas.ex`)

- **Table:** `declarations(cid text primary key, text text not null, inserted_at timestamptz not null default now())`. It is append-only and global. Nothing is ever garbage-collected for now.
- `put([{cid, text}])` inserts with `on_conflict: :nothing`. It is idempotent and needs no process.
- `get([cid]) :: %{cid => text}`. Missing CIDs are simply absent from the result.
- **Writes happen before the universe references them**, so a crash leaves at worst an unreferenced row, never a dangling reference.

### `Nobi.Lang` (changed: internal, text-free universe)

- **No `texts` field.** `Lang.Universe` drops its `texts` map. Canonical text is derived on demand with `Format.decl(decl)`, and `read` formats the committed or staged declaration.
- **`restore`** becomes `restore(commits, staged, decls)`, where `decls :: %{cid => decl}` is the parsed declarations for every CID referenced. It replays the commits, rebuilds committed code, then restages the staged patches in their original order. It returns `{:ok, u} | {:error, [reason]}`.
- **`stage_entries(u, id, entries)`** stages already-parsed entries, `{:live, decl}` or `{:gone, symbol}`. The string-taking `Lang.stage/4` stays for internal tests only.
- **`durable(u) :: %{commits: [commit], staged: [{id, [{symbol, cid | :gone}]}]}`**: the symbol → CID projection only. Staged patches keep their staging order.
- The moduledoc states that `Nobi.Lang` is internal and that callers use `Nobi.Universe`.

### Universe registry (new table, behind `Nobi.Universe`)

- **Table:** `universes(name text primary key, parent text null, forked_at_commit integer null, created_at timestamptz not null default now())`. It answers "which universes exist", including ones that aren't running.
- `parent` and `forked_at_commit` stay null until piece 6 (fork lineage).
- Like the CAS, it has no process. Create is an insert, and two concurrent creates of one name give one `:ok` and one `{:error, :exists}`.
- **Explicit creation:** `main` is created at application boot, idempotently. Any other name must be created first. Using an unknown name returns `{:error, :no_such_universe}`.

### `Nobi.Universe` (new, `lib/nobi/universe.ex`): the interface

A stateless module that routes. Callers never see processes or registries.

- **Existence** is checked against the `universes` table, cached per call path as cheaply as possible, for example only when no CodeDb is running for the name.
- **Writes** find the universe's CodeDb or start it, via `Nobi.Elm.Registry` and `PersistentElmGenServer.start/3`, then call it.
- **Reads** call the CodeDb.
- **`eval`, `call` and `test`** take a snapshot from the CodeDb and run in the caller.

### `Nobi.CodeDb` (new, `lib/nobi/code_db.ex`): the process

- **Process:** a `PersistentElmGenServer` under `Nobi.Elm.Supervisor`, keyed `"universe:" <> name`. Only `Nobi.Universe` starts it or talks to it.
- **`durable/1` = `Lang.durable/1`.**
  - `encode` is `term_to_binary(durable, compressed: 6)`.
  - `decode` uses `binary_to_term(.., [:safe])`, collects every CID referenced, calls `Cas.get`, parses each text, and calls `Lang.restore`. A missing CID or a parse failure raises with the CID, so the boot refuses.
  - The salsa memo is never persisted; it refills lazily.
- **Messages:** the server's `update/2` is pure and only applies `Lang`:
  - `{:stage, id, entries}`, `{:unstage, id}`;
  - read requests: `:symbols`, `{:read, symbol}`, `:staged`, `:history`, `:snapshot`.

  `:snapshot` returns `%{committed: %{symbol => %{cid, typed, signature}}, signatures: sigs}`, everything a caller needs to type-check an expression and build an image.
### Public API (`Nobi.Universe`)

Every function takes the universe name first. A name with no universe gives `{:error, :no_such_universe}`.

```elixir
Universe.list() :: [%{name, parent, created_at}]
Universe.create(name) :: :ok | {:error, :exists | :bad_name}
Universe.stage(universe, id, source, opts \\ [remove: [symbol]]) :: {:promoted, [id]} | {:staged, [reason]}
Universe.unstage(universe, id) :: :ok | :not_found
Universe.staged(universe)   :: [%{id, source, reasons}]
Universe.read(universe, symbol) :: {:ok, text} | :error
Universe.symbols(universe)  :: [%{symbol, cid, signature}]
Universe.history(universe)  :: [commit]
Universe.eval(universe, expr_source, opts) :: {:ok, value, type} | {:error, reason}
Universe.call(universe, symbol, args, opts) :: {:ok, value} | {:error, reason}
Universe.test(universe, symbol, opts) :: :ok | {:error, reason}
```

- **`Universe.stage` runs its first half in the caller**, then calls the CodeDb:
  1. parse, canonicalize and hash, with no server involved;
  2. `Cas.put`;
  3. `GenServer.call({:stage, id, entries})`.

  A parse error returns `{:staged, [parse reason]}`, and the server unstages a previous patch under that id, which is piece 1's ruling.
- **`eval`, `call` and `test`** fetch `:snapshot`, then type-check and run in the caller through `Exec`. The server is never blocked by evaluation.
- **Image memoization** stays content-keyed: Exec's image cache by image hash is the memo, so an unchanged committed state never recompiles, in any universe. This is not a per-CodeDb salsa query, because the image is already a pure function of the committed CIDs, which is exactly what its key is.

### `Nobi.Exec` (changed)

- `load`, `call`, `eval` and `test` take a committed map or an image, never a universe.
- `eval` takes the signatures for checking: `Exec.eval(snapshot, source, opts)`.
- Moduledoc: hosts reach it through `Nobi.Universe`.

### `Nobi.Repl` (changed)

The Agent is gone. `Y.*` calls `Nobi.Universe` on `"main"`, or another universe via `Y.use(name)`. Your session state survives restarts, and agents see the same `main`.

### MCP (new, `lib/nobi_web/controllers/mcp_controller.ex` plus `lib/nobi_web/mcp/*`)

- **Transport:** `POST /mcp`, JSON-RPC 2.0 over the streamable-HTTP MCP transport, with plain JSON responses and no SSE. It goes through a new `:mcp` pipeline that accepts JSON and skips CSRF.
- **Methods:**
  - `initialize`, returning protocol version, server info, a `tools` capability, and `instructions`;
  - `notifications/initialized`, answered with 202 and an empty body;
  - `tools/list`, `tools/call` and `ping`.
- **Tools.** Each has a JSON schema and an optional `universe` argument, default `"main"`:
  - `list_universes`;
  - `create_universe`: `name`;
  - `stage_patch`: `id`, `source`, optional `remove`;
  - `unstage`: `id`;
  - `list_staged`;
  - `read`: `symbol`;
  - `symbols`;
  - `eval`: `expression`;
  - `test`: `symbol`;
  - `history`.

  Each one maps onto one `Nobi.Universe` function. Results are text content, readable by agents, and a promotion and a staging read differently. A tool error is `isError: true` with the reasons.
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
- **Universe and CodeDb:**
  - list and create; an unknown name gives `:no_such_universe`; `main` exists after boot; concurrent creates give exactly one `:ok`;
  - a stopped universe is restarted on demand by the next call;
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
- **REPL:** the walkthrough runs on `Nobi.Universe`, and a restart in the middle of a session keeps the state.

## Done when

The tests above pass, `mix precommit` is green, an MCP client configured with `http://127.0.0.1:4000/mcp` can stage and evaluate the counter app, and `docs/GLOSSARY.md` gains **CAS**.

## Amendments from the final review

Rulings made in the final review that change what this spec says above.

- **Supervised restarts never loop (`PersistentElmGenServer.start/3`).** The supervisor restarts a crashed `start/3` child through the same start function, which tells its first run from a restart. A restart that finds the key already registered to a live process (a caller started it again before the restart ran) returns `:ignore`, so `DynamicSupervisor` drops the child and the caller's process alone serves the key. A restart that fails to boot (the DB is down, or a stored state is corrupt) is logged and also `:ignore`d; the next `start/3` is a first start and returns the boot error to its caller. The first start keeps its contract (`{:error, {:already_started, pid}}`, boot errors). `CodeDb.start/1`'s workaround is gone: `Nobi.Universe` starts a CodeDb with `start/3`. A boot the database fails (`DBConnection.ConnectionError`, `DBConnection.OwnershipError`, `Postgrex.Error`) is `unavailable`, not `internal`.
- **`/mcp` is mounted only where enabled.** The router mounts the `/mcp` scope only when `Application.compile_env(:nobi, :mcp_enabled, false)` is true: `config/dev.exs` and `config/test.exs` set it; prod leaves it off until the endpoint has auth (still deferred; see `NobiWeb.McpController`).
- **Degraded boot.** Boot never refuses on type errors. `Nobi.Lang.restore/3` (still pure) returns `{:degraded, u, reasons}` when committed code no longer typechecks: committed code is kept as stored (symbol → CID, declarations), the failing symbols and reasons are kept, staging and unstaging work, and a patch promotes only when the whole image typechecks with it, which makes the universe healthy again (then every staged patch is tried). Reads (`read`, `symbols`, `staged`, `history`) work; `eval`, `call` and `test` return `{:error, %{code: "degraded", message: ...}}` naming the failing symbols. `Nobi.Universe.health/1 :: :ok | {:degraded, [reason]}`, the MCP tool `health` and `Y.health()` report it, and `list_universes` and `symbols` mention it. Missing CAS rows and unparsable CAS text still refuse boot (corruption), and such a refusal after a crash is dropped by the supervisor rather than retried (first amendment).
- **Eval fast path.** The CodeDb keeps its committed image's hash in its state (recomputed when a stage promotes) and answers `:image_key` with `{:ok, hash, signatures}` without copying committed code. `eval`, `call` and `test` use it and fetch the full `:snapshot` only when `Nobi.Exec.loaded/1` has no image of that hash. On a 3000-def universe, eval with the image loaded takes about 0.2 ms against about 11 ms through the whole snapshot (median of 50; `test/nobi/universe/eval_latency_perf_test.exs`, tagged `:perf`).
