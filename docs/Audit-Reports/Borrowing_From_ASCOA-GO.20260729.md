# What R-Co Can Borrow From ASCOA-GO — 2026-07-29

**Current project:** R-Co BPM Platform (Zig backend, React SPA) — `C:\Users\tvolo\dev\ai-dala\R-Co`
**Reference project:** ASCOA-GO (Go modular monolith, React SPA, Flutter) — `C:\Users\tvolo\dev\ASCOA\ascoa-go`
**Method:** Static comparison of both source trees and doc sets. No execution.
**Supersedes / extends:** `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260626.md` (2026-06-26) and `BPM_vs_ASCOA-GO_Gap_Analysis.20260611.md`.

---

## 0. How to read this

You already ran this exercise twice (June 11, June 26). This document does **not** repeat those. It does three things:

1. **Reconciles the June-26 borrow list against R-Co's tree today** — what shipped, what's still open, and one regression.
2. **Reports what is newly borrowable.** ASCOA-GO has been under heavy development: **505 of its 627 `internal/` files were touched since 2026-06-29**, concentrated in `sandbox`, `bpm`, `promote`, `kernel/migrate`, `agentartifact`, `files`, `taskspec`, and `template`. Most of that work postdates your last analysis.
3. **Flags two verified defects in R-Co** found while checking claims — one of them serious.

The framing from June 26 still holds: same archetype, and the language difference is the least interesting thing. Borrowing means specifications, invariants, and operational discipline — not Go code. R-Co's event-sourced core remains a genuine advantage over ASCOA's mutable hybrid store, and several ASCOA subsystems exist *only* to patch problems R-Co doesn't have.

---

## 1. Status of the June-26 borrow list

| June-26 item | Status in R-Co today |
|---|---|
| Async effects with result re-entry | **Shipped** — `src/effects/{queue,worker,adapters}`, `EFFECT_EMITTED → EFFECT_COMPLETED` re-entry |
| Tier → quota model | **Code shipped** — `src/config/quota_policy.zig` (17 KB), `src/api/middleware/quota_enforcement.zig` (12.5 KB). But the design note `src/design/exp601_tier_quota_model.md` has **no corresponding entry in the functional-requirements doc** — so it has no acceptance criteria and no status gate. Worth reconciling. |
| Written sandbox threat model | **Shipped** — `docs/sandbox_threat_model.md` (41 KB, EXP-701). Better reasoned than ASCOA's equivalent. It is now the go-live gate for EXP-702/703, both still unimplemented. |
| Modular agent-instruction files | **Partially adopted** — `.github/instructions/` exists but holds only 3 role files (backend-dev, frontend-dev, orchestrator), not glob-scoped domain rules. See §4.1. |
| `instance_waits` restore reconciliation (FR-BPM-16) | **Half done** — descriptors persisted (migration 093); the reconciliation saga is **not** implemented. Still open. |
| Generic saga runner | **Not started** — only `identity/onboarding.zig`. Still open. |
| Engine-level compensation / error boundaries | **Not started.** Still open. |
| Per-tenant secrets (envelope encryption) | **Regressed — see §5.1. This is the most urgent item in the document.** |
| Flutter mobile tier | **Not started.** |
| Step-failure semantics (FR-BPM-13/14/15) | Partially reflected; `src/dlq/store.zig` is still one file. |

---

## 2. Backend / platform — the new borrow list, ranked

### 2.1 Promotion as a gated state machine — *highest value*

ASCOA rebuilt promotion in July (FR-PROM-1..5, `internal/promote/`, 41 files touched). The shape:

`Pipeline.Execute` runs a fixed ordering: `rejectIfConflicts` (pre-flight, **before** any transaction opens; returns a typed `*ConflictRejection`, writes one `promotion_rejected` audit row in a separate tx, advances no version pointer) → `requireApprovedReview` → irreversibility guard → `runPostApprovalAssertionRerun` → per-type promote → `markReviewApplied`.

Two ideas are worth taking regardless of anything else:

