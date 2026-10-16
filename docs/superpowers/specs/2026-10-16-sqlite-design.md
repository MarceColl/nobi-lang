# SQLite everywhere — design

## Goal

Kinoko runs locally with no external database. `mix kinoko.start` works from a fresh checkout. All of Kinoko's own tables (stored states, the CAS, universes, deployments) live in one SQLite file. Postgres is dropped now. The SQL stays portable, so a hosted node (piece 7) could bring Postgres back if SQLite turns out not to be enough.

## Decisions (Marce)

- Whole system on SQLite, SQLite only, now. Postgres support is removed, not kept beside it.
- App data (the next piece, "store") lives in one SQLite file per deployment.

## Changes

- **Dependencies:**
  - `postgrex` is replaced by `ecto_sqlite3`.
  - `Kinoko.Repo` uses `Ecto.Adapters.SQLite3`.
  - `docker-compose.yml` is removed.
- **Paths:** the data directory is `.kinoko/`, and it is git-ignored.
  - dev: `.kinoko/kinoko.db`
  - test: `.kinoko/test<partition>.db`
  - prod: `KINOKO_DATA` env var (default `/var/lib/kinoko`) plus `/kinoko.db`, set in `runtime.exs`, replacing `DATABASE_URL`.
  - Pragmas: WAL mode, `busy_timeout` 5000 ms and foreign keys on.
- **Migrations:** rewritten portably. Nothing is deployed, so the existing migration files are edited in place, which keeps the history short.
  - `timestamptz` becomes `:utc_datetime_usec`, and `bytea` becomes `:binary`.
  - `deployments.hosts text[]` becomes a table, `deployment_hosts(deployment, host)` with primary key `(deployment, host)` and an index on `host`. Host lookup becomes an indexed join.
  - No database-side defaults that SQLite can't express. Timestamps are set in Elixir where needed.
- **Queries.** `Kinoko.Cas`, `Kinoko.Universe.Registry`, `Kinoko.Elm.Store` and `Kinoko.Deployment` are audited for Postgres-only features: arrays, `ANY`, `FOR UPDATE` and `ILIKE`. Each one gets a portable form. `on_conflict: :nothing` with `conflict_target` is supported by SQLite. Batch sizes respect SQLite's variable limit, 32766 by default.
- **Tests.** The Ecto SQL sandbox works with `ecto_sqlite3`. SQLite allows one writer, so tests that write in parallel (concurrent creates, concurrent stages) still have to hold, through `busy_timeout` and serialization. `max_cases` or `async: false` is set where a writer contends.
  - The tests stay as strong as they are: every concurrency test still asserts its outcome, for example exactly one `:ok`.
- **Dev data.** Existing Postgres dev data is not migrated. The new file starts empty, `main` and `local` are created at boot, and the forum and playground fixtures can be restaged by hand.

## Testing

- The full suite passes on SQLite, including the opt-in `quint` and `perf` tags.
- **A fresh-checkout smoke:**
  1. `rm -rf .kinoko`, then `mix kinoko.start` on a spare port.
  2. `/_` returns 200, and the MCP `initialize` works.
  3. Staging the forum through MCP serves it at `<name>.localhost`.

## Done when

The suite is green, Postgres is gone from deps and config, the smoke above passes, and AGENTS.md and the docs no longer mention Postgres.
