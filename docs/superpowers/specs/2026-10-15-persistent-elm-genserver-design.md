# PersistentElmGenServer — design (piece 2)

Piece 2 of 7. It builds on the Elm foundation (`Kinoko.ElmGenServer`, `Kinoko.Elm.Runtime`). Piece 3, the code DB server, becomes a `PersistentElmGenServer` that holds a universe.

## Goal

An `ElmGenServer` whose state survives restarts and crashes. Every state change is written to Postgres, append-only, **before** the effects of that step run. A server started again under the same key resumes from its last written state.

## Out of scope

- Durable effects (an intent log with redelivery). An effect in flight when the node dies is lost. Callers retry. This is the known gap, documented.
- Persisting the timeline.
- Persisting LiveView state.
- Distribution and multi-node ownership: one live process per key is assumed, enforced locally by a `Registry` name.

## Shape

```
msg ─▶ Runtime.step ─▶ update/2 (pure) ─▶ {state', effects}
                         │
                         ├─ on_step hook: Store.append(key, seq, encode(state')) ◀── before perform
                         └─ perform(effects)
```

- **`Kinoko.Elm.Runtime`** gains one option, `on_step: (state, seq -> :ok)`. It is called after `update`/`init` returns and before any effect is performed. A raise in it crashes the host, so nothing performs. This is the only change to the foundation, and every existing test stays green.
- **`Kinoko.Elm.Store`** handles storage, through `Kinoko.Repo`:
  - **Table** `elm_states(key text, seq bigint, version int, state bytea, inserted_at timestamptz)`, primary key `(key, seq)`. It is append-only: one row per changed state.
  - `append(key, seq, version, binary)` adds a row.
  - `latest(key) :: {:ok, %{seq, version, state}} | :none` reads the newest row.
  - `history(key, limit)` lists past rows.
  - `prune(key, keep)` deletes all but the newest `keep` rows, so storage stays bounded.
- **`Kinoko.PersistentElmGenServer`** is a module plus a `use` macro. It has the same `init/1` and `update/2` callbacks as `ElmGenServer`, and these optional ones:
  - `version/0`, default `1`, stored with every row;
  - `migrate(state, from_version) :: state`, called on boot when the stored version differs; the default raises, telling the author to implement it;
  - `resume(state) :: {state, effects}`, called instead of `init/1` when a stored state exists; the default is `{state, []}`, and it is where timers get restarted;
  - `encode(state) :: binary` and `decode(binary) :: state`. The defaults are `:erlang.term_to_binary` and `:erlang.binary_to_term(b, [:safe])`. Piece 3 overrides them to store a universe's history and texts and rebuild it with `Kinoko.Lang.restore/2`.

## Behaviour

- **Start:** `start_link(module, args, key: key, keep: n \\ 100)`. The process registers under `{:via, Registry, {Kinoko.Elm.Registry, key}}`, so one live process per key per node.
- **Boot:**
  - If `Store.latest(key)` finds a row: decode it, migrate it if the version differs, then call `resume/1`.
  - Otherwise call `init/1`.
  - The `seq` carries on from the stored one. The first state after `init` or `resume` is written only if it differs from what is stored.
- **Each step:** if the new state differs from the previous one (`!==`), append `seq+1`. Every `keep` appends, prune. An unchanged state writes nothing.
- **Writes happen before effects.** The `on_step` hook runs before perform. A reply or effect is never released for a state that was not written.
- **Crashes:** a supervisor restart under the same key resumes the last written state. Messages in flight are lost, as with any GenServer.
- **`call`/`cast`** are the same API as `ElmGenServer`, and calls accept a key in place of a pid.

## Testing

- `Store` unit tests: append, latest, history, prune, and the composite primary key refusing a duplicate seq.
- The `Runtime` `on_step` hook is called once per step, before effects. Test it with an effect that observes whether the hook already ran.
- Restart: start a counter under key k, increment it, stop it, and start it again under k; the count survives.
- Crash: kill the process under a test supervisor; the restarted one resumes.
- An unchanged state writes no row.
- `keep` prunes.
- A version bump calls `migrate` with the stored version.
- `resume` runs on reboot, and `init` does not.
- With safe decoding, a stored binary that names an unknown atom refuses to boot with a clear error.

The tests use `Kinoko.DataCase`, with the sandbox in shared mode so the server process can reach the connection.

## Done when

The tests above pass, `mix precommit` is green, and the moduledoc has a persistent counter example.
