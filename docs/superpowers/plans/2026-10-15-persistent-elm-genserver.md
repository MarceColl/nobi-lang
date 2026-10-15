# PersistentElmGenServer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An `ElmGenServer` whose state survives restarts. It writes append-only to Postgres before each step's effects, resumes by key, and supports version migration.

**Architecture:**
- `Runtime` gets an `on_step` hook that runs before effects are performed.
- `Kinoko.Elm.Store` reads and writes the `elm_states` table through `Kinoko.Repo`.
- `Kinoko.PersistentElmGenServer` wires the hook to `Store`. It handles boot (`latest` → decode → migrate → resume, or `init`) and registers each process by key in a `Registry`.

**Tech Stack:** Elixir, Ecto SQL with Postgres, a `Registry`, ExUnit with the SQL sandbox.

**Spec:** `docs/superpowers/specs/2026-10-15-persistent-elm-genserver-design.md`

## Global Constraints

- **Table:** `elm_states(key text not null, seq bigint not null, version integer not null, state bytea not null, inserted_at timestamptz not null default now())`, with primary key `(key, seq)`. Append-only: the code never updates a row. `prune` is the only delete.
- **Decoding:** `:erlang.binary_to_term(b, [:safe])` by default. Never create atoms from stored data.
- **Ordering:** `on_step` runs after `update`/`init` and before any effect is performed. A raise in it propagates, so the host crashes and nothing is performed.
- **Existing behaviour:** the existing `ElmGenServer`, `ElmLiveView` and `Runtime` tests must stay green, unchanged.
- **Registry:** `Kinoko.Elm.Registry`, a unique-keys `Registry` started in `Kinoko.Application`.
- **Pruning:** `keep` defaults to 100.
- `mix precommit` must be green after every task. VCS is jj: end each task with `jj commit -m "<msg>"`.

## Review Focus

1. **A state holding pids, refs or funs** (for example `from` in a waiting list). Expected: `term_to_binary` stores it; after a restart the stale pids are harmless and the server boots. Documented. *Task 3.*
2. **Two `start_link` calls for the same key.** Expected: the second returns `{:error, {:already_started, pid}}`, and nothing is double-written. *Task 3.*
3. **A DB outage during a step.** Expected: the server crashes, no effect from that step is performed, and a restart resumes the last written state. *Task 3.*
4. **A large state** (multi-MB). Expected: it is written as `bytea` without trouble, and one row per changed step. Note the cost in the moduledoc. *Task 3.*
5. **`migrate` returns a state that fails `encode`.** Expected: boot crashes with a clear error. *Task 3.*

---