- **The approval is bound to a `plan_digest`** — SHA-256 over canonical-JSON `{type, id, changes}`. An approval cannot be replayed against a different diff. The full plan is serialised into the review record at submit time, so the reviewer UI never re-runs a live diff.
- **A pre-production assertion re-run gate**: claims an ephemeral sandbox, loads *only* the artifact's fixtures (never organic staging data), replays assertions under frozen clock + seeded RNG + stub effects, `defer`s release on every exit path including panic. Results land in `promotion_assertion_runs` with `UNIQUE (tenant_id, idempotency_key)`, key `promotion_rerun:<review_id>:<plan_digest>`. Teardown failure does **not** block promotion — it emits `promotion_assertion_teardown_failed` so the leak is operator-visible instead of turning into a false negative.

**R-Co status: NO.** `src/definition/promotion.zig` is one 21 KB file implementing ENV-03 test-tenant → production-tenant promotion. No diff report, no conflict detection, no approval record, no assertion gate. Grep of the 226 KB FR doc finds 3 hits for "promotion", 3 for "rollback", 0 for "approval".

**Why this matters most for R-Co specifically:** your entire SDLC (WF-02..WF-06) is agent-driven with no human mid-workflow gate. Right now there is nothing structurally between agent output and a production definition. And this is *easier* to build in R-Co than in ASCOA: event sourcing means promotion carries no DDL, so rollback is genuinely just re-pointing the active version, and ASCOA's "irreversible contract step" carve-out disappears entirely.

**Effort:** Medium-Low. **Value:** High.

### 2.2 Version pinning for non-graph definition kinds

ASCOA keeps two parallel pin tables — `instance_pinned_versions` PK `(instance_id, entity_type)` and `instance_pinned_form_versions` PK `(instance_id, form_id)` — deliberately not one table with a nullable discriminator. Both append-only, both written in the same transaction as the instance INSERT. The hard rule: the engine **never falls back to "latest"**; a missing pin raises a typed error rather than silently serving a newer version.

**R-Co status: PARTIAL, with a live gap.** PD-08 copies the whole graph JSON into `instances.definition_snapshot` at start — stronger than ASCOA for the process graph. But nothing pins the definition kinds you've added since: service-catalog entries (REPO-07 / SVC-01..04), variable schemas, and Stage 15's `module_ref` + semver sub-process modules (PLC-01). All resolve at execution time. A months-long instance whose SERVICE_TASK re-resolves `module_ref` mid-flight is exactly the drift the pin tables prevent.

In R-Co these belong in the `INSTANCE_STARTED` event payload, not a side table.

**Effort:** Small-Medium. **Value:** High — this is a latent correctness bug in already-specified work.

### 2.3 Time-partitioned append-only logs

ASCOA partitions `process_step_log`, `pending_events`, and `event_deliveries` by `RANGE` monthly. Next-month partitions are created **proactively by the scheduler, never on demand**. Retention is `DROP TABLE <partition>` — O(1). Partition-level `CHECK (tenant_id IS NOT NULL)` enforces isolation at the partition. The conversion was zero-downtime: new partitioned parent alongside → backfill → rename swap.

**R-Co status: NO** — zero "partition" hits in either spec document. ES-07 archives expired events by **moving rows** into an `events_archive` table in a single transaction; ADP-11 forbids hard deletion of `{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}`; IR-07/XC-05 require replay to span the archive transparently.

**This is the clearest scalability defect in R-Co's spec, and event sourcing makes it worse, not better** — the event log is your single unbounded table *and* you've forbidden yourself from deleting most of it, while archiving O(n) under one long transaction.

One caveat: partition pruning needs a time predicate, and R-Co's reconstruction queries by `instance_id`. Either add `occurred_at` to reconstruction queries or accept per-partition index fan-out.

**Effort:** Medium. **Value:** High.

### 2.4 Migration fanout with a per-(migration, tenant) control table (FR-MIG-2)

`platform.platform_migrations`: one row per `(migration_id, tenant_id)`, status `pending|done|failed` + `error_msg` + `completed_at`, partial index `(migration_id, status) WHERE status IN ('pending','failed')` covering the resume query. `RunAllTenants` **collects per-tenant errors and continues** — tenant N's failure never blocks N+1. `ResumeAllTenants` touches only pending/failed rows. Idempotent via `ON CONFLICT ... DO UPDATE ... WHERE status != 'done'`. The control-row upsert commits **in the same transaction as the DDL**. Admin surface: `GET /admin/migrations/{id}/status`, `POST /admin/migrations/{id}/resume`. Never compensate across schemas — fix forward and resume.

