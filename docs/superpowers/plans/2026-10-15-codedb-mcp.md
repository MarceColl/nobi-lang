> Storage moved to SQLite on 2026-10-16; see docs/superpowers/specs/2026-10-16-sqlite-design.md.

# Universe, CodeDb, CAS and MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Universes become the system's only point of interaction:
- `Nobi.Universe` is the interface.
- `Nobi.CodeDb` is the per-universe persistent process behind it.
- A process-free CAS holds declaration text, and a universe stores only symbol → CID.
- The REPL and an MCP endpoint at `/mcp` are thin adapters.

**Architecture:**
- **Pure core:** `Nobi.Lang`, made text-free and internal.
- **Process-free DB modules:** `Nobi.Cas` (`declarations` table) and `Nobi.Universe.Registry` (`universes` table).
- **Processes:** `Nobi.CodeDb`, a `PersistentElmGenServer` keyed `"universe:<name>"` that serializes only check, promote and persist.
- **Routing:** `Nobi.Universe`, stateless. Writes do parse and `Cas.put` in the caller, then call CodeDb. Reads call CodeDb. `eval`, `call` and `test` take a snapshot and run through `Nobi.Exec` in the caller.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto/Postgres, `PersistentElmGenServer` (piece 2), `Nobi.Exec` (piece 4), ExUnit with the SQL sandbox, Phoenix.ConnTest.

**Spec:** `docs/superpowers/specs/2026-10-15-codedb-mcp-design.md`. Glossary: `docs/GLOSSARY.md`.

## Global Constraints

- `Nobi.Universe` is the only public API for universes. `Nobi.Lang` is internal: only `Nobi.CodeDb` and `Nobi.Universe` call it. `Nobi.Exec` takes a snapshot or an image, never a universe.
- **Universe durable state:** `%{commits: [commit], staged: [{id, [{symbol, cid | :gone}]}]}`, where commit = `%{ids: [id], entries: [{:live, symbol, cid} | {:gone, symbol}]}`. No declaration text and no parsed declarations, ever.
- **CAS table:** `declarations(cid text primary key, text text not null, inserted_at timestamptz not null default now())`. Append-only; inserts use `on_conflict: :nothing`; there is no process.
- **Universes table:** `universes(name text primary key, parent text null, forked_at_commit integer null, created_at timestamptz not null default now())`. No process. `main` is created at app boot, idempotently.
- **Universe names** match `~r/^[a-z0-9][a-z0-9_-]{0,62}$/`; anything else is `{:error, :bad_name}`. An unknown name is `{:error, :no_such_universe}`.
- **CodeDb key:** `"universe:" <> name`, run under `Nobi.Elm.Supervisor` via `PersistentElmGenServer.start/3`. It uses `durable/1`, `encode` = `term_to_binary(durable, compressed: 6)`, and `decode` = `binary_to_term(b, [:safe])` followed by a CAS fetch, a parse and `Lang.restore`.
- **Write order:** `Cas.put` happens before the CodeDb call that references those CIDs.
- **Salsa is never persisted.**
- `mix precommit` must be green after every task. VCS is jj: end each task with `jj commit -m "<msg>"`.

## Review Focus

1. **Two concurrent stages to the same universe from different processes.** Expected: serialized in the CodeDb; both get correct verdicts; history is consistent. *Task 4.*
2. **A universe whose CodeDb died, then a call.** Expected: transparently restarted from the DB, with staged patches restored and reasons recomputed. *Task 4.*
3. **A CAS row missing for a referenced CID** (corruption). Expected: boot refuses with an error naming the CID; the universe call returns `{:error, %{code: "internal", …}}` and doesn't crash the caller. *Task 4.*
4. **A long `eval` at the same time as `stage`.** Expected: the stage completes without waiting for the eval. *Task 4.*
5. **MCP: malformed JSON, a batch request, an unknown tool, a missing argument, a tool that raises.** Expected: proper JSON-RPC errors or `isError` results, never a 500. *Task 6.*

---

### Task 1: CAS and universe registry tables

**Files:**
- Create: two migrations (`create_declarations`, `create_universes`), `lib/nobi/cas.ex`, `lib/nobi/universe/registry.ex`
- Test: `test/nobi/cas_test.exs`, `test/nobi/universe/registry_test.exs`

**Interfaces:**

```elixir
Nobi.Cas.put([{cid :: String.t(), text :: String.t()}]) :: :ok
Nobi.Cas.get([cid]) :: %{cid => text}                      # missing cids absent
Nobi.Universe.Registry.create(name, opts \\ []) :: :ok | {:error, :exists | :bad_name}
Nobi.Universe.Registry.exists?(name) :: boolean
Nobi.Universe.Registry.list() :: [%{name, parent, forked_at_commit, created_at}]   # by name
Nobi.Universe.Registry.ensure_main() :: :ok                 # idempotent; called at boot
```