### Task 1: `elm_states` migration and `Kinoko.Elm.Store`

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_elm_states.exs`
- Create: `lib/kinoko/elm/store.ex`
- Test: `test/kinoko/elm/store_test.exs`, using `Kinoko.DataCase`

**Interfaces:**

```elixir
Kinoko.Elm.Store.append(key :: String.t(), seq :: non_neg_integer, version :: pos_integer, state :: binary) :: :ok   # raises on failure
Kinoko.Elm.Store.latest(key) :: {:ok, %{seq: integer, version: integer, state: binary}} | :none
Kinoko.Elm.Store.history(key, limit \\ 50) :: [%{seq, version, state, inserted_at}]    # newest first
Kinoko.Elm.Store.prune(key, keep :: pos_integer) :: non_neg_integer                     # rows deleted
```

- [ ] **Step 1:** Write the failing tests:
  - append then latest;
  - history order and limit;
  - prune keeps the newest N;
  - a duplicate `(key, seq)` raises;
  - two keys stay independent.
- [ ] **Step 2:** Write the migration and `Store`. Use `Ecto.Query` against a schemaless `"elm_states"` source, or a minimal schema. Run `mix ecto.migrate`; the test alias already runs migrations.
- [ ] **Step 3:** Check the tests pass, run `mix precommit`, then `jj commit -m "feat: elm_states store"`.

### Task 2: `Runtime` `on_step` hook

**Files:**
- Modify: `lib/kinoko/elm/runtime.ex`
- Test: `test/kinoko/elm/runtime_on_step_test.exs`

**Interfaces:** `Runtime.init(module, init_msg, init_fun, opts)` now accepts `on_step: (state, seq -> any)`. It is called in `init` and in every `step`, after the module returns and before `perform`. `seq` is the timeline `seq` of that msg. The hook is stored on the struct.

- [ ] **Step 1:** Write the failing tests:
  - The hook sees every state, in order.
  - Hook-before-effect: the hook sends `{:hooked, seq}` to the test process, and an effect `send_to(test_pid, :effect)` from the same step must arrive after `{:hooked, seq}`.
  - A raising hook prevents the effect.
- [ ] **Step 2:** Implement: in `init/4` and `step/3`, call the hook between `record_msg` and `perform`.
- [ ] **Step 3:** Check the tests pass and all the existing elm and LiveView tests stay green, run `mix precommit`, then `jj commit -m "feat(elm): on_step hook before effects"`.

### Task 3: `Kinoko.PersistentElmGenServer`

**Files:**
- Create: `lib/kinoko/persistent_elm_genserver.ex`
- Modify: `lib/kinoko/application.ex`, to add `{Registry, keys: :unique, name: Kinoko.Elm.Registry}`
- Create: `test/support/persistent_counter.ex`
- Test: `test/kinoko/persistent_elm_genserver_test.exs`

**Interfaces:**

```elixir
use Kinoko.PersistentElmGenServer       # @behaviour + defaults for version/0, migrate/2, resume/1, encode/1, decode/1 (overridable)
Kinoko.PersistentElmGenServer.start_link(module, args, key: key, keep: 100) :: GenServer.on_start()
Kinoko.PersistentElmGenServer.call(key_or_pid, request, timeout \\ 5000)
Kinoko.PersistentElmGenServer.cast(key_or_pid, msg)
Kinoko.PersistentElmGenServer.whereis(key) :: pid | nil
child_spec(arg) via `use` (id: {module, key})
```

- [ ] **Step 1:** Write the failing tests, async: false, with the sandbox in shared mode. Use `PersistentCounter` with `count`, a `:inc` call, and a `resume` that records it was resumed.
  - restart survives;
  - a crash under a test supervisor resumes;
  - an unchanged state writes no row (check `Store.history`);
  - `keep: 3` prunes;
  - a version bump calls `migrate/2` with the stored version, and the default `migrate` raises;
  - `resume` runs on reboot and `init` does not;
  - a duplicate key gives `{:error, {:already_started, _}}`;
  - a binary naming a non-existent atom fails boot clearly when decoded with `:safe`;
  - Review Focus 3: a `Store` failure crashes and no effect is performed. Simulate it with a module whose `encode/1` raises on a marked state, and assert the effect never arrives.
- [ ] **Step 2:** Implement.
  - **`init/1` (GenServer):** register via the `Registry` `:via` name. Load `Store.latest`.
    - If it exists: decode it, migrate if needed, then `Runtime.init(module, {:resume, seq}, fn -> module.resume(state) end, on_step: hook)`, with seq continuing from the stored one.
    - Otherwise use `module.init(args)`.
  - **The hook:** compare against the last written state (keep it in the hook's closure or the host state). Append when the state changed. Prune every `keep` appends.
  - The rest delegates exactly like `Kinoko.ElmGenServer`. Factor the shared host code instead of copy-pasting, through a small shared module if needed.
- [ ] **Step 3:** Check the tests pass, run `mix precommit`, then `jj commit -m "feat: PersistentElmGenServer"`.

### Task 4: Docs and a worked example

**Files:** modify the moduledocs; create `test/kinoko/persistent_elm_genserver_doc_test.exs` or extend Task 3's tests.

- [ ] **Step 1:** The moduledoc covers:
  - a persistent counter example (start under a key, inc, restart, still there);
  - durability semantics: written before effects, in-flight effects lost, stale pids in state;
  - the `version`/`migrate` contract;
  - storage cost and pruning;
  - the `encode`/`decode` override, mentioning piece 3's universe use: store `history` and `texts`, and rebuild with `Kinoko.Lang.restore/2`.
- [ ] **Step 2:** Doctest or test the example, run `mix precommit`, then `jj commit -m "docs: PersistentElmGenServer"`.