**R-Co status: PARTIAL.** `src/db/provisioning.zig::runForSchema` applies numbered migrations per tenant schema with a startup advisory lock, but state is a plain `schema_migrations` table per schema: no cross-tenant control table, no partial-failure tolerance, no resume, no status endpoint. Your own architecture doc concedes "single-sweep startup migration lock is sufficient below 5,000 tenants." The 2026-07-02 audit still lists SPT-02/03/04 as PENDING and ISS-504 as implemented-not-released.

**Effort:** Small-Medium. **Value:** High — this is the machinery that unblocks your oldest open High audit finding (dual-path SPT coexistence).

### 2.5 `ValidatePlatformDDL` — a pure lock-safety gate (FR-MIG-3)

A pure function, no DB access. Rejects `DROP COLUMN`, `CLUSTER`, `VACUUM`, `REINDEX`, `ALTER COLUMN SET DATA TYPE` in any step, and enforces expand-then-constrain (`SET NOT NULL` requires a preceding `ADD COLUMN … NULL` for the same field). Called from the admin handler → HTTP 400 **before any tenant schema is touched**. The companion `PhasedDDLGenerator` emits exactly three statements, the backfill being idempotent and batched: `UPDATE … WHERE f IS NULL AND data ? 'f' LIMIT <batch>`.

**R-Co status: NO.** A pure string validator ports to Zig in an afternoon, and one unbounded exclusive lock × N tenant schemas is a whole-platform outage.

**Effort:** Small. **Value:** Medium-High. Best effort/value ratio on this list, alongside §2.6.

### 2.6 `plat_` reserved-prefix namespace separation (FR-MIG-4)

Tenant-authored DDL creating a table/index/named-constraint/sequence with the reserved `plat_` prefix is rejected case-insensitively, quoted or unquoted; the error must name the offender. PG auto-generated names exempt.

**R-Co status: NO** — and it matters now that you're committing to schema-per-tenant with per-tenant migrations. **Effort: XS. Value: Medium.**

### 2.7 Per-correlation FIFO at the consumption layer

ASCOA states explicitly that a single drainer guarantees lost-NOTIFY recovery and *dispatch* order — **not** per-consumer *apply* order. So the BPM consumer claims head-of-queue with `pg_try_advisory_xact_lock(hashtext(correlation_id))` + `FOR UPDATE SKIP LOCKED`: strictly in order and singly in flight *within* a correlation, parallel *across* correlations. Order-insensitive consumers (effects, alerts) use plain `SKIP LOCKED`.

The paired distinction is worth internalising, because these three are routinely conflated: instance-level `FOR UPDATE SKIP LOCKED` prevents double-**claiming**; `step_execution_id` prevents double-**execution**; the correlation lock supplies **order**.

**R-Co status: PARTIAL.** You have `FOR UPDATE SKIP LOCKED` on timers and a scheduler advisory lock, plus `effects/queue` and `dlq`, but no per-correlation serialisation on `EFFECT_COMPLETED` re-entry. Two effects for one correlation completing out of order will drive catch-event matching wrong. **Effort: Small. Value: Medium-High.**

### 2.8 Agent-artifact envelope (FR-AGT-1/3/5/7)

Given that R-Co's whole SDLC is agent-driven, this is more relevant to you than to ASCOA. Artifacts persist in the **staging** schema (403 `wrong_environment` otherwise), discriminated by `kind`, idempotent on `(tenant_id, task_spec_id, attempt_count)` using `ON CONFLICT … RETURNING xmax = 0` to distinguish a fresh insert from a re-hit (200 re-hit / 409 on `spec_hash` mismatch). Task specs are immutable: `spec_hash` = SHA-256 of canonical JSON, and `RngSeed` is validated non-zero and folded into the hash, so **determinism is bound into spec identity**. Retention is a dual sweep: verified rows are exempt from the needs-review TTL until *either* the pinned `(task_spec_version, process_definition_version)` pair is GC'd *or* `STAGING_VERIFIED_TTL_DAYS` (365) elapses — **whichever is later**.

One detail worth stealing as a habit: the legacy field name `ignore_fields` is **rejected as a validator error, not silently aliased** to `non_deterministic_fields`.