- [ ] **Step 1: failing tests.**
  - `put` is idempotent: the same pair twice gives one row.
  - `get` returns only the CIDs that exist.
  - Concurrent puts of the same CID from 10 tasks all return `:ok`.
  - `create`, then `exists?` and `list`.
  - A duplicate create gives `:exists`; a bad name gives `:bad_name`.
  - Concurrent creates give exactly one `:ok`.
  - `ensure_main` twice succeeds.
- [ ] **Step 2:** Implement. Call `Registry.ensure_main()` from `Nobi.Application` after the Repo starts, through a one-shot `Task` child, or another way that doesn't block boot if the DB is down. Log the failure and let the first `Universe` call retry it. Document the choice.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "feat: CAS and universe registry tables"`.

### Task 2: Text-free `Lang` universe

**Files:** modify `lib/nobi/lang/universe.ex` and `lib/nobi/lang.ex`, plus the piece-1 tests that touch `texts`/`text`/`restore`.

**Interfaces:**

```elixir
Nobi.Lang.durable(u) :: %{commits: [commit], staged: [{id, [{symbol, cid | :gone}]}]}
Nobi.Lang.restore(commits, staged, decls :: %{cid => decl}) :: {:ok, u} | {:error, [reason]}
Nobi.Lang.stage_entries(u, id, [{:live, decl} | {:gone, symbol}]) :: {u, verdict}
Nobi.Lang.prepare(source, opts \\ [remove: [symbol]]) :: {:ok, entries, [{cid, text}]} | {:error, [reason]}   # pure: parse + canonical text + cid; used by Universe before Cas.put
Nobi.Lang.snapshot(u) :: %{committed: %{symbol => %{cid, decl, typed, signature}}, signatures: sigs}
```

- [ ] **Step 1: failing tests.**
  - `durable(u)` contains no binaries other than ids, symbols and CIDs. Walk the term: every binary must be an id, a symbol or a 64-hex CID.
  - `restore(durable.commits, durable.staged, decls)` reproduces committed code, staged patches and reasons. Test on a universe with commits, one staged broken patch, one tombstone and one restaged id.
  - `restore` with a missing CID returns `{:error, [%{code: "restore", …}]}`.
  - `prepare` returns the same CIDs that `Cid.of` gives.
- [ ] **Step 2:** Implement.
  - Remove the `texts` field.
  - `read`/`text` format the declaration.
  - `restore/2`'s old callers move to `restore/3`.
  - Piece-1 tests that relied on texts adapt. Any change in what they assert must be called out in the report.
  - The moduledoc says `Nobi.Lang` is internal and callers use `Nobi.Universe`.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "refactor(lang): text-free universe, durable/restore, prepare, snapshot"`.

### Task 3: `Exec` takes snapshots

**Files:** modify `lib/nobi/exec.ex` and `lib/nobi/repl.ex` (keep it compiling for now); update the `test/nobi/exec*` tests.

**Interfaces:**

```elixir
Nobi.Exec.load(snapshot | committed_map, opts) :: {:ok, image} | {:error, reason}
Nobi.Exec.call(snapshot | image, symbol, args, opts)
Nobi.Exec.eval(snapshot, source, opts)      # checks source against snapshot.signatures
Nobi.Exec.test(snapshot | image, symbol, opts)
```

- [ ] **Step 1:** Change the signatures. The tests build a snapshot with `Lang.snapshot(u)` from a staged universe.
- [ ] **Step 2:** `Exec` must not call any `Nobi.Lang` function that takes a universe. Document this in the moduledoc. The goldens stay green.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "refactor(exec): take snapshots, not universes"`.

### Task 4: `Nobi.CodeDb` and `Nobi.Universe`

**Files:** create `lib/nobi/code_db.ex` and `lib/nobi/universe.ex`; tests `test/nobi/universe_test.exs` and `test/nobi/code_db_test.exs`.

**Interfaces:** the spec's public API, exactly:

```elixir
Universe.list/0, create/1, stage/4, unstage/2, staged/1, read/2, symbols/1, history/1, eval/3, call/4, test/3
```

CodeDb messages: `{:call, from, {:stage, id, entries}}`, `{:unstage, id}`, `:symbols`, `{:read, symbol}`, `:staged`, `:history` and `:snapshot`. It replies through `Effect.reply`.

