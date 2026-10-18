# Nobi Release Roadmap

This roadmap records the product work after remote code deployment. It is sequenced around making Nobi code portable first, then making its behavior testable and observable, then adding durable asynchronous work. These are candidate release slices with acceptance gates, not promises about dates.

## Release sequence

| Order | Release slice | User outcome | Depends on |
|---|---|---|---|
| 1 | Remote deployment bundles | Move an immutable code image from a local code database to a running server, activate it, and roll back by pinning the previous image. | Current universe history, CAS, deployments |
| 2 | Simulation against committed Nobi apps | Explore generated inputs and simulated effects against a selected code image; report property failures with reproducible traces and honest truncation status. | Release snapshot/import contract; existing `Nobi.Elm.Sim` |
| 3 | Runtime failure introspection | Query a durable run record and focused trace after a deployed app fails, including effect results and the code image that ran. | Stable deployment release identity; simulation trace format informs trace records |
| 4 | Durable workflows and queues | Express and inspect background work with explicit delivery, retry, idempotency, and version semantics. | Run identity, failure records, durable storage contract |
| 5 | Evidence-led language evolution | Add only syntax and type rules that simplify the proven deployment, simulation, or workflow contracts. | Findings from releases 1–4 |

## Release 1: Remote deployment bundles

**Goal:** Ship a selected Nobi code image between instances without shipping a new Nobi executable.

**Design:** Export an immutable bundle from one healthy universe commit. Include a versioned manifest, image hash, runtime compatibility, CIDs, and canonical declaration source. The receiver verifies the bundle, imports the full image as one atomic promotion, then pins a deployment. Preserve the old pin for rollback. Never include deployment data or secrets.

**Acceptance gate:** A two-instance smoke test exports a prior commit, imports it on a server-mode target, serves the expected app version, keeps target deployment data, and rolls back to the prior image. Invalid payloads leave the active pin unchanged. Reapplying the same image is idempotent.

**Open design boundary:** Cross-version persisted model changes need a migration policy before model-changing releases are considered safe for unattended activation.

## Release 2: Simulation against committed Nobi apps

**Current base:** `Nobi.Elm.Sim` already performs breadth-first interleaving exploration and seeded random walks with invariant checks after steps (`lib/nobi/elm/sim.ex`). Nobi source already supports `always` and `sometimes`, and committed code exposes `Nobi.Universe.test/3` (`lib/nobi/lang.ex`, `lib/nobi/exec.ex`). The gap is that the simulator currently accepts Elixir modules and closures, not a selected Nobi universe image.

**Goal:** Run a Nobi `defapp` or test scenario against a pinned universe image with generated, typed messages and simulated effects.

**Release steps:**

1. Define a scenario representation that names the universe commit, app, initial args, input domains/generators, effect outcome policy, properties, and exploration limits.
2. Bridge scenario steps through `Nobi.Universe.at/2`, `apply/4`, and app runtime semantics without executing real network or process effects.
3. Connect `always` to safety checks after every transition. Define `sometimes` as bounded reachability goals with a distinct `reached`, `not reached within bound`, or `inconclusive` result. Do not report bounded absence as proof of impossibility.
4. Return the seed, image hash, input sequence, effect outcomes, and minimized or directly replayable counterexample trace.
5. Expose the operation to agents only after the local result format is stable.

**Acceptance gate:** A seeded run replays exactly on the same image; a deliberately violated `always` returns a counterexample; a reachable `sometimes` reports success; truncated exploration reports inconclusive; no external effect executes.

**Non-goals:** General theorem proving, unbounded model checking, and unrestricted generation of values outside declared types.

## Release 3: Runtime failure introspection

**Current base:** Step and effect timelines exist in memory for running Elm processes (`lib/nobi/elm/timeline.ex`). Deployed LiveViews intentionally keep no server-side timeline per connection, and current failure reporting is primarily visible during a live run (`test/nobi_web/deployment_live_test.exs`). `Nobi.Deployment.Runner` already returns structured step/effect records for an MCP send, but those records are not a durable run history (`lib/nobi/deployment/runner.ex`).

**Goal:** Give an agent a run ID and durable, bounded records it can query after a deployed action fails.

**Release steps:**

1. Define one run record: run ID, deployment, release image hash/commit, start/end time, status, triggering message or request, and retention policy.
2. Persist ordered step and effect events with bounded payload capture. Store errors as code/message plus relevant source location when available; redact credentials and avoid recording arbitrary secrets.
3. Add focused APIs to fetch a run summary, fetch events around a failure, and list recent failures for a deployment. Avoid returning full app state by default.
4. Add a console view and MCP query only after the stable run query contract exists.

**Acceptance gate:** Force an async effect failure, restart the Nobi process, query the run by ID, and recover its release identity, failed effect, and surrounding trace. Retention removes old records without affecting active application data.

**Non-goals:** Full process-wide distributed tracing or an unbounded event archive.

## Release 4: Durable workflows and queues

**Current base:** `Nobi.Elm.Effect.task/2` runs work asynchronously, but `Nobi.PersistentElmGenServer` documents that in-flight effects can be lost when a process dies (`lib/nobi/persistent_elm_genserver.ex`). There is not yet a durable job queue contract.

**Goal:** Let Nobi programs schedule background work that survives restarts and is visible to operators.

**Release steps:**

1. Write the delivery contract before adding syntax: durable enqueue, retry limits/backoff, dedupe key, idempotency expectations, cancellation, dead-letter behavior, and whether delivery is at-least-once.
2. Persist job intent before acknowledging the application step. Workers lease jobs, record attempt state, and recover expired leases after restart.
3. Pin each job to the release image that created it, unless the language explicitly supports safe migration to a newer image.
4. Expose job state and attempt failures through the durable run query model from Release 3.
5. Add the smallest Nobi-level declaration or effect needed to enqueue typed work; keep worker execution in the existing Elm effect/runtime boundary.

**Acceptance gate:** A queued job survives process restart, retries a transient failure according to policy, never creates a duplicate side effect when retried with a supported idempotency key, and reports terminal failure with a queryable trace.

**Non-goals:** Distributed scheduling across a cluster or exactly-once claims for arbitrary external side effects.

## Release 5: Evidence-led language evolution

**Goal:** Keep language growth small and tied to a demonstrated gap in the release work above.

**Candidates to validate, not pre-approve:**

- A typed scenario/generator declaration if simulation cannot be expressed cleanly with current `deftest` and app message types.
- A typed durable job contract if a plain `Cmd` effect cannot express durable enqueue and result handling safely.
- A migration declaration only if deployment model evolution requires a program-defined, checked data transition.
- More explicit temporal properties only after bounded `sometimes` semantics and counterexample reporting are proven useful.

**Acceptance gate for any syntax addition:** The proposal names the concrete use case, shows that existing syntax is awkward or unsafe, specifies parser/formatter/checker/codegen/runtime behavior together, and includes golden and type-error coverage. Avoid introducing broad workflow or temporal logic syntax based on vocabulary alone.

## Cross-release rules

- Every run, trace, and release identifies the immutable code image that produced it.
- Results distinguish failure, success, and bounded/incomplete exploration.
- No test or simulation path performs real side effects unless the caller explicitly invokes a live deployment operation.
- Durable work has explicit retry and idempotency behavior before a public syntax is added.
- Preserve append-only code history; activation changes a deployment's selected image, not its past code.
