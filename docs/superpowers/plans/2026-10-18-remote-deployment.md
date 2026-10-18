# Remote Deployment Implementation Plan

## Overview

Add a release path that moves a selected Nobi code image from a local instance to a remote server, verifies it there, and activates it by moving a deployment pin. The release is an immutable bundle derived from the code database, rather than a copy of the Nobi executable.

- **Motivation**: Nobi already stores canonical declarations by content ID and records append-only commits; deployment records can pin a deployment to a commit. The missing link is safely transferring a chosen image to another running Nobi.
- **Related**: [`../specs/2026-10-17-distribution-design.md`](../specs/2026-10-17-distribution-design.md), [`2026-10-15-routes-deployments.md`](2026-10-15-routes-deployments.md), [Nobi release and follow-up roadmap](../roadmaps/2026-10-18-release-roadmap.md)

## Current State Analysis

- `Nobi.Universe.stage/4` canonicalizes source, writes declarations to the CAS, then asks the CodeDb to typecheck and promote the whole image (`lib/nobi/universe.ex:92-157`). The CAS is append-only and keyed by CID (`lib/nobi/cas.ex:1-43`).
- Commits store declaration names and CIDs, not source text; CodeDb restores history by fetching the declarations from the CAS (`lib/nobi/code_db.ex:49-71`, `lib/nobi/code_db.ex:223-315`). `Nobi.Universe.history/1`, `symbols/1`, `read/2`, `at/2`, and `image/1` provide pieces needed to create and verify a release snapshot (`lib/nobi/universe.ex:186-204`, `lib/nobi/universe.ex:383-411`, `lib/nobi/universe.ex:547-581`).
- `Nobi.Deployment` can follow a universe head or pin to a 1-based commit; pin and follow update the deployment row (`lib/nobi/deployment.ex:190-212`, `lib/nobi/deployment.ex:243-263`). Existing runtime data is stored per deployment (`lib/nobi/data.ex`).
- MCP and app serving are compiled only when `:mcp_enabled` is true, while production server mode disables that local control plane (`lib/nobi_web/router.ex:20-35`, `lib/nobi_web/router.ex:85-110`). A remote apply endpoint therefore needs its own intentionally narrow production route and authentication.
- Nobi release distribution packages the Nobi executable, not a selected universe image (`docs/superpowers/plans/2026-10-17-distribution.md`).

## Desired End State

A developer can select a healthy universe commit, create a deterministic release bundle, and apply it to a remote Nobi server. The receiver authenticates the request, validates bundle format and payload limits, verifies declaration CIDs and the expected image hash, typechecks the complete image, imports it as one commit, and pins the requested deployment to that commit only after import succeeds. Failed imports leave the active deployment untouched. Applying the same release again is idempotent. The prior deployment commit remains available for rollback.

A release manifest identifies the bundle format version, source universe and commit, image hash, Nobi runtime compatibility version, and the canonical declaration payloads addressed by CID. The bundle does not include deployment data or secrets.

## What We're NOT Doing

- Shipping a new Nobi executable as part of each app release.
- Replicating deployment SQLite data, secrets, or arbitrary files.
- Multi-node coordination, traffic splitting, automated health-based rollback, or a hosted release registry.
- General-purpose remote MCP access or an unauthenticated control endpoint.
- Automatic model/data migrations. A release that changes persisted model shape must have a separately designed migration policy before production rollout.

## Implementation Approach

- Export a complete immutable snapshot for the selected commit, including the declaration texts referenced by that snapshot and a stable image hash.
- Import and verify the snapshot through `Nobi.Universe` public interfaces; keep raw `Nobi.CodeDb` storage private.
- Add one authenticated release apply endpoint and one local CLI path (`nobi release export` and `nobi release apply --to URL`). The endpoint accepts only a release bundle and a deployment name.
- Import as one atomic promotion, then pin the deployment. Preserve the previous pin so rollback is a deployment operation, not a code rewrite.
- Make idempotency explicit through the release image hash; reject incompatible runtime versions and invalid or incomplete bundles before activation.

## Quick Verification Reference

- `mix test test/nobi/release_test.exs test/nobi_web/release_controller_test.exs test/mix/nobi_release_test.exs`
- `mix precommit`
- CLI end-to-end smoke against two isolated Nobi instances with temporary data directories and distinct ports.

---

## Phase 1: Release snapshot contract

### Overview

Define and implement the deterministic bundle format and export/import operations. A validated import creates one complete commit through the public universe interface and proves the resulting image hash matches the manifest.

### Changes Required:

#### 1. Snapshot format and builder
**File**: `lib/nobi/release.ex` (or a focused `lib/nobi/release/bundle.ex` if the format logic warrants separation)
**Changes**: Define a versioned manifest; export the selected commit's complete declaration set; include canonical source and CIDs; compute a stable image hash; reject degraded universes, missing declarations, malformed bundle versions, duplicate symbols, CIDs that do not hash to their payload, and incompatible runtimes.

#### 2. Universe import seam
**File**: `lib/nobi/universe.ex`
**Changes**: Add a public operation for importing a verified snapshot as one patch/promotion, with full replacement semantics for the destination universe. Ensure the destination becomes exactly the exported image, including removals, and return its local commit number and image hash. A failed typecheck or persistence error must not activate partial code.