**R-Co status: NO** module. `repository/` (content-addressed artifacts) and `simulation/scenario_runner` supply primitives. **Effort: Medium. Value: High.**

### 2.9 Orchestrator/implementer separation enforced at the API layer (FR-AGT-7/8/9)

The boundary is enforced in handlers, not by deployment convention. Orchestrator = `agent.submit_task_spec` permission **AND** `tenant_orchestrator` realm role; the handler force-sets `spec.OrchestratorPrincipal = identity.Subject` so the persisted JSON is authoritative. `PoolManager.Claim` rejects orchestrator-role callers — an orchestrator cannot drive its own sandbox while retaining cross-sandbox supervisory read. Sandboxes bind at claim to `(tenant_id, agent_principal, task_spec_id)`, and **one sentinel error → 403 covers both not-found and wrong-tenant**, so response codes can't be used to probe existence across tenants.

**R-Co status: PARTIAL** — `src/oidc/` has agent identities and the threat model covers role simulation well, but there's no ownership binding, no orchestrator/implementer split, and no probe-safe sentinel. Take the auth/audit half (store-agnostic, small); the warm-schema-pool half is a schema-per-tenant artifact you partly obviate via `simulation/{time_source,uuid_source,mock_catalog}`.

**Effort:** Small (auth) / Large (pool). **Value:** High (auth) / Medium (pool).

### 2.10 Second tier — worth a look, lower urgency

- **File / attachment subsystem (FR-FILE-1/2/3).** R-Co has none. HMAC-signed download URLs (`?kid&exp&sig`, payload `kid\nexp\nattachment_id\ntenant_slug`, slug server-derived; cross-tenant probes return 404 not 403), transactional quota (upload row + usage counter + outbox in one tx), and a three-sweep deletion reaper idempotent via `WHERE expected_state` predicates rather than locks. Human tasks with `form_schema` aren't usable for real business processes without document attachment. **Effort: High. Value: High.**
- **Generic entity query API (FR-QRY-1/2/3).** Filters/sorts allowed on typed columns and on **declared** `filterable_jsonb_keys` only; an undeclared key is a 400. An unauthorised entity type returns **200 with an empty envelope, not 403**. R-Co has cursor pagination (API-06) on fixed endpoints but no generic query over `src/entities` projections — so tenant-defined entities are effectively write-only to an app builder. Borrow the query surface and the declared-key contract; **not** the placement-state machine behind it.
- **Formula type-check at promotion (FR-VAL-4).** ASCOA compiles every formula against a **typed environment built from the definition's field context**, so a type error or unknown-field reference fails at promotion. R-Co validates CEL **syntax only** (PD-06) and explicitly defers semantics to runtime (EE-05). Cheapest correctness win in the validation family. **Effort: Low-Medium. Value: Medium-High.**
- **Outbox depth cap with two backpressure paths (FR-GRO-4).** External ingress over cap → 429, counted **before** the transaction opens so the idempotency key isn't consumed. An internal emit over cap can't be 429'd mid-transaction, so it returns a typed overflow error and **fails its step** into the normal rollback → backoff → dead-letter path, letting the runaway producer throttle itself. **Effort: Small. Value: Medium.**
- **Reaper conventions.** Issue the storage call *before* opening the transaction, so no DB lock is held across a streaming delete and a storage failure leaves no DB write. Idempotency via `WHERE expected_state`, not advisory locks. **Effort: Small. Value: Medium.**
- **Pre-vetted template auto-promotion (FR-TPL-5).** A publisher marks a version pre-vetted, and provisioning auto-promotes staging→production via `Pipeline.PromoteTemplateSeed` — a **separate entry point that structurally cannot reach the gate**, explicitly not a skip flag on `Pipeline.Execute`. That routing-not-flagging choice is the borrowable part. Your SOL-01/02/03 + PLC-01..04 already cover most of the bundle mechanics; the genuine gaps are FR-TPL-5 and FR-TPL-3 (update-offer diffed against tenant customisations).

---

## 3. Frontend

