# ISS-0150 / GH-482 — `test-integration-svc` Close-out Design

## 1. Purpose and scope

This Type E design closes out GH-482 / ISS-0150 as an acceptance-measurement task. The reported per-tenant `schema_migrations` premise is intentionally disproven: `public.schema_migrations(schema_name, version)` is canonical, and stray tenant-local ledgers are deliberately removed. RC-1, RC-2, and RC-3 were fixed in PR #519, while ISS-0182 through ISS-0185 were drained separately. This step therefore changes no source code, migrations, tests, or build graph unless a fresh measurement establishes a genuinely new root cause.

The authoritative result is the **process exit code** of a complete `zig build test-integration-svc` run. Pass-count text, interleaved stderr, and individual block summaries are evidence for triage only and cannot override the exit code.

## 2. Classification

**Type E — novel / cross-cutting acceptance and test-infrastructure close-out.**

The work does not add a table, migration, CRUD route, list page, or React Flow node. It coordinates fresh database provisioning, migration verification, a multi-binary integration target, branch/origin comparison, release decision, issue-state transition, and conditional forwarding. It cannot be represented safely by a Type A–D parameter file.

## 3. Re-measurement procedure

### Preconditions

1. Confirm the current branch is `feature/WF03-GH482-20260808` and record the commit under test.
2. Ensure the branch contains the post-PR-#519 and sibling fixes, but do not alter source to improve the measurement.
3. Use a **fresh, workspace-owned `db_test` database/container**, not a long-lived shared database. The database must be created independently for this run and must not be concurrently used by another workspace.
4. Resolve and print the exact database endpoint used by the run. Set `BPM_TEST_DB_URL` to that fresh database. Set `BPM_DB_URL` separately to the development database if migration tooling requires it; do not let a migration command silently certify a different database from the one tested.
5. Reserve the required ports for the test environment. The test target must not share PostgreSQL, API, or Keycloak ports with another active workspace.

### Fresh migration and health evidence

Run the project migration path against the fresh test database, using the repository's documented environment and migration command. Capture its exit code and complete output in a scratch log. Verify:

- all migration files are accounted for in `public.schema_migrations`;
- the fresh database has the intended canonical public ledger and no tenant-local ledger requirement;
- the test-environment pre-check exits 0;
- no unrelated process owns the test database or required ports.

Do not use ad-hoc destructive SQL or modify migration ledgers manually. If provisioning fails, classify it as an environment/precondition failure rather than silently continuing.

### Suite execution

Run the complete target from the branch:

```text
BPM_TEST_DB_URL=<fresh-workspace-db> zig build test-integration-svc
```

Capture:

- exact command and resolved database identity;
- start/end UTC timestamps;
- process exit code;
- complete output and test artifact identity;
- failing block names, crash blocks, skips, and any PostgreSQL error text;
- whether each reported error has a stack/source frame in its own test file or is interleaved sibling output.

A single successful run is sufficient to satisfy the close-out measurement only if the environment pre-check and fresh migration verification also pass. If the run exits 1, reproduce only the remaining failure clusters as needed under the same fresh database or a second independently fresh database before assigning causes.

### Origin control

For every residual block, compare the exact test name and failure signature against a clean `origin/main` control run using an independently fresh database. Record the branch result and control result separately. Do not infer “new” from a changed total; use the set of failing test names and the root-cause signature.

## 4. Close-out path when exit code is 0

If migration/health checks pass and the full `test-integration-svc` process exits 0:

1. Create a release decision artefact under `docs/status/` stating that GH-482 acceptance criterion 2 is verified on the fresh database, the original ledger premise remains disproven, and no source change was needed in this close-out step.
2. Update `docs/issues/ISS-0150.json` from `PARTIALLY_RESOLVED` to `RESOLVED`, preserving the historical diagnosis, PR #519 evidence, sibling references, and fresh-run evidence. Update the acceptance-criteria status and close-out metadata; do not erase prior measurements.
3. Prepare the GitHub close-out action for GH-482: comment with the fresh-run evidence, PR #519, and ISS-0182/0183/0184/0185 outcomes, then close the issue according to the active workflow's issue/board protocol.
4. Update the changelog/release record through the designated DOC-UPDATER step. This design step does not independently mark the requirement status file.
5. Make no source-code, migration, or test changes. The close-out is validated evidence and bookkeeping only.

## 5. Forwarding path when exit code is non-zero

A non-zero result keeps ISS-0150 open and must not be relabeled as a successful close-out.

For each remaining block:

1. Identify the concrete failing test artifact and source frame. Discard unrelated interleaved stderr as causal evidence unless the failing artifact itself owns the frame.
2. Classify the failure as one of:
   - **Pre-existing on `origin/main`:** same test name and root-cause signature fails in the clean origin control. Do not attribute it to this branch. Map it to an existing sibling issue if one exactly covers it; otherwise register, file, and queue a new issue through the normal WF-03 issue protocol.
   - **Branch-new regression:** passes on clean `origin/main` but fails on this branch, with a root cause introduced by the branch's actual diff. This requires a new diagnosis and a source change only after the new root cause is confirmed.
   - **Environment-only:** caused by stale/shared database state, migration drift, parallel workspace interference, missing service, or port conflict. Recreate the environment correctly first; do not file it as a product defect unless it persists on isolated fresh conditions.
   - **Existing sibling residual:** matches the stated acceptance scope of ISS-0182/0183/0184/0185 but remains unresolved in live evidence. Verify the sibling's current status and forward/update the correct issue rather than creating a duplicate.