#### 3. Focused tests
**File**: `test/nobi/release_test.exs`
**Changes**: Cover deterministic export, CID validation, image hash validation, empty and non-empty images, removals, invalid manifests, degraded source, typecheck refusal, idempotent import, and source/target semantic equality.

### Success Criteria:

#### Automated Verification:
- [ ] Focused tests pass: `mix test test/nobi/release_test.exs`
- [ ] Full project gate passes: `mix precommit`
- [ ] Bundle export/import round-trip yields the manifest image hash and the same committed symbols and callable behavior.

#### Automated QA:
- [ ] Export an earlier commit, advance the source universe, import into a separate target database, and confirm the target runs the earlier code image.

#### Manual Verification:
- [ ] Review the bundle manifest and confirm it contains no deployment rows, app data, or secrets.

**Implementation Note**: Keep the bundle contract small and explicit; do not serialize internal BEAM terms or CodeDb state.

---

## Phase 2: Authenticated remote apply and atomic activation

### Overview

Add a narrow production endpoint that accepts verified release bundles and activates a named deployment. Authentication and bundle validation happen before durable mutation; activation occurs only after the import has committed successfully.

### Changes Required:

#### 1. Release API and authentication
**File**: `lib/nobi_web/router.ex`, `lib/nobi_web/controllers/release_controller.ex`, `config/runtime.exs`
**Changes**: Mount a dedicated POST route in server mode; require a configured bearer token, compare credentials safely, require HTTPS at the deployment boundary, enforce content type and request size, and return structured JSON errors without echoing secrets or payloads.

#### 2. Target resolution and activation
**File**: `lib/nobi/release.ex`, `lib/nobi/deployment.ex`
**Changes**: Resolve or create the configured release target, import the snapshot, verify the returned hash, then pin its deployment. Capture the prior pin in the result for rollback. Use an idempotency key derived from the image hash so retries after an uncertain network result do not create repeated history.

#### 3. Endpoint tests
**File**: `test/nobi_web/release_controller_test.exs`
**Changes**: Cover missing/wrong auth, malformed and oversized payloads, runtime mismatch, CID/hash failure, typecheck failure, retry, successful pin update, and preservation of the previous active pin on failure.

### Success Criteria:

#### Automated Verification:
- [ ] Endpoint tests pass: `mix test test/nobi_web/release_controller_test.exs`
- [ ] `mix precommit` passes.
- [ ] The production router exposes only the release apply route; MCP and console remain unavailable in server mode.

#### Automated QA:
- [ ] Apply a release from an isolated source instance to a server-mode target; confirm the selected app serves the new version and the target deployment retains its existing data file.
- [ ] Submit an invalid release and confirm the active deployment continues serving its prior commit.
- [ ] Reapply the same bundle and confirm the operation returns the existing activation result.

#### Manual Verification:
- [ ] Confirm deployment operator setup can inject the release token without printing it to logs or CLI output.

**Implementation Note**: Return the activation commit and image hash so callers can reconcile retries. Do not claim the application is healthy merely because the import typechecks.

---

## Phase 3: Local release CLI and operator workflow

### Overview

Add a small CLI workflow for creating and applying release bundles and document configuration, rollback, and failure recovery. Keep the CLI a thin client of the bundle and HTTP interfaces.

### Changes Required:

#### 1. CLI commands
**File**: `lib/nobi/cli.ex`, `lib/nobi/release.ex`, `test/mix/nobi_release_test.exs`
**Changes**: Add `nobi release export --universe NAME --commit N --output FILE` and `nobi release apply --to URL --deployment NAME FILE`; support token lookup only from environment or a permission-restricted config file; never accept a token as a command-line argument.

#### 2. Operator documentation
**New file**: `docs/remote-deployments.md`
**Changes**: Document bundle identity, server token configuration, HTTPS requirements, dry-run/validation behavior, activation result, rollback to prior pin, and data migration boundaries.

### Success Criteria:

#### Automated Verification:
- [ ] CLI tests pass: `mix test test/mix/nobi_release_test.exs`
- [ ] `mix precommit` passes.

#### Automated QA:
- [ ] Using two isolated local instances, export an older source commit and apply it to the target; verify the target app serves the selected version and rollback restores the prior one.
- [ ] Verify the CLI rejects missing credentials and never includes the credential in error output.

#### Manual Verification:
- [ ] Confirm the operator documentation's config names and rollback steps against a server-mode release.

**Implementation Note**: Do not add remote management commands beyond release export/apply in this slice.

---

## Appendix

- **Follow-up plans**: [`2026-10-18-release-roadmap.md`](../roadmaps/2026-10-18-release-roadmap.md)
- **Derail notes**: Persistent model evolution across deployment versions needs an explicit data migration design; code rollback alone cannot reverse writes made under the newer model.
- **References**:
  - `lib/nobi/universe.ex`
  - `lib/nobi/cas.ex`
  - `lib/nobi/code_db.ex`
  - `lib/nobi/deployment.ex`
  - `lib/nobi_web/router.ex`