- [ ] **Step 1: failing tests.** Async false, with the shared sandbox. Use a unique universe name per test, created in setup.
  - Stage, promote and read.
  - A broken patch is staged with reasons, fixed, then promoted.
  - **Restart:** stop the CodeDb; the next call restarts it with commits and staged patches intact.
  - Two universes are independent.
  - A parse error never reaches the server: the CodeDb `seq` is unchanged and no row is written.
  - `eval`, `call` and `test` work against the current commit.
  - The persisted row decodes to symbol → CID only.
  - An unknown universe gives `:no_such_universe`.
  - The Review Focus cases 1–4. For case 4: start a 2 s eval in a Task, stage meanwhile, and assert the stage returns quickly.
- [ ] **Step 2:** Implement.
  - **`Universe` routing:**
    - existence check via `Registry.exists?`, skipped when a CodeDb is already running;
    - `ensure_started` via `PersistentElmGenServer.whereis` or else `start/3`. A start race returns `{:error, {:already_started, pid}}`; treat it as found.
    - Writes: `Lang.prepare`, then `Cas.put`, then call. Reads: call. `eval`/`call`/`test`: call `:snapshot`, then `Exec`.
  - **CodeDb:**
    - `durable/1` = `Lang.durable/1`;
    - `decode` collects the CIDs, then `Cas.get`, parses, and calls `Lang.restore/3`. On a missing CID or a parse failure it raises with the CID.
    - `Universe` turns a boot failure into `{:error, %{code: "internal", message}}`, so the caller survives.
  - **Call timeout:** `:infinity` for stage, since the server is the serialization point. 5 s for reads.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "feat: Nobi.Universe interface over per-universe CodeDb"`.

### Task 5: REPL on `Nobi.Universe`

**Files:** modify `lib/nobi/repl.ex` and `test/nobi/repl_test.exs`.

- [ ] **Step 1:** Remove the Agent.
  - `Y.*` targets the current universe: `"main"` by default; `Y.use(name)` switches, and `Y.universes()` / `Y.create(name)` are new.
  - The current-universe choice is per iex session: the process dictionary of the shell process is fine here, because the REPL isn't the pure tree.
  - `Y.reset()` is removed; document creating a fresh universe instead.
- [ ] **Step 2:** The tests use a fresh universe per test via `Y.create` plus `Y.use`. Keep the walkthrough test, and add: a restart of `main`'s CodeDb mid-session keeps state.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "feat(repl): drive universes through Nobi.Universe"`.

### Task 6: MCP endpoint

**Files:**
- Create `lib/nobi_web/controllers/mcp_controller.ex`, `lib/nobi_web/mcp/{protocol,tools,instructions}.ex`
- Modify `lib/nobi_web/router.ex` (new `:mcp` pipeline: `accepts ["json"]`, no CSRF or session)
- Test: `test/nobi_web/mcp_test.exs`

**Interfaces:** `POST /mcp`, JSON-RPC 2.0.
- **Methods:**
  - `initialize`: `protocolVersion` echoes the client's when it's one we support, else `"2025-06-18"`; `serverInfo` is `%{name: "nobi", version}`; `capabilities` is `%{tools: %{}}`; plus `instructions`.
  - `notifications/*`: answered with 202 and an empty body.
  - `ping`, `tools/list` and `tools/call`.
- **Tools.** Each has an optional `universe` argument, default `"main"`:
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
- **Results:** `%{content: [%{type: "text", text: …}], isError: bool}`. The text is agent-readable:
  - a verdict reads as `promoted: a, b` or `staged:` followed by `- symbol [code] message` lines;
  - eval reads as `value : type`.

- [ ] **Step 1: failing tests**, through `Phoenix.ConnTest`:
  - the handshake;
  - `tools/list`: names and that each has an `inputSchema`;
  - every tool's happy path and error path;
  - the Review Focus 5 cases;
  - an end-to-end flow: create a universe, stage the counter corpus, eval `Counter.update(…)`, stage a broken def, read its reasons, fix it, and see it promote.
- [ ] **Step 2:** Implement.
  - `Protocol` is pure: decode a request, dispatch, encode a response.
  - `Tools` maps arguments onto `Nobi.Universe` and formats results, reusing `Exec.show` and `Format.type`.
  - `Instructions` adapts the TS server instructions (shown in this session's MCP list for `nobi`: syntax you cannot guess, the loop, rework costs). It drops anything about features we don't have yet (apps hosting, store, deploy, decide, PRs) and generates the stdlib list from `Rt.Stdlib`'s table.
  - A raised exception inside a tool becomes `isError: true` with the message.
- [ ] **Step 3:** `mix precommit`, then `jj commit -m "feat(web): MCP endpoint over Nobi.Universe"`.