3. Produce an evidence table with test name, branch result, origin result, database identity, failure signature, classification, existing issue or new issue ID, and next action.
4. Forward only confirmed residual defects. Every new issue must receive the required local registry entry, GitHub issue, and global queue entry; a mention in this design alone is insufficient.
5. Keep the GH-482 close-out blocked until the acceptance criterion is met or the remaining blocks are explicitly transferred with durable issue references.

No source-code change is permitted merely to make the target exit 0. If the measurement reveals a new root cause, stop the close-out implementation path and route a new diagnosis/design or rework handoff to the appropriate specialist.

## 6. Data flow

```text
feature branch + clean origin control
              |
              v
workspace-owned fresh db_test --(migration runner)--> public.schema_migrations
              |                                          |
              +-------------------- health evidence -----+
              |
              v
zig build test-integration-svc
              |
       exit code + artifact output
          /                 \
        0                    non-zero
        |                       |
        v                       v
release decision         isolate failure blocks
ISS-0150 RESOLVED        compare exact names/signatures
GH-482 close-out         against fresh origin/main control
no source change         pre-existing / branch-new / environment
                                |
                                v
                         existing sibling or new issue
                         + GitHub + global queue
```

## 7. Failure and error taxonomy

- `FreshDatabaseUnavailable`: the workspace-owned test database cannot be created, reached, or uniquely identified.
- `MigrationVerificationFailed`: migration command, ledger count, or schema invariant fails before tests.
- `EnvironmentPrecheckFailed`: required service, credentials, database, or health check is unavailable.
- `PortConflict`: PostgreSQL, API, or Keycloak port is occupied by another workspace/process.
- `ParallelWorkspaceInterference`: another run mutates or cleans the same database/schema during measurement.
- `IntegrationSuiteFailed`: `zig build test-integration-svc` exits non-zero on isolated fresh conditions.
- `InterleavedOutputMisattribution`: stderr from a sibling artifact appears inside another test block; not causal without a matching frame.
- `PreExistingResidual`: failure reproduces on fresh `origin/main` control.
- `BranchRegression`: failure is absent on origin control and caused by the branch diff.
- `UnclassifiedResidual`: failure cannot yet be assigned; keep ISS-0150 open and route for diagnosis rather than closing.
- `CloseOutEvidenceIncomplete`: exit 0 exists but fresh-migration or environment evidence is missing; no release decision may pass.

## 8. Dependencies and non-dependencies

### Dependencies

- `build.zig` target `test-integration-svc` and its cleanup predecessor.
- `src/db/migrations.zig` canonical public migration ledger behavior.
- `tools/clean_test_db.py` and the repository health-check procedure.
- PostgreSQL and required backend services, isolated per workspace.
- `docs/issues/ISS-0150.json`, diagnosis report, sibling issue records, GitHub issue #482, and the handoff audit protocol.
- TEST-RUNNER for authoritative execution evidence; RELEASE-VALIDATOR for release decision; DOC-UPDATER/ORCH for issue and board bookkeeping.

### Must not depend on

- Long-lived shared `db_test` state.
- Another workspace's container, database, service, or port.
- Pass-count strings or arbitrary stderr text as the pass/fail signal.
- Per-tenant `schema_migrations` tables.
- Manual SQL edits to repair or precondition the measurement.
- A source change whose only purpose is to satisfy this gate.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Environment sensitivity creates hangs or false failures | Use a fresh workspace-owned database, verify migration and health checks first, capture complete logs, and classify environment-only failures separately. |
| Parallel workspaces clean or migrate the same schemas | Use unique compose/database identity and confirm ownership before running; never share `db_test`. |
| PostgreSQL/API/Keycloak port conflicts | Reserve workspace-specific ports and fail the pre-check if the resolved endpoint differs from the intended workspace. |
| Shared database migration drift | Compare ledger state to migration files and refuse to certify a stale database. |
| Interleaved multi-binary stderr | Trace the failing artifact and source frame; use process exit code as the gate. |
| Flaky connection-pressure behavior such as TC-DB-02-04 | Record repeated isolated observations and document/bound it separately; do not silently count a passing repeat as closure evidence. |
| Misclassification of a new residual as pre-existing | Run the clean `origin/main` control on an independently fresh database and compare exact failure sets/signatures. |
| Premature issue closure | Require both exit 0 and complete fresh-environment evidence before the release decision. |

## 10. Open questions

None block this close-out design. The remaining business choice is procedural, not ambiguous: exit 0 permits close-out; non-zero requires evidence-based forwarding or a newly routed diagnosis.