R-Co's `docs/guides/frontend_design_system.md` (10.6 KB) is real and reasonably complete — colour tokens, typography, spacing, status badges, canvas node styles, Button/DataTable/Dialog/Toast/JsonEditor/DynamicForm APIs, layout template, breakpoints. **The gap is not specification, it's implementation:** `web/src/components/ui/` contains exactly one file (`JsonDiffView.tsx`), and `design-tokens/r-co.tokens.json` is 377 bytes. Every one of ~15 pages across 12 API domains is inventing its own loading and error handling.

**3.1 The five-state renderer contract — best value/effort on the frontend.** ASCOA requires every renderer to handle exactly five states, and a missing one is a *test failure*, not a review comment. Named components: `SkeletonLayout`, `FetchError({onRetry})`, `PermissionDenied` (test asserts no error code or status text leaks), `StaleVersionError`, `RateLimitBackpressure({retryAfter})` with a 429 countdown — narrowed by a `classifyError()` helper to the union `'loading'|'success'|'fetch-failure'|'permission-denied'|'stale-version'|'rate-limit'`. The same table is restated for Flutter, so it's client-agnostic. **R-Co has none of these.** Five components plus a helper. **Effort: Small. Value: Very high.**

**3.2 Tenant-scoped React Query keys.** ASCOA's keys are `['definition', tenantSlug, type, id, version]` — `tenantSlug` in position 2 is an explicit cross-tenant cache-leak mitigation with a named regression test. **Verified: R-Co's `web/src/api/queryKeys.ts` has no tenant segment**, despite `auth/tenantConfig` and `TenantHeader` establishing per-tenant sessions. Small change, security-relevant. **Effort: Small. Value: High.**

**3.3 Write the generic-renderer principle down.** ASCOA states it as an architecture rule — *"the SPA is a generic interpreter of server-delivered definitions; it never contains a hand-coded screen for any tenant entity"* — and enforces it structurally: `renderers/{form,list,process,task}/` hold logic, `features/` are thin route shells, `editors/` are staging-only. `FieldRegistry.registerField(type, component)` is the documented extension surface, so a new field type is an additive frontend-only change. R-Co's `DynamicFormRenderer` + `FieldFactory` + `formSchemaParser` is the same idea for forms, but `pages/` is screen-per-domain and there's no registry API or list/task equivalent. Converging fully is Large; writing the principle down and adding `registerField` is Small.

**3.4 Static-guard tests.** ASCOA's FR-UI-NFR-1/2 aren't really NFRs — they're executable architecture guards: forbidlist modules as single source of truth, imported by both a source scan and a post-build bundle scan (which `rmSync`s `dist/` and runs a real `vite build` in `beforeAll`). Each regex is paired with a **META "test the test"** control asserting it matches a synthetic offender *and* misses innocent bystanders. Guards report file paths and pattern names only, never matched content. R-Co's `lint_frontend_conventions.py` is the same instinct but sits outside the test suite with no META controls. This fits your agent pipeline well — a validator gate can't be argued with. **Effort: Small-Medium. Value: High.**

**3.5 Accessibility gate.** One `it()` per canonical surface, failing on any `serious` or `critical` axe violation; `color-contrast` disabled at gate level (jsdom can't do pixels) and guaranteed instead by the token contract. Per-field ARIA specified verbatim: `<label htmlFor>`, `aria-required`, `aria-describedby`, `aria-invalid` + `aria-errormessage`, `aria-busy` on the form. R-Co has no a11y reference anywhere. **Effort: Medium. Value: High.**

**3.6 409 conflict UX.** Three actions — refetch latest / merge manually / discard mine — portal-mounted, never silently overwriting. `web/src/components/ui/JsonDiffView.tsx` is already the raw material.

**Two caveats.** First, **ASCOA has no performance budgets** — despite the file names, FR-UI-NFR-1/2 are hygiene guards. There is no LCP/TTI/bundle-size/p95 target anywhere. If you want perf budgets you must author them; ASCOA is not a source. (It also has an unresolved internal contradiction: 200 ms debounce in `ARCHITECTURE_WEB` vs 300 ms in the frontend guide. Don't import that.) Second, **don't import ASCOA's test substrate** — it leans on MSW and jsdom-axe, and your DIRECTIVE T-2 forbids MSW outright. Borrow the *contracts* (five states, allowlist, ARIA wiring, static guards — all substrate-independent) and realise them as Playwright steps.

---

## 4. Process and governance

### 4.1 Split `CLAUDE.md` into glob-scoped instruction files with one source of truth

ASCOA's `CLAUDE.md` is ~120 lines of pointers. The enforceable rules live in 7 files under `.github/instructions/`, each with YAML frontmatter scoping it (`applyTo: "**/*.go"`, `applyTo: "migrations/**"`, `applyTo: "**/*_test*"`). Role definitions live once in `.copilot/agents/`; `.claude/`, `.github/agents/`, `.kilo/` are thin adapters, with the rule stated explicitly: *"If you change agent behavior, edit the files under `.copilot/`… otherwise the two harnesses will drift apart."*

**R-Co: NO.** Every agent loads all 1,438 lines of `CLAUDE.md` — BO personas, UAT rules, ORCH estimation code — regardless of role. The same role text also exists in `.claude/agents/` (13 files), `.github/agents/` (18 files), `.github/instructions/` (3 files), and `docs/agents/`. Four copies, no stated canonical. Your own June-26 analysis recommended this (§6.1) and it wasn't adopted. **Highest-value process item.**

### 4.2 Numbered security invariants with verification steps — and a security agent

`security-invariants.instructions.md` gives INV-1..INV-11, each with Rule / Reference (FR-id) / **How to verify** / severity. E.g. INV-1: *"Platform-schema tables: EVERY query MUST include `WHERE tenant_id = $1`… Violation = BLOCKER. No exceptions for 'internal' or 'admin' paths."* A dedicated `security-reviewer` subagent gates every new data-access path.

**R-Co: PARTIAL/NO.** Four "Security rules (hard constraints)" sit *inside the BACKEND-DEV section* of `CLAUDE.md` — so FRONTEND-DEV and ISSUE-FIXER never read them — with no verification steps, no severities, and **no security agent in the 13-agent roster**. For a multi-tenant BPM platform running two untrusted runtimes, this is the largest governance hole. Pair it with ASCOA's `tenant-isolation.yml` workflow: path-triggered, spins `postgres:16-alpine`, migrates, runs `go test ./internal/kernel/... -run CrossTenant`.

### 4.3 Smaller process borrows

- **A committed Zig-level lint gate.** ASCOA's `.golangci.yml` enables 20 linters (`errorlint`, `contextcheck`, `rowserrcheck`, `sqlclosecheck`, `gosec`, `exhaustruct`…), plus a policy that no suppression may exist without a written rationale. R-Co's three custom linters police *process artefacts*, not backend code — there is no `zig fmt --check` and no vet gate anywhere. Your only Zig-level check is `zig build 2>&1 | grep -i "error set"`, which your own docs call "the #1 cause of TEST-RUNNER compile failures." That grep belongs in a build step, not in prose.
- **A Makefile (or one `.ps1`) as the single command surface.** ASCOA's is 83 lines and self-documenting; `make test-live` boots Postgres and *waits* (10× `pg_isready` retry loop) before running integration tests. R-Co's commands are duplicated across `README.md`, `CLAUDE.md`, and both guides, forked bash/PowerShell. Every agent hand-assembles env + command, and TEST-RUNNER's service pre-check is prose — a whole class of INFRA_BLOCK round-trips.
- **Scored test-tier rubric.** ASCOA scores a change across 8 dimensions (DB schema 2, tenant isolation 2, Wasm 2, cross-module 1, transactional boundary 1…): *"0 points: unit only. 1–2: unit + integration. 3+: unit + integration + sandbox."* R-Co has good fixed coverage thresholds but no rule for *which tiers a given change requires*, so TEST-DESIGNER re-derives it every run. Add the **fail-first rule** at the same time — *"a test that passes both before and after the code change provides no value"* — it's nearly free to add to TEST-DESIGN-VALIDATOR's checklist and R-Co lacks it entirely.
- **"Test helpers apply real migration files; never handcode DDL."** ASCOA learned this the hard way (`idempotency_keys.key` → `key_value` drift, ISS-041) and pins each divergence with a regression test. R-Co is append-only-migration and event-sourced, so drifting test DDL fails late and confusingly.
- **Gate tiering + flakiness policy + pre-commit contract.** PR gate (unit, fast integration, lint, build — each timed) / merge gate (slow integration, sandbox, tenant isolation) / nightly (perf, chaos). *"Tag `@flaky`, skip on PR, investigate… Fix within 48h or disable."* R-Co has none of these and runs everything every time. Also borrow ASCOA's path-filter trick: coordination-only changes (`.copilot/claims/**`) hit an always-green marker job — R-Co commits `handoffs/**` and `registry.json` constantly and shouldn't pay a full suite for them.
- **Bound cascading fixes in-branch.** ASCOA explicitly retired per-issue subworkflows: register → develop → security-review → test → **one `fix(ISS-n):` commit on the parent branch**, budget **5 per workflow**, then terminate in `needs-review`. R-Co's `max_rework: 3` is the same intent, but WF-05 "spawns WF-03 for every BLOCKER and MAJOR issue" — the exact fan-out ASCOA measured as prohibitively expensive.
- **An operations runbook.** `OPERATIONS.md` documents config the app assumes but doesn't control (`ALTER ROLE ascoa_app SET search_path TO platform, public;`), enforced by a startup assertion right after `db.Ping()` that emits a deterministic FATAL line whose 7 substrings are **pinned by a test** so alerts can match it. R-Co has no runbook and no startup assertions — see §5.2.

---

## 5. Two verified defects found while checking claims

### 5.1 `src/secrets/crypto.zig` does not encrypt anything — **fix this first**

Read directly and confirmed. `encrypt()` discards the master key (`_ = master_key;`), generates a random nonce, auth tag, and data key that are **never used for anything**, and sets `ciphertext = allocator.dupe(u8, plaintext)`. `decrypt()` likewise discards the key and returns `dupe(envelope.ciphertext)`. Meanwhile the envelope declares `algorithm: .aes_256_gcm` and `wrapped_key_algorithm: .aes_kw_256`.

Net effect: **every tenant secret is stored in the database in plaintext, behind metadata that claims AES-256-GCM envelope encryption.** The code comment is candid — *"Wave-1 envelope model… reserve true AEAD wrapping for a follow-up hardening step"* — so this is deliberate and unfinished, not accidental. But the failure mode is bad in both directions: an operator reading the envelope metadata, or the June-26 audit recording "secrets module exists," would both conclude the opposite of the truth.

Zig's standard library has `std.crypto.aead.aes_gcm.Aes256Gcm` and this is roughly a 20-line fix plus a key-wrapping decision. Whatever else you take from ASCOA, do this first, and add a test asserting `ciphertext != plaintext`.

### 5.2 `.env.example` is incomplete

R-Co's is 37 lines and **omits every Keycloak variable**, despite `README.md` requiring Keycloak on :8081 for login, and omits `BPM_UAT_TOKEN` / `BPM_API_URL`, which `CLAUDE.md`'s UAT-RUNNER section invokes directly. ASCOA's is 80 lines and documents each variable's consuming file *and* its empty-value behaviour (*"All empty in dev → client is nil → saga warn-and-skips Keycloak steps"*). Small, but it's a live onboarding defect, not a nice-to-have.

---

## 6. What NOT to borrow

- **`entity/placement*`, expand/contract field promotion, `dual_write`, the hot-field monitor.** This entire subsystem exists *because* ASCOA has a mutable hybrid column+JSONB store where a version-pinned writer could write to the wrong physical location and silently lose data. R-Co's `src/entities/` is events + typed projections; the log is authoritative and projections are rebuildable. **Residual lesson worth keeping though:** never let two readers resolve "where does this value live" through different maps. R-Co's analogue is a projection rebuilt under definition version N while a pinned instance reads version N−1. Decide that explicitly rather than by accident.
- **Writing the failure log in a separate transaction after rollback** (FR-BPM-12 AC-5). ASCOA spawns a goroutine opening a fresh tx so the failed-step row survives the rollback. Importing this would violate R-Co's stated invariant that the audit log stays in-transaction with every state change, and would create an event with no corresponding state transition. Your DLQ is the right home. Take the semantics, not the mechanism.
- **Warm schema pool with sub-second claim.** Real value, but it's a schema-per-tenant artifact, and `simulation/{time_source,uuid_source,mock_catalog}` already gives you most of the determinism.
- **Role-simulation confinement (FR-ENV-9)** — R-Co's threat model (EXP-701) already specifies this, and arguably better-reasoned. Don't port.
- **Graph static validation (FR-VAL-2)** — R-Co's PD-02 is equal or stricter (500 nodes / 2,000 edges caps, cycle rules). Don't port.
- **User groups** — IDN-02 is complete. Don't port.
- **Staging subdomain routing (FR-ENV-1)** — R-Co's ENV-01/03 test-tenant model solves the same business problem differently. Low value.

---

## 7. What ASCOA should borrow from R-Co

Worth recording, since the flow isn't one-directional:

1. **`reqctl.py` as a single requirements store.** R-Co collapsed ~150 markdown requirement files into `docs/requirements.yaml` with `add`/`show`/`validate`/`set-status`/`render-status`, and forbids hand-editing generated status. ASCOA still hand-flips statuses in a 175 KB `IMPLEMENTATION_ORDER.md` — the exact "status flipped before merge confirmed" bug its v1.2 rule was written to patch.
2. **The estimation → retrospective → rule-adjustment loop.** `metrics/estimation_rules.json` + difficulty × integration-surface surcharge, with variance ≥25% across two consecutive same-difficulty runs feeding back into the rules. 118 retrospectives on file. ASCOA has no work-metrics loop at all.
3. **Codegen from typed design artefacts.** The Type A–E artefact classification, `codegen_*.py --dry-run` as a validator gate, and "boilerplate is regenerated; only edit `// CUSTOM:` blocks" is a stronger anti-drift mechanism than convention docs.
4. **Business-owner UAT with adversarial personas.** Three tenant personas, Meridian's 2-of-3 quorum, a PRODUCT-OWNER cross-tenant gate, and a report-language rule banning stack traces. ASCOA says "reviewed at UAT" and leaves UAT undefined.
5. **Hard-gate validator agents before work starts** (CODE-DESIGN-VALIDATOR at step 1b, TEST-DESIGN-VALIDATOR at 3b). ASCOA's `quality-gate` only runs at the end, so a bad design is caught after implementation.
6. **Absolute no-mocks + visual-verdict E2E** (T-1/T-2/T-3: *"verdict must be 'Screen shows X after action Y'"*). ASCOA still permits mocked cross-module deps in unit tests.
7. **Event sourcing itself.** Three of ASCOA's audit rounds went into problems the event log doesn't have.

---

## 8. Recommended sequence

1. **Fix `secrets/crypto.zig`** (§5.1). Hours, not days. Everything touching authenticated external APIs is currently building on sand.
2. **Cheap structural gates, in one pass** — `plat_` prefix validator (§2.6), `ValidatePlatformDDL` (§2.5), tenant segment in query keys (§3.2), `.env.example` completion (§5.2). All small, all independent.
3. **Split `CLAUDE.md` + add security invariants and a security-reviewer agent** (§4.1, §4.2). This makes everything after it cheaper to enforce, and it's your second unadopted recommendation from June.
4. **Pin the non-graph definition kinds** (§2.2) — closes a latent correctness bug in work already specified.
5. **Migration control table + resume** (§2.4) — unblocks the SPT dual-path finding that's been open since June 11.
6. **The five-state renderer contract + shared `ui/` layer** (§3.1) — your design system is written but unbuilt; this is the smallest step that starts paying it off.
7. **Promotion gate with plan-digest-bound approval** (§2.1) — the largest single win, and cheaper in an event-sourced system than it was for ASCOA.
8. **Partition the event log** (§2.3) — plan it before the table is large enough that the zero-downtime swap is scary.

---

*Static comparison, 2026-07-29. Claims about R-Co reflect its `src/`, `web/`, `docs/`, `.claude/`, and `.github/` trees; claims about ASCOA-GO reflect its `internal/`, `docs/`, and `.github/` trees. Two claims (§5.1 secrets crypto, §3.2 query keys) were verified by reading the source directly. Where ASCOA requirements are still `not-started` on its own side — FR-TPL-1..5, FR-TIER-1/2, FR-I18N-1/2 — you would be porting a specification, not a proven design; FR-FILE-2/3 and FR-MIG-2/3/4 are marked implemented with concrete file and test names, so their acceptance criteria are directly reusable as requirement text.*
