# Changelog

All notable changes to the BPM Platform are documented here.

## [SPT-01] — 2026-06-05
### Added
- Schema-per-tenant provisioning infrastructure (`migrations/060_schema_per_tenant_bootstrap.sql`)
- `public.tenant_schemas` registry table for tracking provisioned tenant schemas
- `public.bpm_provision_tenant_schema(UUID)` PL/pgSQL function for safe concurrent schema creation
- `src/db/migrations.zig`: `runForSchema()` — applies migrations inside a named tenant schema
- `src/db/pool.zig`: connection checkout now sets `search_path` to the tenant's schema in addition to the `bpm.tenant_id` session variable (backward-compatible transition)
- `src/db/provisioning.zig`: `provisionTenantSchema()` — idempotent orchestration of schema creation + migration run
### Notes
- Both `search_path` and `bpm.tenant_id` session variable are set during this transition phase; SPT-03 will remove the column-based approach.

## [Unreleased]

### Stage 12 — Schema-Per-Tenant Isolation (RELEASED 2026-06-10)

- **TNT-01** (MUST): Business tables migrated to per-tenant schemas — All 21 business tables now live in `tenant_<uuid>` PostgreSQL schemas, not in `public`. Migrations 001–071 create tables inside the tenant schema when run via the updated migration runner; public business tables are removed by `GBL-073_tnt01_drop_legacy_public_business_tables.sql`. Legacy table names (`dead_letter_queue`, `form_schema_registry`) renamed to canonical names (`dead_letter_items`, `repository_form_schemas`) via migration 072.
- **TNT-02** (MUST): Migration runner enforces search_path isolation — `src/db/migrations.zig` issues `SET search_path TO <tenant_schema>, public` as the first statement on the migration connection before executing any migration SQL. `schema_migrations` tracking uses a `(schema_name, version)` composite primary key for per-tenant migration state. CI linter `tools/lint_migration_schema.py` rejects any migration SQL file that contains `public.<business_table>` references (21 business table patterns enforced); allows `public.tenant_schemas`, `public.tenant`, and `public.schema_migrations` references.
- **TNT-03** (MUST): Connection pool sets search_path per tenant on checkout, resets on return — Pool checkout issues `SET search_path TO <tenant_schema>, public` for tenant-scoped requests and `SET search_path TO public` for platform-admin/no-tenant requests. Connection return issues `SET search_path TO public`; if the reset fails, the connection is discarded rather than returned to the pool. Search path is re-applied after reconnect.
- **TNT-04** (MUST): Platform startup audits public schema and logs ERROR for unexpected tables — On startup, the platform queries `information_schema.tables` for all `BASE TABLE` and `VIEW` objects in the `public` schema and compares against the permitted list of 10 tables (`tenant`, `tenant_schemas`, `tenant_hostnames`, `tenant_realm_binding`, `schema_migrations`, `onboarding_registry`, `service_catalog`, `repository_artifacts`, `repository_activations`, `alerting_state`). Unexpected tables produce an `ERROR` log entry naming the table. During active migration windows (`migration_window_active = TRUE`) the severity is downgraded to `WARN`. No hard-stop occurs.
- Validation evidence: 19/19 integration tests passing in `tests/reports/report-20260610-WF02-tnt-batch1-20260609.yaml`. NFR benchmarks: p99_read=0.609ms, p99_write=1.277ms, throughput=114547 events/sec, replay_10k=32.735ms — all within targets. Release approval: `docs/status/release-stage12-tnt-batch1-20260610.yaml`.
- Requirements: TNT-01, TNT-02, TNT-03, TNT-04 (Stage 12) — RELEASED

### 2026-06-07
#### Fixes
- [ISS-0068] Fixed missing tenant schema provisioning in onboarding saga - after tenant registration, PostgreSQL schemas (tenant_default, tenant_<uuid>) are now created correctly. Retroactive migration (069/070) provisions schemas for pre-existing tenants.
- [WF02-uat-tenant-url-20260607] Released UAT tenant-realm URL resolution flow for UAT-TM-01..04: Playwright helper token acquisition now supports tenant realm parameterisation and tenant context resolution by company slug, and UAT runner docs/schema guidance now define company_id as the only required tenant selector.

#### Released
- UAT-TM-01, UAT-TM-02, UAT-TM-03, UAT-TM-04 marked RELEASED via WF02-uat-tenant-url-20260607 (release decision: docs/status/release-uat-tenant-url-2026-06-07.json; test evidence: tests/reports/report-2026-06-07-WF02-uat-tenant-url-20260607.yaml).

### Stage F8 Batch 2 - Tenant Lifecycle Controls (RELEASED 2026-06-06)

- **TM-04** (MUST): Deactivate tenant - Added tenant deactivation lifecycle action in tenant management with state-aware visibility, confirmation UX, backend lifecycle API integration, and deterministic error handling for forbidden/not-found/invalid-state paths.
- **TM-05** (MUST): Reactivate tenant - Added tenant reactivation lifecycle action with complementary state-aware controls, confirmation UX, lifecycle API integration, and post-action query refresh behavior.
- Validation evidence: TM-scoped integration and lifecycle E2E checks passing in tests/reports/report-20260607-WF02-f8-batch2-20260607-rerun3.yaml. Release approval: docs/status/release-f8-batch2-20260607.yaml.

### Stage F8 Batch 1 - Tenant Management GUI (RELEASED 2026-06-06)

- **TM-01** (MUST): Platform-admin tenant list — Added paginated, sortable tenant list page with columns for slug, display name, hostname, realm, status, and timestamps. PLATFORM_ADMIN-only access with role-based DOM hiding and redirect for unauthorized users.
- **TM-02** (MUST): Navigation to onboarding — Added "Register Tenant" button on the tenant list page (PLATFORM_ADMIN only) navigating to the tenant onboarding wizard from Stage F7.
- **TM-03** (MUST): Edit tenant mutable fields — Added edit tenant page with inline editing of display_name. Immutable fields (slug, idp_realm_id) are read-only and rejected with 422 if submitted. Non-existent tenant returns 404.
- Validation evidence: 7/7 E2E tests passing (TC-TM-UI-01 through TC-TM-UI-07). Release approval: docs/status/release-f8-batch1-20260606.yaml.

### Stage F7 - Tenant Onboarding GUI (RELEASED 2026-06-05)

- **ONB-UI-01** (MUST): Register Tenant entry point — PLATFORM_ADMIN-only nav item in the admin sidebar, DOM-hidden for non-admin users. Direct URL access to admin onboarding screens is role-guarded with redirect to /instances.
- **ONB-UI-02** (MUST): Tenant registration form — RegisterTenantPage with fields for slug, display name, hostname, admin email, admin username, admin display name, and redirect URIs. Client-side validation, Idempotency-Key generation per submission, and POST /api/v1/onboarding on submit with navigation to the progress screen on 201.
- **ONB-UI-03** (MUST): Onboarding progress display — OnboardingProgressPage polling GET /api/v1/onboarding/:id at a fixed interval. Stops polling on terminal states (completed/failed). Shows a spinner during progress and clears the interval on unmount. After three consecutive 5xx transient poll errors, displays an error banner with Retry button.
- **ONB-UI-04** (MUST): Onboarding result screen — OnboardingResultPage showing slug and oidc_authority on success; failure reason and Try Again button on failure. Try Again navigates to RegisterTenantPage with form prefill values. Page-reload restore via GET /api/v1/onboarding?hostname= query on mount.
- Validation evidence: 18/18 E2E tests passing (ONB-UI-01: 5, ONB-UI-02: 6, ONB-UI-03: 3, ONB-UI-04: 3, onboarding-wizard pipeline: 1). Release approval: docs/status/release-stage-f7-tenant-onboarding-2026-06-05.json.

### ISS-0063 - OIDC login redirect loop closeout (RESOLVED 2026-06-01)
- Closed out the login redirect loop regression after verified validation passed: the gateway now preserves the exposed port in the Keycloak Host header, OIDC callback state survives reloads, and tenant-config returns the browser-aligned localhost authority.
- Regression evidence is in tests/reports/report-20260531-WF03-login-redirect-loop-20260601.yaml; release approval is recorded in docs/status/release-WF03-login-redirect-loop-2026-06-01.json.

### Stage F6 - DLQ + Webhooks (Batch 1)

### DLQ-UI-01..DLQ-UI-04 - Dead-letter queue operator release batch (RELEASED 2026-05-31)
- **DLQ-UI-01** (MUST): DLQ list - Added a paginated DLQ table showing source type, related instance link, failure reason, retry count, created time, and current status.
- **DLQ-UI-02** (MUST): DLQ detail panel - Added item detail view exposing full failure reason, context JSON, retry history, and source payload information.
- **DLQ-UI-03** (MUST): Retry action - Added row-level Retry action wiring to DLQ retry mutation with immediate UI feedback on mutation outcome.
- **DLQ-UI-04** (MUST): Discard action - Added confirmation-gated Discard action with explicit warning copy when the DLQ item is tied to an instance cancellation path.
- Validation evidence passed in tests/reports/report-2026-05-31-WF02-f6-dlq-webhooks-batch1-20260531.yaml; release approval is recorded in docs/status/release-stage-f6-dlq-webhooks-batch1-2026-05-31.json.
- Requirements: DLQ-UI-01, DLQ-UI-02, DLQ-UI-03, DLQ-UI-04 (Stage F6) - RELEASED

### DLQ-UI-05, WH-UI-01..WH-UI-03 - DLQ badge and webhook subscriptions release batch (RELEASED 2026-05-31)
- **DLQ-UI-05** (MUST): DLQ nav badge - Added a pending-DLQ counter badge in the main app shell navigation with alert colouring when the threshold is exceeded.
- **WH-UI-01** (MUST): Webhook list - Added the Webhooks page with subscription listing and create flow for target URL, secret, and status.
- **WH-UI-02** (MUST): Webhook pause/resume - Added ACTIVE/PAUSED toggle actions on each webhook row with immediate list refresh.
- **WH-UI-03** (MUST): Webhook delete - Added row-level delete action with confirmation and list refresh.
- Validation evidence passed in tests/reports/report-2026-05-31-WF02-f6-dlq-webhooks-batch2-20260531-rerun.yaml; release approval is recorded in docs/status/release-stage-f6-dlq-webhooks-batch2-2026-05-31.json.
- Requirements: DLQ-UI-05, WH-UI-01, WH-UI-02, WH-UI-03 (Stage F6) - RELEASED

### WH-UI-04 - Webhook delivery log follow-up release (RELEASED 2026-05-31)
- **WH-UI-04** (SHOULD): Delivery log - Added subscription detail access with a recent delivery-attempts table showing delivery status, HTTP response code, and timestamp for each webhook attempt.
- Failed delivery attempts now stay visually highlighted even when a response code is absent, and an explicit empty-state view is shown when a subscription has no delivery history yet.
- Validation evidence passed in tests/reports/report-2026-05-31-WF02-f6-wh-ui-04-20260531-step04.yaml; release approval is recorded in docs/status/release-stage-f6-wh-ui-04-2026-05-31.json.
- Requirements: WH-UI-04 (Stage F6) - RELEASED

### Stage F5 - Administration (Batch 1)

### ADM-UI-01..ADM-UI-04 - Admin users release batch (RELEASED 2026-05-30)
- **ADM-UI-01** (MUST): User list - Added a paginated, searchable users table with columns for username, display name, email, roles, status, and created date.
- **ADM-UI-02** (MUST): Create user - Added New User flow to create users with username, display name, email, and initial role assignments via POST /users.
- **ADM-UI-03** (MUST): Edit user - Added user detail editing for display name, email, ACTIVE/INACTIVE status, group memberships, and role assignments.
- **ADM-UI-04** (MUST): Deactivate user - Added explicit deactivate action that sets status to INACTIVE with confirmation messaging.
- Validation evidence passed in tests/reports/report-20260530-WF02-f5-admin-batch1-step04.md; release approval is recorded in docs/status/release-stage-f5-admin-batch1-2026-05-30.json.
- Requirements: ADM-UI-01, ADM-UI-02, ADM-UI-03, ADM-UI-04 (Stage F5) - RELEASED

### Stage F5 - Administration (Batch 2)

### ADM-UI-05..ADM-UI-08 - Admin groups and tokens release batch (RELEASED 2026-05-30)
- **ADM-UI-05** (MUST): Group management - Added Groups admin section supporting group listing with member counts, group creation, member add/remove, and empty-group deletion flows.
- **ADM-UI-06** (MUST): Token list - Added API Tokens admin table with associated user, granted roles, expiry date, created date, and revoked-state visibility without exposing raw token values.
- **ADM-UI-07** (MUST): Issue token - Added Issue Token workflow collecting target user, role set, and optional expiry; token value is shown exactly once with copy action and non-retrievable warning.
- **ADM-UI-08** (MUST): Revoke token - Added token revoke action with confirmation dialog and revoked-state UI treatment in token list rows.
- Validation evidence passed in handoffs/WF02-f5-admin-batch2-20260530/step-04-test-runner.json; release approval is recorded in docs/status/release-stage-f5-admin-batch2-2026-05-30.json.
- Requirements: ADM-UI-05, ADM-UI-06, ADM-UI-07, ADM-UI-08 (Stage F5) - RELEASED

### Stage F5 - Administration (Batch 3)

### ADM-UI-09..ADM-UI-11 - Admin observability release batch (RELEASED 2026-05-30)
- **ADM-UI-09** (MUST): Health dashboard - Added `/admin/health` dashboard cards for readiness, database connectivity, scheduler status, DB latency, and uptime with 15-second auto-refresh behavior.
- **ADM-UI-10** (SHOULD): Metrics viewer - Added `/admin/metrics` rendering for Prometheus `GET /metrics` output grouped by metric family with readable sample/labels/value tables.
- **ADM-UI-11** (MUST): Audit log viewer - Added `/admin/audit` paginated filtering by actor/resource/time and expandable JSON before/after diff rows.
- Validation evidence passed in tests/reports/report-20260530T232838Z-WF02-f5-admin-batch3-step04-recovery-rerun.yaml; release approval is recorded in docs/status/release-stage-f5-admin-batch3-2026-05-31.json.
- Requirements: ADM-UI-09, ADM-UI-10, ADM-UI-11 (Stage F5) - RELEASED

### Stage F4 — Task Inbox

### TK-UI-01..TK-UI-10 - Task inbox full release batch (RELEASED 2026-05-30)
- **TK-UI-01** (MUST): Task inbox display — Authenticated users see a list of tasks assigned to them or their groups, with columns for task name, definition, due date, assignee, and status. Filtering by status, assignee, and definition is supported.
- **TK-UI-02** (MUST): Task detail panel — Selecting a task opens a slide-in detail panel showing full task metadata (name, description, due date, priority, assignee, form schema fields) with action buttons contextualised by role.
- **TK-UI-03** (MUST): Dynamic form schema rendering — Task detail panel renders the form schema attached to the task node as an interactive form with supported field types (text, number, select, checkbox, date). Form values are pre-populated from task variables.
- **TK-UI-04** (MUST): Task completion — Assignees can submit the rendered form to complete a task; the UI calls POST /tasks/:id/complete with form field payloads and transitions the task to COMPLETED status with optimistic UI feedback.
- **TK-UI-05** (MUST): Claim group-assigned tasks — Tasks assigned to a group (no individual assignee) display a Claim button; clicking it calls POST /tasks/:id/assign to set the current user as assignee before allowing completion.
- **TK-UI-06** (MUST): Reassign tasks (operator) — Operators see a Reassign button on any task detail panel; selecting a new assignee from a user picker calls the assign endpoint and updates the task record, with the change reflected immediately in the inbox.
- **TK-UI-07** (SHOULD): Sort and free-text search — The inbox supports column-header sorting (due date, name, priority) and a free-text search bar that filters visible tasks client-side with debounce, plus server-side search via query param.
- **TK-UI-08** (SHOULD): Navigation badge count — The sidebar navigation entry for Tasks shows a live badge with the count of pending tasks assigned to the current user; badge updates on a polling interval without requiring page reload.
- **TK-UI-09** (SHOULD): Escalation indicator — Tasks past their due date display a distinct escalation indicator (warning icon + red tint) in both the inbox list row and the detail panel header.
- **TK-UI-10** (MUST): Mobile responsive layout — Task inbox and detail panel are fully usable on viewport widths ≥ 375 px; detail panel renders as a full-screen overlay on mobile, and form fields stack vertically with touch-friendly tap targets.
- Validation evidence: 29/29 E2E tests passing in tests/reports/report-2026-05-30-WF02-f4-task-inbox-20260530-final.yaml; release approval recorded in docs/status/release-f4-task-inbox-2026-05-30.yaml.
- Key fixes before release: task_id→id field normalisation in API boundary, epoch-microseconds→ISO timestamp conversion, form_schema_json storage and retrieval, operator inbox visibility, useClaimTask wired to assign endpoint.
- Requirements: TK-UI-01..TK-UI-10 (Stage F4) — RELEASED

### Stage F3 — Instance Monitoring (Batch 2)

### IN-UI-09..IN-UI-10 - Token visualization & history scrubber release batch (RELEASED 2026-05-30)
- **IN-UI-09** (SHOULD): Active token visualisation on process graph displays live execution context tokens with distinct visual styling on the canvas, including token state transitions during execution.
- **IN-UI-10** (SHOULD): History scrubber provides timeline-based scrubbing on the event history tab allowing users to seek to any historical snapshot of the running instance with live state rendering.
- Validation evidence passed in tests/reports/report-2026-05-30-WF02-f3b-inui0910-20260530.yaml; release approval is recorded in docs/status/release-F3b-IN-UI-09-10-2026-05-30.yaml.
- Requirements: IN-UI-09, IN-UI-10 (Stage F3) - RELEASED

### Stage F3 — Instance Monitoring (Batch 1)

### IN-UI-05..IN-UI-08 - Instance detail enhancements release batch (RELEASED 2026-05-30)
- **IN-UI-05** (MUST): Event history tab now includes event type and time-range filtering, plus expandable raw JSON payload rendering.
- **IN-UI-06** (MUST): Timeline tab now renders actor avatars with deterministic color mapping and improved human-readable timeline entries.
- **IN-UI-07** (MUST): Cancel instance flow now uses a role-gated confirmation dialog with optional reason capture and optimistic UI update behavior.
- **IN-UI-08** (SHOULD): Auto-refresh support added via shared polling on board and detail pages, with last-refresh visibility and manual refresh support.
- Validation evidence passed in tests/reports/report-2026-05-30-WF02-f3b-inui0508-20260530.yaml; release approval is recorded in docs/status/release-F3b-IN-UI-05-08-2026-05-30.yaml.
- Requirements: IN-UI-05, IN-UI-06, IN-UI-07, IN-UI-08 (Stage F3) - RELEASED

### IN-UI-01..IN-UI-04 - Instance monitoring release batch (RELEASED 2026-05-30)
- **IN-UI-01** (MUST): Instance board — Kanban-style board with columns for Running, Suspended, Completed, and Error instances; cards show instance name, definition name, started-at timestamp, and current status.
- **IN-UI-02** (MUST): Instance filters — Filter bar on the instance board supporting status filter (multi-select), definition filter (dropdown), and date range filter; filters update the board view in real time.
- **IN-UI-03** (MUST): Start instance — Start Instance button on the board opens a modal to select a deployed definition and start a new instance; modal validates required selection before submission.
- **IN-UI-04** (MUST): Instance detail view — Dedicated detail page at `/instances/:id` displaying instance metadata, current state, definition name, started-at, and a status badge; navigable from board cards.
- Validation evidence passed in WF-02 f3a batch 1 E2E tests; release approval is recorded in `docs/status/release-stage-F3-batch1-2026-05-30.json`.
- Requirements: IN-UI-01, IN-UI-02, IN-UI-03, IN-UI-04 (MUST, Stage F3) — RELEASED

### Stage 11 — Test Runner and Simulation Mode

### SIM-01..SIM-04 - Simulation mode release batch (RELEASED 2026-05-29)
- Released Stage 11 simulation capabilities covering isolated simulation tenant routing, deterministic service mocking, deterministic time control, and deterministic UUID generation.
- Release approval is recorded in docs/status/release-Stage11-SIM-01-04-2026-05-29.json after WF-03 release-fix closure and WF-02 post-fix test reruns.
- Validation evidence passed in tests/reports/report-20260529T080704Z-WF02-stage11-sim01-04-20260528-step04-post-wf03-5.json.
- Requirements: SIM-01, SIM-02, SIM-03, SIM-04 (MUST, Stage 11) - RELEASED

### SIM-05..SIM-08 - Scenario execution rerun release batch (RELEASED 2026-05-29)
- Released Stage 11 simulation scenario capabilities covering schema validation, assertion vocabulary coverage, scenario runner execution API behavior, and tenant-aware batch execution behavior.
- Release approval is recorded in docs/status/release-Stage11-SIM-05-08-rerun1-2026-05-29.json after WF-03 release-fix closure and WF-02 deterministic rerun validation.
- Validation evidence passed in tests/reports/report-20260529T122112Z-WF02-stage11-sim05-08-rerun1-20260529-step04.json.
- Requirements: SIM-05, SIM-06, SIM-07, SIM-08 (MUST, Stage 11) - RELEASED

### Stage 2 — Process Definitions (Batch f2c)

### PD-09..PD-10, PD-UI-07..PD-UI-08 — Definition import/export + search + UI (RELEASED 2026-05-29)
- **PD-09** (SHOULD): Definition import/export — Export button downloads self-contained JSON document; Import button accepts JSON file and calls the import endpoint. Backend previously implemented in `src/definition/export_import.zig`.
- **PD-10** (COULD): Full-text search — Backend search endpoint previously implemented in `src/definition/store.zig` with parameterized ILIKE search ranked by relevance.
- **PD-UI-07** (SHOULD): Export/Import buttons — Frontend UI providing Export button on definition detail view and Import button on definition list view, wired to PD-09 backend endpoints.
- **PD-UI-08** (COULD): Debounced full-text search — Search bar on definition list view with 300 ms debounce querying the PD-10 search endpoint, with highlighted results.
- Validation evidence passed in WF-02 f2c batch 2 E2E tests; release approval is recorded in `docs/status/release-stage2-2026-05-29.json`.
- Requirements: PD-09, PD-10, PD-UI-07, PD-UI-08 — RELEASED

### Stage 6 — Observability + Extensions

### Stage 6.5 — Schema adaptations + OIDC foundations

### ADP-01 - Tenant Column on Event Store (RELEASED 2026-05-25)
- Implemented additive tenant-aware event-store persistence and read behavior with default-tenant backward compatibility preserved for legacy flows without explicit tenant context.
- Added migration support for tenant indexing and tenant-scoped filtering in event-store query paths, plus deterministic handling rules for missing tenant context.
- Validation evidence passed in tests/reports/report-20260525T210953Z-WF02-adp01-20260526-step04b.json; release approval is recorded in docs/status/release-ADP-01-20260525.json.
- Requirement: ADP-01 (MUST, Stage 6.5) - RELEASED

### ADP-02 - Tenant column on definition, instance, and audit tables (RELEASED 2026-05-25)
- Implemented additive tenant scoping persistence on definition, instance, and audit data paths, with migration-backed tenant_id columns and index updates to prevent cross-tenant leakage.
- Added deterministic default-tenant behavior for legacy flows with missing tenant context while preserving tenant-scoped read/write invariants across updated backend stores.
- Validation evidence passed in tests/reports/report-20260525T215115Z-WF02-adp02-20260526-step04.json; release approval is recorded in docs/status/release-ADP-02-20260525.json.
- Requirement: ADP-02 (MUST, Stage 6.5) - RELEASED

### ADP-03 - Tenant context resolution on API (RELEASED 2026-05-26)
- Implemented deterministic tenant context resolution for bearer tokens so requests without tenant_id resolve to default tenant and requests with tenant_id remain scoped to the claimed tenant.
- Added ADP-03 integration coverage for tenant-scoped reads/writes, cross-tenant rejection, malformed tenant claim rejection, and default-tenant compatibility behavior.
- Validation evidence passed in tests/reports/report-20260526T022434Z-WF02-adp03-20260526-step04.json; release approval is recorded in docs/status/release-ADP-03-20260526.json.
- Requirement: ADP-03 (MUST, Stage 6.5) - RELEASED

### ADP-04 - Tenant binding for users (RELEASED 2026-05-26)
- Implemented additive tenant binding for identity users and aligned identity/group service paths to explicit tenant-aware behavior, including default-tenant compatibility for pre-existing users.
- Enforced single-tenant membership and claim invariants in identity/group operations to prevent cross-tenant leakage.
- Validation evidence passed in tests/reports/report-20260526T032153Z-WF02-adp04-20260526-step-04b-rework1.json; release approval is recorded in docs/status/release-ADP-04-20260526.json.
- Requirement: ADP-04 (MUST, Stage 6.5) - RELEASED

### ADP-04a - External identity linkage for users (RELEASED 2026-05-26)
- Implemented additive user identity-linkage support for external authentication by introducing external realm/sub fields with compatibility-preserving internal-user defaults.
- Enforced tenant-scoped uniqueness and lookup semantics for realm+sub identity resolution used by OIDC JIT provisioning while preserving legacy internal-user behavior.
- Validation evidence passed in tests/reports/WF02-adp04a-20260526-step-04-test-runner.md and tests/reports/WF02-adp04a-20260526-step-04c-test-runner-rework2.log; release approval is recorded in docs/status/release-ADP-04a-20260526.json.
- Requirement: ADP-04a (MUST, Stage 6.5) - RELEASED

### ADP-04b - Tenant realm binding for OIDC foundations (RELEASED 2026-05-26)
- Implemented and validated default-tenant realm binding behavior for OIDC foundations, including strict rejection of non-bpm-default realm assignment for the default tenant.
- Added explicit executable coverage for default-tenant realm mismatch rejection and omitted-realm normalization to bpm-default, then revalidated through the ADP-04b rework test run.
- Validation evidence passed in tests/reports/report-20260526T055349Z-WF02-adp04b-20260526-step04b-rework1.json; release approval is recorded in docs/status/release-ADP-04b-20260526.json.
- Requirement: ADP-04b (MUST, Stage 6.5) - RELEASED

### ADP-05 - Artifact hash reference on instance (RELEASED 2026-05-26)
- Implemented additive nullable instance artifact-hash persistence support, including deterministic hash population for repository-backed starts while preserving NULL compatibility for legacy and pre-repository paths.
- Implemented and validated artifact-hash-first reconstruction source selection with explicit snapshot fallback for absent or mismatched hashes, preserving PD-08 compatibility semantics.
- Validation evidence passed in tests/reports/report-20260526T070227Z-WF02-adp05-20260526-step04b.json; release approval is recorded in docs/status/release-ADP-05-20260526.json.
- Requirement: ADP-05 (MUST, Stage 6.5) - RELEASED

### ADP-06 - Pipeline run correlation on audit and events (RELEASED 2026-05-26)
- Implemented additive pipeline-run correlation persistence on audit and event records, preserving backward compatibility while enabling deterministic cross-artifact traceability for pipeline execution analysis.
- Added and validated ADP-06 end-to-end evidence through WF-02 rework completion, including test-runner revalidation after WF-03 issue-fix handoff closure.
- Validation evidence passed in tests/reports/report-20260526T085420Z-WF02-adp06-20260526-step04b.json; release approval is recorded in docs/status/release-ADP-06-20260526.json.
- Requirement: ADP-06 (SHOULD, Stage 6.5) - RELEASED

### ADP-07 - Agent role and reserved usernames (RELEASED 2026-05-26)
- Implemented additive identity-role support by introducing AGENT_RUNNER as a grantable role in token and authorization paths while preserving existing role behavior.
- Enforced reserved username policy for the agent: prefix so non-PLATFORM_ADMIN actors are rejected and PLATFORM_ADMIN creation paths remain explicitly allowed.
- Validation evidence passed in tests/reports/report-20260526T103148Z-WF02-adp07-20260526-step04.json; release approval is recorded in docs/status/release-ADP-07-20260526.json.
- Requirement: ADP-07 (MUST, Stage 6.5) - RELEASED

### ADP-08 - Service task catalog reference (RELEASED 2026-05-26)
- Implemented additive SERVICE_TASK configuration support for catalog-based service routing via `service_id`, while preserving legacy inline `url` behavior for backward compatibility.
- Enforced `service:call:<service_id>` capability checks and deterministic precedence behavior where `service_id` overrides `url`, including error-path handling for missing or inactive catalog entries.
- Validation evidence passed in tests/reports/report-20260526T114455Z-WF02-adp08-20260526-step04.json; release approval is recorded in docs/status/release-ADP-08-20260526.json.
- Requirement: ADP-08 (MUST, Stage 6.5) - RELEASED

### ADP-09 - Tamper-evident audit chain (RELEASED 2026-05-26)
- Implemented additive tamper-evident audit chaining with nullable `chain_hash` and `prev_chain_hash` persistence, deterministic canonical SHA-256 chain computation, and tenant-scoped predecessor linkage semantics.
- Added chain-validation behavior that detects tampered rows and propagates validation failure forward from the modified row, while preserving compatibility for historical rows with null chain fields.
- Validation evidence passed in tests/reports/report-20260526T132149Z-WF02-adp09-20260526-step04b-rework1.json; release approval is recorded in docs/status/release-ADP-09-20260526.json.
- Requirement: ADP-09 (MUST, Stage 6.5) - RELEASED

### ADP-10 - Agent IO capture audit (RELEASED 2026-05-26)
- Implemented additive nullable `payload_full` audit field for capturing agent invocation IO payloads, including deterministic JSON object-shape validation and per-agent row filtering semantics.
- Added agent-invocation detection logic to distinguish agent-initiated actions from user/platform-initiated actions, ensuring non-agent rows preserve NULL payload_full behavior.
- Implemented and validated ADP-10 integration coverage across new `tests/integration/adp10_agent_io_capture_audit_test.zig` with explicit unit/integration exit-code markers and focused filter runs.
- Validation evidence passed in tests/reports/report-20260526T151827Z-WF02-adp10-20260526-step04.json; release approval is recorded in docs/status/release-ADP-10-20260526.json.
- Requirement: ADP-10 (MUST, Stage 6.5) - RELEASED

### ADP-11 - Replay-safe retention policy (RELEASED 2026-05-26)
- Implemented additive replay-safe retention guardrails for protected event families `{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}` with deterministic hard-delete rejection and explicit structured error semantics for policy upsert validation.
- Preserved ES-07 hard-delete configurability and behavior for non-protected families while enforcing archive/queryability invariants required for deterministic replay compatibility with IR-07 and XC-05.
- Validation evidence passed in tests/reports/report-2026-05-26-wf02-adp11-step04.json and tests/reports/WF02-adp11-20260526-step-05-release-validator-bench.log; release approval is recorded in docs/status/release-ADP-11-20260526.json.
- Requirement: ADP-11 (MUST, Stage 6.5) - RELEASED

### ADP-12 - Default-tenant regression suite (RELEASED 2026-05-26)
- Implemented automated default-tenant pre/post migration regression validation across Stage 1-6 API and workflow behaviors, with deterministic canonicalization and pairwise comparison coverage.
- Reworked test execution after WF-03 blocker fix and validated zero-diff outcomes across all paired cases in the ADP-12 regression summary artifact.
- Validation evidence passed in tests/reports/report-20260526T183724Z-WF02-adp12-20260526-step04b-rework1.json; release approval is recorded in docs/status/release-ADP-12-20260526.json.
- Requirement: ADP-12 (MUST, Stage 6.5) - RELEASED

### OIDC-01 - Pluggable provider interface (RELEASED 2026-05-26)
- Implemented a provider-agnostic IdentityProvider boundary for authentication so non-adapter auth paths depend on interface contracts instead of provider-specific APIs.
- Added provider manager/adapters and auth middleware integration coverage validating successful and failed provider verification behavior through interface-based call paths.
- Validation evidence passed in tests/reports/report-20260527-wf02-oidc01-step-04.json; release approval is recorded in docs/status/release-OIDC-01-20260526.json.
- Requirement: OIDC-01 (MUST, Stage 6.5) - RELEASED

### Stage 7 — Expression DSL

### DSL-04 - Supported types (RELEASED 2026-05-27)
- **DSL-04**: Supported types — defined the six-value tagged union `Value` type (null, bool, int64, float64, string, timestamp) in `src/expr/ast.zig` with `TypeTag` enum and `typeOf()` helper.
- Added literal parsing for all supported types: `null` keyword, `true`/`false` booleans, integer and float digit sequences, and `"..."` string literals.
- Timestamp values are produced via built-in functions rather than direct literals.
- Unsupported type-like tokens produce structured parse errors with position and description.
- `evaluate()` now handles all literal node types returning correctly typed `Value` variants; round-trip (parse → evaluate → same Value) verified for every type.
- Validation evidence passed in tests/reports/report-2026-05-27T07-25-18Z-WF02-dsl04-step04.json; release approval is recorded in docs/status/release-DSL-04-2026-05-27.json.
- Requirement: DSL-04 (MUST, Stage 7) - RELEASED

### DSL-05 - Type coercion (RELEASED 2026-05-27)
- **DSL-05**: Type coercion — implemented the 6×6 type coercion matrix for the Expression DSL evaluator: arithmetic operators (add_expr, mul_expr, unary_neg) with automatic int64↔float64 promotion (int64 promoted to float64 when mixed) and structured EvalError for non-numeric types in arithmetic.
- Comparison operators (cmp_expr) with no silent cross-type coercion: same-type direct comparison; int64 vs float64 returns explicit EvalError; other mixed-type comparisons return EvalError.
- Three-valued Kleene K3 logic for null in comparisons (null == non-null → null) and boolean operators (null AND/OR/NOT) with deterministic truth tables.
- Null propagation in dot-path resolution — field access on null returns null, not an error.
- No automatic string coercion — string↔other-type conversion requires explicit built-in functions.
- All 78 DSL-05 type coercion unit tests pass; 124 total unit tests pass with zero regressions across DSL-01 through DSL-04.
- Validation evidence passed in tests/reports/report-2026-05-27T08-13-30Z-WF02-dsl05-step04.json; release approval is recorded in docs/status/release-DSL-05-20260527.json.
- Requirement: DSL-05 (MUST, Stage 7) - RELEASED

### DSL-03 - Error recovery (RELEASED 2026-05-27)
- **DSL-03**: Error recovery — parser now reports all errors in a single pass, with synchronize points added after each grammar production to continue parsing past errors.
- Added three gap fixes: dot-path missing synchronize (Gap A), parsePrimary synchronize too aggressive (Gap B), consumeArgList missing synchronize after missing ')' (Gap C).
- Validation evidence passed in tests/reports/report-2026-05-27T06-47-01Z-WF02-dsl03-step04.json; release approval is recorded in docs/status/release-DSL-03-20260527.json.
- Requirement: DSL-03 (SHOULD, Stage 7) - RELEASED

### DSL-02 - AST stability (RELEASED 2026-05-27)
- **DSL-02**: AST stability — `nodeEql` function added to `src/expr/ast.zig`; deterministic AST equality verified for all 14 Node variants.
- Validation evidence passed in tests/reports/report-2026-05-27T05-26-58Z-WF02-dsl02-step04.json; release approval is recorded in docs/status/release-DSL-02-20260527.json.
- Requirement: DSL-02 (MUST, Stage 7) - RELEASED

### DSL-01 - Grammar conformance (RELEASED 2026-05-26)
- Implemented the Tier 1 Expression DSL as a new `src/expr/` module comprising a hand-written recursive descent parser with zero external dependencies; grammar covers 9 productions (or_expr, and_expr, not_expr, cmp_expr, add_expr, mul_expr, unary, primary, func_call) with all 11 built-in functions (length, lower, upper, trim, contains, startsWith, endsWith, coalesce, now, date_add, date_diff) whitelisted at lex time.
- Module includes lexer.zig (single-pass token scan), parser.zig (recursive descent, producing a tagged-union AST), ast.zig (Node union, Value type, CmpOp/AddOp/MulOp enums, Context), error.zig (ParseError struct with line, column, token, message), and mod.zig (public parse() API).
- All parser rejection messages include the line number, column number, and offending token; evaluate() is a stub returning error.NotImplemented pending DSL-04/06 wiring.
- Validation evidence passed in tests/reports/report-20260526T213627Z-WF02-dsl01-step04.json (56/56 test cases PASS); release approval is recorded in docs/status/release-DSL-01-20260526.json.
- Requirement: DSL-01 (MUST, Stage 7) - RELEASED

### OIDC-02 - Keycloak adapter (RELEASED 2026-05-26)
- Implemented a concrete Keycloak 26.x adapter under `src/identity/provider/adapters/keycloak/` that satisfies the OIDC-01 IdentityProvider contract while keeping Keycloak-specific URLs, payloads, and behavior adapter-local.
- Preserved compile isolation by keeping Keycloak references confined to adapter modules and adapter-local tests, so removing the adapter does not affect non-adapter compilation paths.
- Validation evidence passed in tests/reports/report-20260527-wf02-oidc02-step-04.json; release approval is recorded in docs/status/release-OIDC-02-20260526.json.
- Requirement: OIDC-02 (MUST, Stage 6.5) - RELEASED

### OIDC-03 - Configuration source (RELEASED 2026-05-26)
- Implemented startup identity-provider configuration loading and validation for required OIDC provider fields (`provider_type`, `base_url`, `admin_credentials_ref`, `default_realm`) with clear field-attributed startup errors for misconfiguration.
- Wired provider bootstrap selection by configured provider type while preserving provider-agnostic boundaries outside adapter modules.
- Validation evidence passed in tests/reports/report-20260527-wf02-oidc03-step-04.json; release approval is recorded in docs/status/release-OIDC-03-20260526.json.
- Requirement: OIDC-03 (MUST, Stage 6.5) - RELEASED

### OIDC-04 - Standards-compliance boundary (RELEASED 2026-05-27)
- Implemented standards-only OIDC verification boundaries so authentication paths rely on discovery metadata, JWKS signature verification, and required standard claims (`iss`, `sub`, `aud`, `exp`, `nbf`, `iat`) without requiring provider-specific extension claims.
- Added OIDC-04 acceptance coverage for standards-only positive verification plus deterministic negative cases for invalid claims, invalid signature material, and discovery/JWKS boundary failures.
- Validation evidence passed in tests/reports/report-20260527-wf02-oidc04-step-04.json; release approval is recorded in docs/status/release-OIDC-04-20260527.json.
- Requirement: OIDC-04 (MUST, Stage 6.5) - RELEASED

### OIDC-05 - Bearer token acceptance (RELEASED 2026-05-27)
- Implemented deterministic bearer token type classification in auth middleware so OIDC JWT-shaped tokens and legacy opaque internal tokens follow explicit verification paths without ambiguous fallback behavior.
- Added validation coverage for malformed JWT-like token rejection (`token_type_indeterminate`) and route-gate assertions confirming opaque internal tokens never invoke external OIDC verification.
- Validation evidence passed in tests/reports/report-20260527-wf02-oidc05-step-04.json; release approval is recorded in docs/status/release-OIDC-05-20260527.json.
- Requirement: OIDC-05 (MUST, Stage 6.5) - RELEASED

### OBS-01 — Structured logging (RELEASED 2026-05-24)
- Implemented a shared single-line JSON logger in `src/obs/logger.zig` and integrated runtime wiring across `src/config.zig` and `src/main.zig`
- Added request and background logging behavior in `src/api/routes/health.zig` and `src/scheduler/scheduler.zig` with trace-aware field emission and sensitive-value redaction to `[REDACTED]`
- Enforced strict `BPM_LOG_LEVEL` parsing so invalid values fail startup validation instead of silently falling back
- Test evidence is recorded in `tests/reports/report-20260524T145355Z-WF02-obs01-20260524-rework1.json` (WF-02 Step 04b PASS)
- Release approval is recorded in `docs/status/release-OBS-01-20260524.json` with NFR benchmark gate passing
- Requirement: OBS-01 (MUST, Stage 6) — RELEASED

### OBS-02 — Prometheus metrics (RELEASED 2026-05-24)
- Implemented Prometheus exposition and metric aggregation via `src/obs/metrics.zig` and `src/api/routes/metrics.zig`, including active instances, task completions, event append latency histogram, DB query latency histogram with `query_type`, and HTTP request/error counters
- Wired instrumentation in `src/db/pool.zig`, `src/event_store/store.zig`, and `src/engine/instance.zig` to capture runtime metric updates without introducing blocking behavior in request handling
- Test evidence is recorded in `tests/reports/report-2026-05-24-WF02-obs02-step04c-rework2.json` and `tests/reports/WF02-obs02-20260524-step04c-integration-obs02.log` (WF-02 Step 04c PASS)
- Release approval is recorded in `docs/status/release-OBS-02-20260524.json` after benchmark gate revalidation in WF-02 Step 05c
- Requirement: OBS-02 (MUST, Stage 6) — RELEASED

### OBS-04 — Instance timeline view (RELEASED 2026-05-25)
- Implemented timeline retrieval contract for `GET /instances/:id/timeline` with deterministic ascending ordering, API-06 cursor pagination, and any-authenticated-role access enforcement across backend route and service layers
- Added timeline shaping to include required OBS-04 fields (`event_type`, `timestamp`, `actor_display_name`, `description`, plus context fields), including actor fallback behavior for automated and token-originated actions
- Ensured timeline composition includes archived events and complete cancellation history (including `INSTANCE_CANCELLED`) for cancelled instances
- Validation evidence passed in `tests/reports/report-20260525T034702Z-WF02-obs04-step04d-rework3.json`; release gate approval is recorded in `docs/status/release-OBS-04-20260525.json`
- Requirement: OBS-04 (MUST, Stage 6) — RELEASED

### OBS-05 — Dead letter queue (RELEASED 2026-05-25)
- Implemented durable dead-letter queue processing with configurable retry lifecycle and operator actions, including retention of failure context for investigation and replay workflows
- Delivered authenticated DLQ listing and action handling for retry/discard operations with deterministic behavior validated by the OBS-05 integration suite
- Preserved OBS-03 transactional audit semantics for discard actions so audit persistence and DLQ state transitions remain atomic on failure paths
- Validation evidence passed in `tests/reports/report-20260525-wf02-obs05-step-04-test-runner.json`; release gate approval is recorded in `docs/status/release-OBS-05-20260525.json`
- Requirement: OBS-05 (MUST, Stage 6) — RELEASED


### OBS-06 - Alerting hooks (RELEASED 2026-05-25)
- Implemented configurable alerting hooks for observability signals, including threshold-based trigger conditions and extension-friendly notification dispatch integration.
- Release approval is recorded in docs/status/release-OBS-06-20260525.json with NFR benchmark gate passing.
- Test evidence is recorded in tests/reports/report-20260525-wf02-obs06-step-04c-test-runner-rework2.json (WF-02 Step 04c PASS).
- Requirement: OBS-06 (SHOULD, Stage 6) - RELEASED

### EXT-01 - Service task node type (RELEASED 2026-05-25)
- Implemented SERVICE_TASK execution flow to invoke external HTTP endpoints with mapped input/output variables and deterministic payload merge back into instance state.
- Added retry/backoff and failure handling behavior that routes exhausted attempts into the WF-02 observability/error path while preserving run-level traceability.
- Validation evidence passed in tests/reports/report-20260525-wf02-ext01-step-04d-test-runner-rework3.json; release gate approval is recorded in docs/status/release-EXT-01-20260525.json.
- Requirement: EXT-01 (MUST, Stage 6) - RELEASED

### EXT-03 - Plugin interface (RELEASED 2026-05-25)
- Implemented a stable startup-only plugin registration surface for custom node handlers, including post-bootstrap registry freeze enforcement.
- Added plugin execution integration with explicit plugin-over-built-in precedence, COMPLETE output variable merge semantics, and ERROR routing through existing EE-10 handling.
- Added panic-safe plugin invocation behavior by mapping handler panics into structured ERROR outcomes handled by the execution error path.
- Validation evidence passed in tests/reports/report-20260525T144146Z-WF02-ext03-20260525.json; release gate approval is recorded in docs/status/release-EXT-03-20260525.json.
- Requirement: EXT-03 (SHOULD, Stage 6) - RELEASED

### EXT-04 - Variable transformer (RELEASED 2026-05-25)
- Implemented optional CEL-based edge transform expressions for traversed edges, with activation-time syntax validation integrated into definition validation and activation paths.
- Added runtime transform evaluation in edge traversal after EE-09 variable merge and before next-node activation, with output constrained to JSON object merge semantics.
- Routed runtime CEL evaluation failures and non-object transform outputs through existing EE-10 error handling behavior.
- Validation evidence passed in tests/reports/report-20260525T152809Z-WF02-ext04-20260525.json; release gate approval is recorded in docs/status/release-EXT-04-20260525.json.
- Requirement: EXT-04 (SHOULD, Stage 6) - RELEASED

### EXT-05 - Sub-process support (RELEASED 2026-05-25)
- Implemented SUB_PROCESS runtime support with parent WAITING semantics, child-start linkage, copy-on-start variable isolation, and merge-on-child-complete behavior aligned to EE-09.
- Added child terminal propagation behavior so child ERROR and external child cancellation transition the parent to ERROR with required parent and child identifiers in emitted events.
- Validation evidence passed in tests/reports/report-20260525T162125Z-WF02-ext05-20260525.json; release gate approval is recorded in docs/status/release-EXT-05-20260525.json.
- Requirement: EXT-05 (SHOULD, Stage 6) - RELEASED

### Stage 5 — Scheduler + Identity

### IDN-04 — API token management (RELEASED 2026-05-24)
- Implemented API token issuance, listing, and revocation flows in `src/identity/service.zig` and `src/api/routes/identity.zig`, including one-time secret return semantics and hash-only token persistence
- Added additive token-management schema support via `migrations/019_idn04_api_token_management.sql` for durable token metadata, expiration tracking, and revocation state
- Extended bearer-token validation in `src/api/middleware/auth.zig` so revoked and expired tokens are rejected while valid token role claims interoperate with Stage 5 authorization behavior
- Test evidence is recorded in `tests/reports/WF02-idn04-20260524-run-01.md` (WF-02 Step 04 PASS)
- Release approval is recorded in `docs/status/release-IDN-04-20260524.json` with NFR benchmark gate passing
- Requirement: IDN-04 (MUST, Stage 5) — RELEASED

### IDN-03 — Role-based access (RELEASED 2026-05-24)
- Implemented centralized Stage 5 authorization policy evaluation in `src/api/authorization.zig` with additive role union semantics and explicit default fallback to PLATFORM_ADMIN-only behavior for unmapped endpoints
- Enforced role checks in task operations and task listing routes via `src/api/routes/tasks.zig`, including permission-denied (403) behavior for unsupported actions and additive-role allow paths for mixed-role principals
- Added TASK_WORKER task-list row filtering in `src/tasks/store.zig` to return only own assignments or authorized group assignments, aligned with IDN-01/IDN-02 identity and membership context
- Test evidence is recorded in `tests/reports/report-2026-05-24-WF02-idn03-step04.json` (WF-02 Step 04 PASS)
- Release approval is recorded in `docs/status/release-IDN-03-20260524.json` with NFR benchmark gate passing
- Requirement: IDN-03 (MUST, Stage 5) — RELEASED

### IDN-02 — Group management (RELEASED 2026-05-24)
- Implemented group registry and membership model in `src/identity/registry.zig` and `src/identity/service.zig`, with identity route handlers in `src/api/routes/identity.zig`
- Added additive schema migration `migrations/018_identity_group_members.sql` for groups and memberships, including constraints/indexes for idempotent membership operations
- Wired GROUP assignee claim authorization in `src/api/routes/tasks.zig` so ACTIVE group members can claim assigned tasks without mutating assignee semantics
- Test evidence is recorded in `tests/reports/report-20260524T064224Z-WF02-idn02-20260524-rework1.json` (WF-02 Step 04b PASS)
- Release approval is recorded in `docs/status/release-IDN-02-20260524.json` with NFR benchmark gate passing
- Requirement: IDN-02 (MUST, Stage 5) — RELEASED

### IDN-01 — User registry (RELEASED 2026-05-24)
- Implemented user-registry backend flows in `src/identity/registry.zig` and `src/identity/service.zig` with admin create-user API wiring in `src/api/routes/identity.zig`
- Added additive persistence migration `migrations/017_identity_user_registry.sql` and auth integration updates in `src/api/middleware/auth.zig` for ACTIVE/INACTIVE enforcement
- DB-backed validation evidence is recorded in `tests/reports/report-2026-05-24T02-59-07Z-WF02-idn01-rework2.json` (WF-02 Step 04c PASS)
- Release approval is recorded in `docs/status/release-IDN-01-20260524.json` with NFR benchmark gate passing on rework
- Requirement: IDN-01 (MUST, Stage 5) — RELEASED

### SCH-07 — Recurring timers (RELEASED 2026-05-24)
- Implemented ISO 8601 repeat support for timers (`R/PT...` and `Rn/PT...`) with recurrence parsing and persistence in `src/scheduler/recurrence.zig`, `src/scheduler/store.zig`, and `src/scheduler/scheduler.zig`
- Scheduler fire flow now performs recurring re-arm in the same transaction as TIMER_FIRED persistence, including bounded completion for finite repeats and continuous re-arm for infinite repeats until instance termination
- Added additive recurrence schema support in `migrations/016_timer_recurrence_fields.sql` and integrated lifecycle interactions with existing cancellation/recovery behavior
- Test evidence recorded in `tests/reports/WF02-sch07-20260524-run-02.md` from `tests/specs/SCH-07.md`; prior compile blockers were resolved and validation commands passed
- Release approval recorded in `docs/status/release-SCH-07-20260524.json` with NFR benchmark gate passing on rework
- Requirement: SCH-07 (SHOULD, Stage 5) — RELEASED

### SCH-06 — Timer jitter (RELEASED 2026-05-23)
- Implemented configurable random jitter (±N ms) on scheduler polling interval to prevent thundering-herd effects in clustered deployments
- Added `BPM_SCHEDULER_JITTER_MS` environment variable (u64, default 0 = disabled) to `SchedulerConfig` in `src/scheduler/scheduler.zig`
- Added thread-local `std.Random.DefaultPrng` seeded from OS entropy (`fillRandom`) to the `Scheduler` struct; independent per node, no shared seed
- Implemented `computePollDelayMs()`: applies random offset in [-jitter_ms, +jitter_ms], clamped so effective delay ≥ 0
- Jitter is applied ONLY to the poll-cycle sleep, never to timer `fire_at` values
- No DB schema changes required; zero new migrations
- Verified: `zig build` (exit 0), `zig build test` (exit 0), 15 SCH-06 test cases PASS
- Requirement: SCH-06 (SHOULD, Stage 5) — RELEASED

### SCH-05 — Missed timer recovery (RELEASED 2026-05-23)
- Implemented missed timer recovery: scheduler detects overdue timers on startup and normal polling and marks them with `fired_late: true` in the TIMER_FIRED event payload
- Added `is_startup_sweep` flag to the scheduler: first poll after init fires all due timers as overdue; subsequent polls use poll-interval threshold-based detection
- Extended TIMER_FIRED payload with `fired_late`, `scheduled_fire_at`, and `actual_fire_at` fields
- All overdue timers are fired exactly once; no timer is skipped
- Implementation confined to `src/scheduler/scheduler.zig` — no schema changes, no new migrations
- Verified: `zig build` (exit 0), `zig build test` (exit 0), 11 unit tests PASS
- Requirement: SCH-05 (MUST, Stage 5) — RELEASED

### SCH-04 — Escalation timer (RELEASED 2026-05-23)
- Implemented durable escalation timers for HUMAN_TASK activation across `src/scheduler/store.zig`, `src/tasks/store.zig`, `src/engine/instance.zig`, and `src/scheduler/scheduler.zig`
- Scheduler firing appends `ESCALATION` only while the task remains `PENDING`, and optional reassignment is committed in the same transaction as event persistence
- Completing a task before the escalation deadline now cancels the pending escalation timer atomically, preserving first-commit-wins race semantics against scheduler fire
- Focused SCH-04 validation is recorded in `tests/reports/WF02-sch04-20260523-run-02.md`; release approval is recorded in `docs/status/release-SCH-04-20260523.json`
- Requirement: SCH-04 (MUST, Stage 5) — RELEASED

### SCH-03 — Timer cancellation (RELEASED 2026-05-23)
- Implemented atomic cancellation of PENDING timers when instances transition to terminal states, with completion/cancellation logic in `src/engine/instance.zig`
- Added integration coverage in `tests/integration/sch02_timer_polling_test.zig` to verify cancelled timers are not fired after terminal state commits
- Release validation approved in `docs/status/release-SCH-03-20260523.json` with NFR and SCH-03 test evidence (`tests/reports/WF02-sch03-20260523-run-01.md`)
- Requirement: SCH-03 (MUST, Stage 5) — RELEASED

### SCH-02 — Timer polling (RELEASED 2026-05-23)
- Implemented scheduler polling for due timers with atomic fire semantics in `src/scheduler/scheduler.zig` and timer persistence support in `src/scheduler/store.zig`
- Verified clustered firing behavior through the approved release path in `docs/status/release-SCH-02-20260523.json`
- SCH-02 integration evidence is recorded in `tests/reports/WF03-sch02-fix-20260523-run-01.md` with the test spec in `tests/specs/SCH-02.md`
- Requirement: SCH-02 (MUST, Stage 5) — RELEASED

### SCH-01 — Durable timer creation (RELEASED 2026-05-23)
- Implemented durable timer creation on timer-node arrival with atomic transition + timer persistence in `src/scheduler/store.zig`, `src/engine/transition.zig`, and `src/engine/instance.zig`
- Added additive timer-status constraint hardening migration in `migrations/015_timers_status_constraint.sql`
- Covered SCH-01 acceptance criteria AC-1..AC-5 in `tests/specs/SCH-01.md`; SCH-01 test report: `tests/reports/WF02-sch01-20260523-test-report.json` (unit/integration PASS)
- Benchmark blocker remediation (ISS-SCH01-RV-002): optimized append throughput benchmark path in `tests/bench/bench.zig`; final release validation passed with NFR-02 append throughput 1517.712 events/sec (target >= 1000), while NFR-01 and NFR-04 remained PASS
- Requirement: SCH-01 (MUST, Stage 5) — RELEASED

### Stage 4 — REST API Layer

### API-12 — Health endpoints (RELEASED 2026-05-23)
- Added public unauthenticated `GET /health/live` and `GET /health/ready` handlers in `src/api/routes/health.zig`
- Implemented readiness evaluation in `src/api/health/readiness.zig` and subsystem result modeling in `src/api/health/subsystems.zig`
- `GET /health/ready` is DB-04 backed and reports `db_latency_ms` when ready; degraded responses return HTTP 503 with structured failing-subsystem details (including pool-exhausted and DB-failure variants)
- Registered health route metadata updates through `src/api/openapi/builder.zig` and `src/api/routes/openapi.zig`
- API route wiring completed via `src/main.zig`
- Verification: `zig build test` passed; targeted API-12 report at `tests/reports/API-12-test-report.md` (11 API-12 checks passed)
- Requirement: API-12 (MUST, Stage 4) — RELEASED

### API-11 — OpenAPI specification (RELEASED 2026-05-23)
- Added public `GET /openapi.json` endpoint in `src/api/routes/openapi.zig` with no auth requirement
- Implemented code-generated OpenAPI 3.1 pipeline (no static hand-maintained spec file) via `src/api/openapi/{model,path_registry,schema_registry,version_source,builder,serialize,mod}.zig`
- Wired route/module integration in `src/api/api_mod.zig` and `src/main.zig`; added `src/tools/openapi_gen.zig` support tooling
- `info.version` is sourced from platform release/build metadata through the version source strategy in the OpenAPI module
- OpenAPI components include shared RFC 9457 problem detail schemas/responses and documented core API paths
- Verification: `zig build test` passed; API-11 report at `tests/reports/API-11-test-report.md` (4 targeted API-11 checks passed)
- Requirement: API-11 (SHOULD, Stage 4) — RELEASED

### API-10 — Rate limiting (RELEASED 2026-05-23)
- Created `src/api/middleware/rate_limit.zig`: per-token sliding-window rate limiter keyed by `AuthContext.token_id`; fixed-bucket algorithm with configurable default limit (1,000 req/min via `BPM_RATE_LIMIT_DEFAULT`, fallback 1,000); per-token override via `BPM_RATE_LIMIT_TOKEN_<id>` env var; Mutex-based thread-safe bucket map; middleware short-circuits with HTTP 429 before route handler is invoked
- Extended `src/api/middleware/auth.zig`: added `token_id` field to `AuthContext` (allocated for both bootstrap and DB-validated tokens); existing auth unit tests updated to free newly-allocated fields
- Extended `src/api/errors.zig`: added `problemRateLimited()` constructor returning RFC 9457 Problem Details with HTTP 429 status and `Retry-After` header (seconds until window resets; clamped to 0 when window has just reset)
- Wired rate limit middleware into middleware chain (`src/main.zig`, `src/api/api_mod.zig`); runs after auth middleware (only authenticated requests counted)
- 9 unit tests pass (9 test cases: TC-API-10-01 through TC-API-10-09, including per-token env-var override and default-fallback assertion); 6 integration tests deferred pending HTTP server entry point; test spec: `tests/specs/API-10.md`; design artefact: `src/design/api-rate-limit.md`
- Requirement: API-10 (SHOULD, Stage 4) — RELEASED

### API-09 — Request tracing (RELEASED 2026-05-23)
- Created `src/api/middleware/trace.zig`: trace middleware runs first in the request chain (before auth); extracts `X-Trace-Id` request header if present (non-UUID values accepted as-is), otherwise generates a new UUID v4 via OS CSPRNG (`fillRandom()`); stores trace ID in thread-local context; injects `X-Trace-Id` into every response header; trace ID assigned and returned even on HTTP 401 auth failure
- Created `src/api/trace_context.zig`: thread-local trace ID storage with `get()`, `set()`, and `clear()` functions; per-request isolation
- Extended `src/api/errors.zig`: added `trace_id` field to `ProblemDetails` struct; `serialise()` includes `trace_id` in all RFC 9457 error response bodies
- Modified `src/obs/logger.zig`: structured logger now reads `trace_context` and injects `trace_id` into every log entry during request processing
- Wired trace middleware and trace context exports into `src/api/api_mod.zig` and `src/main.zig`; trace middleware first in chain before auth
- 10 unit tests pass (`tests/unit/test_api09_tracing.zig`); 6 integration tests deferred pending HTTP server entry point; test spec: `tests/specs/API-09.md`; design artefact: `src/design/api-tracing.md`
- Requirement: API-09 (MUST, Stage 4) — RELEASED

### API-08 — Bearer token auth (RELEASED 2026-05-23)
- Implemented `src/api/middleware/auth.zig`: `Role` enum (PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, API_CLIENT), `AuthContext` struct, `AuthResult` union (`.authenticated`, `.unauthenticated`, `.forbidden`), `init()` (startup validation of `BPM_BOOTSTRAP_TOKEN`), `authenticate()` middleware (extracts Bearer token from Authorization header, validates against bootstrap token with constant-time hash comparison, attaches role to request context), `deinit()`
- Extended `src/api/errors.zig` with `problemUnauthorized()` (HTTP 401 + `WWW-Authenticate: Bearer` header + RFC 9457 Problem Details body) and `problemForbidden()` (HTTP 403 + RFC 9457 body)
- Updated `src/api/api_mod.zig` to export auth middleware
- Bootstrap token: `BPM_BOOTSTRAP_TOKEN` env var accepted as `PLATFORM_ADMIN` in non-production; fatal startup error in production
- Missing Authorization header → HTTP 401 + WWW-Authenticate; malformed header (no Bearer prefix) → HTTP 401; empty bootstrap token → treated as not set (all requests get 401)
- Token validation on every request; no caching beyond request lifetime
- 4 unit tests pass, 5 skip (env-dependent: bootstrap token not configured, production mode not active); test spec `tests/specs/API-08.md` (10 test cases); design artefact `src/design/api-auth.md`
- Requirement: API-08 (MUST, Stage 4) — RELEASED

### API-07 — Input validation (RELEASED 2026-05-23)
- Implemented `src/api/validation.zig`: `ValidationError` type with field path, constraint, and received value; `FieldConstraint` enum (`.required`, `.type_object`, `.type_string`, `.type_number`, `.type_bool`, `.non_empty`, `.min_length`, `.max_length`, `.one_of`, `.min`, `.max`); `Schema(T)` generic type for defining per-field validation rules; `validate()` pure function returning all errors (not just first)
- Implemented `src/api/middleware/validate.zig`: `enforceValidation()` middleware that runs validation before any business logic; returns HTTP 422 with RFC 9457 Problem Details `errors` array on violations; malformed JSON → HTTP 400; empty required strings treated as missing
- RFC 9457 compliance: each error entry includes `field`, `constraint`, `message`, and `received`; all errors collected and reported simultaneously
- Integrated into existing route handlers via middleware composition; validation happens before any database writes
- Memory-leak fix (step-02a): arena allocator from `parseFromValue` properly freed in both `.ok` and `.errors` paths
- 36 unit tests pass, 0 memory leaks; test spec: `tests/specs/API-07.md`; design artefact: `src/design/api-validation.md`
- Requirement: API-07 (MUST, Stage 4) — RELEASED

### API-06 — Shared pagination module (RELEASED 2026-05-22)
- Implemented `src/api/pagination.zig`: centralized cursor-based pagination module shared by all list endpoints
- `Cursor` struct with base64url encode/decode, prefix validation (T:, I:, D:, H:), and 24-hour cursor expiry (HTTP 410 on stale cursor)
- `PageResponse(T)` generic response envelope with optional `cursor` field (absent on last page)
- `validatePageSize(n)`: enforces 1–200 range, default 50
- `buildRawCursor` and `buildRawCursorTimestampKey` helpers for constructing endpoint-specific cursors
- `parseIntFromCursor` and `findNthColon` utility functions
- Refactored 4 endpoints to use shared module: `tasks.zig` (T: prefix), `instances.zig` handleList (I: prefix, three-segment cursor), `instances.zig` handleHistory (H: prefix), `definitions.zig` (D: prefix, 24h expiry)
- Removed duplicated base64url encode/decode helpers from `tasks.zig` and `instances.zig`; replaced `definitions.zig` inline cursor logic
- Updated `api03_handler_test.zig` cursor format tests to match new I: prefix cursors
- Cross-endpoint cursor rejection: a cursor from one endpoint prefix is rejected on another
- 37 unit tests in `tests/unit/test_api06_pagination.zig`; 210 total pass, 0 fail, 102 skip
- Test spec: `tests/specs/API-06.md` (20 test cases); design artefact: `src/design/api-06-pagination.md`
- Requirement: API-06 (MUST, Stage 4) — RELEASED

### API-04 — Task operations HTTP endpoints (RELEASED 2026-05-22)
- Implemented `GET /api/v1/tasks`: paginated list of tasks (cursor-based, API-06 compliant) filterable by `assignee_id`, `status`, and `instance_id` query parameters; TASK_WORKER sees only their own tasks, PROCESS_OPERATOR and above see all tasks
- Implemented `GET /api/v1/tasks/:id`: returns full task record including `status`, `instance_id`, `node_id`, `assignee_type`, `assignee_ref`, `created_at`; HTTP 404 if not found
- Implemented `POST /api/v1/tasks/:id/complete`: delegates to EE-04 completion logic; requires task ownership (HTTP 403 for TASK_WORKER attempting another owner's task); HTTP 409 if already completed or cancelled; body: `{ "output_variables": {...} }`
- Implemented `POST /api/v1/tasks/:id/assign`: assigns an unassigned task to a specified user; body: `{ "user_id": "..." }`; HTTP 409 if task already assigned; requires PROCESS_OPERATOR or above
- Implemented `POST /api/v1/tasks/:id/reassign`: changes assignee of an already-assigned task; HTTP 409 if task is unassigned; requires PROCESS_OPERATOR or above
- Added `TaskStore.listCursor()`, `TaskStore.assign()`, `TaskStore.reassign()` methods with parameterised SQL (no string interpolation)
- All SQL positional parameters bound via pg.zig; SQL injection safe
- EE-04 integration: `POST /tasks/:id/complete` invokes existing `completeTask` logic directly
- Unit tests in `tests/unit/test_tasks_api.zig`; test spec `tests/specs/API-04.md` (57 test cases); design artefact `src/design/api-04-task-operations.md`
- Requirement: API-04 (MUST, Stage 4) — RELEASED

### API-05 — History endpoint (RELEASED 2026-05-22)
- Implemented `GET /api/v1/instances/:id/history`: returns the full ordered event log for an instance in ascending sequence order; HTTP 404 if instance not found
- Optional query parameters: `event_type` (filter by specific event type), `from`/`to` (ISO 8601 timestamps, inclusive); `from > to` → HTTP 422; unknown `event_type` → HTTP 422
- Cursor-based pagination per API-06: base64url `H:` prefix cursors with 24-hour expiry (HTTP 410 on stale cursor); default `page_size` 50, max 200
- Archived events (ES-07) included in correct sequence position via UNION ALL across `events` + `events_archive` tables
- Any authenticated role may access instance history
- Added `Store.readHistory()` method in `src/event_store/store.zig` with parameterised SQL (no string interpolation)
- Added `handleHistory` handler in `src/api/routes/instances.zig` with full param parsing and ISO 8601 timestamp validation
- Route registered before generic `/:id` route in `src/main.zig` to avoid path conflict
- All SQL positional parameters bound via pg.zig; SQL injection safe
- 22 unit tests pass in `tests/unit/test_api05_history.zig`; test spec `tests/specs/API-05.md` (19 test cases); design artefact `src/design/api-05-history-endpoint.md`
- Requirement: API-05 (MUST, Stage 4) — RELEASED

### API-03 — Instance management HTTP endpoints (RELEASED 2026-05-22)
- Implemented `GET /api/v1/instances/:id`: returns full instance state (instance_id, status, current_tasks, variables, started_at, completed_at) as JSON; HTTP 404 if not found; HTTP 422 INVALID_INSTANCE_ID for malformed UUID; any authenticated role
- Implemented `GET /api/v1/instances`: paginated list of instances (cursor-based, API-06 compliant) filterable by `status` and `definition_id` query parameters; cursor format: base64url(started_at_us:instance_id_hex:cursor_created_at_us) with 24-hour expiry (HTTP 410 CURSOR_EXPIRED on stale cursor); any authenticated role
- Added `InstanceStore.getById()` and `InstanceStore.listInstances()` methods in `src/engine/instance.zig` with parameterised SQL (no string interpolation)
- All SQL positional parameters bound via pg.zig; SQL injection safe
- 11 unit tests pass (`tests/unit/api03_handler_test.zig`): handler validation coverage for INVALID_INSTANCE_ID, INVALID_STATUS, INVALID_PAGE_SIZE, INVALID_DEFINITION_ID, INVALID_CURSOR, CURSOR_EXPIRED; 12 integration tests in `tests/integration/api03_instance_read_test.zig` pending BPM_TEST_DB_URL
- Design artefact: `src/design/api-03-instance-management.md`; test spec: `tests/specs/API-03.md` (21 test cases)
- Requirement: API-03 (MUST, Stage 4) — RELEASED

### API-02 — Process definition CRUD HTTP endpoints (RELEASED)
- Implemented full CRUD handler layer for process definitions in `src/api/routes/definitions.zig`: `handleCreate` (POST /api/v1/definitions → HTTP 201), `handlePut` (PUT /api/v1/definitions/:id → HTTP 409 if non-DRAFT), `handlePatch` (PATCH /api/v1/definitions/:id → HTTP 409 if non-DRAFT), `handleDelete` (DELETE /api/v1/definitions/:id → HTTP 204 hard-delete DRAFT, HTTP 200 archive ACTIVE/DEPRECATED), `handleActivate` (POST /api/v1/definitions/:id/activate → HTTP 200, HTTP 409 if non-DRAFT, HTTP 422 on graph validation failure), `handleDeprecate`, `handleArchive`
- Extended `src/definition/store.zig` with `Store.update()`, `Store.hardDelete()` methods
- Role guards enforce PROCESS_DESIGNER/PLATFORM_ADMIN for all write operations; any-auth for reads
- All 7 API-02 acceptance criteria traceable to test cases in `tests/specs/API-02.md` (35 test cases)
- 10 unit tests pass (`tests/unit/api02_handler_test.zig`); 22 integration tests ready pending `BPM_TEST_DB_URL`
- Requirement: API-02 (MUST, Stage 4) — RELEASED

### API-01 — REST Conventions (RELEASED)
- Added `src/api/errors.zig`: RFC 9457 Problem Details builder with constructors for all standard HTTP error codes
- Added `src/api/middleware/content_type.zig`: Content-Type enforcement middleware (HTTP 415 on mismatch, HTTP 400 on PUT with no body)
- Added `src/api/response.zig`: HTTP response helpers (ok/created/noContent/problemResponse)
- Foundation for all Stage 4 API endpoints (API-02 through API-12)
- Requirement: API-01 (MUST, Stage 4) — RELEASED

### Stage 3 — Execution Engine

### EE-12 — Concurrent instance safety (RELEASED)
- Row-level locking (`FOR UPDATE NOWAIT`) on the instance row in `src/engine/instance.zig` serialises concurrent operations per instance, ensuring exactly one writer at a time
- Two concurrent task completions on the same instance: first succeeds (HTTP 200), second returns HTTP 409 `CONCURRENT_MODIFICATION`
- 100 concurrent task completions across 100 distinct instances all succeed with zero cross-instance contention
- New error variant `ConcurrentModification` added to `CompleteTaskError` set in `src/api/routes/tasks.zig`
- No schema migration required: existing row-per-instance structure is sufficient for per-row locking
- Requirement: EE-12 (MUST, Stage 3) — RELEASED

- **EE-01**: Start process instance — `POST /api/v1/instances` implemented; validates initial_variables, enforces ACTIVE definition requirement, enforces correlation key uniqueness per definition, stores definition snapshot atomically (PD-08 integration)

- **EE-02**: Pure transition function — Implemented `src/engine/transition.zig` as a pure, deterministic, zero-I/O function: `(DefinitionGraph, InstanceState, TransitionEvent) -> InstanceState`. Covers all node types: START, END, HUMAN_TASK, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY (split + join). 11 unit tests (TC-EE-02-01 through TC-EE-02-11) all passing. No database or network access; fully deterministic and database-free. Requirement: EE-02 (MUST, Stage 3) — RELEASED

- **EE-03**: Task activation — `TaskStore` (`src/tasks/store.zig`) with atomic `createInTx()`; `InstanceStore.applyTransition()` in `src/engine/instance.zig` persists state transitions and task records in a single DB transaction; `GET /tasks` endpoint (`src/api/routes/tasks.zig`) with instance_id/status/assignee_ref filters and pagination. Requirement: EE-03 (MUST, Stage 3) — RELEASED

- **EE-04**: Complete task — `TaskStore.getById()` and `TaskStore.completeInTx()` added to `src/tasks/store.zig`; `InstanceStore.completeTask()` in `src/engine/instance.zig` performs the full complete-task transaction (task status update, variable merge, pure transition, TASK_COMPLETED event, next-node activation) atomically; `POST /tasks/:id/complete` HTTP handler (`src/api/routes/tasks.zig`) with output_variables validation and full error mapping (404/409/422/500/503). `TaskError.AlreadyTerminated` and `CompleteTaskError` error sets added. Requirement: EE-04 (MUST, Stage 3) — RELEASED

### EE-05 — Exclusive gateway (RELEASED)
- Implemented CEL expression evaluator in `vendor/cel/cel.zig` (recursive descent parser; subset: bool/int/string literals, `variables.<key>` access, comparison and boolean operators, parentheses)
- Updated `src/engine/transition.zig` EXCLUSIVE_GATEWAY handler to evaluate edge conditions via `cel.evaluate`; CEL runtime errors treated as `false` per EE-05 AC
- Added TC-EE-05-01 through TC-EE-05-17 unit tests; all pass

### EE-06 — Parallel gateway (split) (RELEASED)
- Added `PendingEvent` / `ParallelSplitPayload` types and `pending_events` field to `InstanceState` in `src/engine/transition.zig`
- Implemented `PARALLEL_GATEWAY` split handler in `processNodeEntry`: removes arriving token, creates N new `Token` entries (one per outgoing edge) with unique branch IDs, appends a `PARALLEL_SPLIT` event recording `source_node_id`, `token_ids`, `target_node_ids`, and `edge_count`, then recursively calls `processNodeEntry` for each new token's target node
- All N tokens created in a single DB transaction (DB-03 compliance: `transition.zig` is a pure function with zero I/O; caller in `engine/instance.zig` holds the transaction)
- Added TC-EE-06-01 through TC-EE-06-05 unit tests; all 183 unit tests pass
- Requirement: EE-06 (MUST, Stage 3) — RELEASED

### EE-08 — Instance cancellation (RELEASED)
- Implemented `cancelInstance` in `src/engine/instance.zig`: full 8-step atomic DB transaction (SELECT FOR UPDATE row lock, cancel all open tasks with ID collection, cancel all pending timers with ID collection, insert structured `INSTANCE_CANCELLED` event, update projection with `current_nodes` cleared and `cancelled_at` set, COMMIT)
- Added `actor_id` parameter and helper functions `extractBranchIds` and `buildCancelPayload`; both `ACTIVE` and `ERROR` instances are cancellable
- Added `POST /instances/:id/cancel` HTTP handler in `src/api/routes/instances.zig`: HTTP 200 on success, HTTP 409 if already terminal (`CANCELLED`/`COMPLETED`/`ERROR`), HTTP 404 if not found
- No open tasks/timers edge case handled correctly: `INSTANCE_CANCELLED` event is still appended
- Concurrency handled by row-level `SELECT FOR UPDATE` lock: first writer wins, second caller receives HTTP 409
- 5 integration test cases (TC-EE-08-01 through TC-EE-08-05) all passing
- Requirement: EE-08 (MUST, Stage 3) — RELEASED

### EE-07 — Parallel gateway (join) (RELEASED)
- Extended `processNodeEntry` in `src/engine/transition.zig` with full join algorithm: when a token arrives at a `PARALLEL_GATEWAY` join node, the arriving token's `branch_id` is recorded; the engine computes `expected_count = total_branches - cancelled_branches` and waits until all active branches arrive before firing
- Added `cancelled_branch_ids` field (with default) to `InstanceState`; join tracking uses existing `active_tokens` map combined with arrived-branch accounting — no auxiliary DB table required
- Added `ParallelJoinPayload` and `InstanceCancelledPayload` structs; extended `PendingEvent` union with `parallel_join` and `instance_cancelled` variants
- Join fires exactly once: the join-fire path runs inside the single DB transaction opened by the caller (`engine/instance.zig`) — DB-03 row-level locking guarantees no double-fire under concurrent token arrivals; `transition.zig` remains a pure, zero-I/O function
- Cancelled-branch exclusion: branches cancelled via EE-08 are excluded from the join threshold (`expected_count` decrements for each cancelled branch); a `PARALLEL_JOIN` event records `branch_ids_arrived`, `branch_ids_cancelled`, and `outgoing_token_id`
- All-branches-cancelled edge case: when all parallel branches are cancelled before any reaches the join, the join node itself is cancelled and the instance transitions to `CANCELLED` status; an `INSTANCE_CANCELLED` event is appended in lieu of `PARALLEL_JOIN`
- Added TC-EE-07-01 through TC-EE-07-04 unit tests in `src/engine/transition.zig`; TC-EE-07-05 (3-branch N=3 join) in `tests/unit/test_ee07_parallel_join.zig`; all 188 unit tests pass
- Requirement: EE-07 (MUST, Stage 3) — RELEASED

### EE-11 — State reconstruction (RELEASED)
- Implemented `reconstructInstance` in `src/engine/reconstruction.zig`: queries the `events` table and `events_archive` table for all events for an instance ordered by `sequence_number ASC`, merges the two ordered streams via UNION ALL (with graceful fallback if `events_archive` is empty), and replays each event through the pure `applyEvent` / `transition()` function starting from the initial state (token on START node, empty variable map, ACTIVE status, empty task set)
- EXECUTION_ERROR events during replay set `status = ERROR` on the reconstructed state; replay continues through the full event log without halting mid-stream
- Optional write-back: when called with `write_back=true`, the reconstructed `InstanceState` is atomically persisted back to `instance_projections` using `FOR UPDATE NOWAIT` (same lock discipline as normal projection updates)
- Added `POST /instances/{id}/reconstruct` HTTP endpoint in `src/api/routes/instances.zig`: returns HTTP 200 with reconstructed `InstanceState` JSON; HTTP 404 if the instance has no events; HTTP 409 on lock contention; requires operator-level authorization
- NFR-04 compliant: `applyEvent` is O(1) per event and the replay loop performs no DB writes; only one optional write-back occurs after the full replay, achieving ≤5 seconds for 10,000-event instances
- Spans both `events` and `events_archive` tables: reconstruction from a post-archival log produces identical results to pre-archival reconstruction
- 3 unit tests (TC-EE-11-U01 through TC-EE-11-U03) and 9 integration test cases (TC-EE-11-01 through TC-EE-11-09) all passing
- Requirement: EE-11 (MUST, Stage 3) — RELEASED

### EE-10 — Execution error handling (RELEASED)
- Implemented `setInstanceError` in `src/engine/instance.zig` as the unified ERROR entry-point: atomically inserts an `EXECUTION_ERROR` event into the event store and updates `instance_projections.status = ERROR` with `error_detail` JSONB in a single `SELECT FOR UPDATE` transaction
- Added `ErrorType` enum (`NO_MATCHING_EDGE`, `SCHEMA_VIOLATION`), `EvaluatedCondition` struct (for gateway condition traces), and `SetInstanceErrorArgs` struct carrying `error_type`, `affected_node`/`affected_field`, `reason`, `variable_state`, and `evaluated_conditions`
- Added `HTTP 409` guard in `completeTask`: immediately after `SELECT FOR UPDATE`, checks `instance.status = ERROR` and returns `CompleteTaskError.InstanceInError` → HTTP 409 before any write
- Concurrent ERROR race protection: `SELECT FOR UPDATE` row lock ensures exactly one `EXECUTION_ERROR` event is appended even when two operations race to set the same instance to ERROR; the second caller sees `status = ERROR` from the lock and returns HTTP 409
- Refactored EE-05 (gateway no-match) and EE-09 (schema-violation) paths to call `setInstanceError` as the single ERROR entry-point
- 12 unit tests (TC-EE-10-unit-01 through TC-EE-10-unit-12) all passing: error set variants, struct layouts, error mapping function (5 paths), `InstanceInError` variant
- Integration tests TC-EE-10-01 through TC-EE-10-06 compile and skip pending `BPM_TEST_DB_URL` (deferred to WF-04, consistent with EE-04, EE-07, EE-08, EE-09 precedent)
- Requirement: EE-10 (MUST, Stage 3) — RELEASED

### EE-09 — Variable scoping and merge (RELEASED)
- Implemented `mergeVariables` in `src/engine/instance.zig`: applies task `output_variables` to the instance variables map using a three-path collision policy — (1) new key: inserted directly; (2) existing key with no schema constraint or schema-valid value: variable overwritten and a `VARIABLE_OVERWRITTEN` event appended; (3) schema violation: merge aborted, `ERROR` status set on the instance, and an `EXECUTION_ERROR` event appended
- New `src/engine/json_schema.zig` validator: validates variable values against JSON Schema constraints (type, enum, minimum, maximum, maxLength); returns structured `SchemaViolation` errors used by the merge collision policy
- `MergeVariablesError` error set covers `SchemaViolation`, `PersistenceFailed`, and `OutOfMemory`; empty `output_variables` map is a no-op (no DB writes, no events)
- `VARIABLE_OVERWRITTEN` event recorded per overwritten key; `EXECUTION_ERROR` event records the violating key, expected schema, and actual value
- 10 unit tests (TC-EE-09-U01 through TC-EE-09-U10) all passing; 5 integration tests (TC-EE-09-01 through TC-EE-09-05) compile cleanly and are deferred to WF-04 (require live PostgreSQL)
- Requirement: EE-09 (MUST, Stage 3) — RELEASED

### Added — PD-04 Definition lifecycle (2026-05-22)
- New `Store.deprecate()` method in `src/definition/store.zig`: transitions a definition from `ACTIVE` to `DEPRECATED`; returns `DefinitionError.InvalidTransition` (HTTP 409) if the definition is not currently `ACTIVE`.
- New `Store.archive()` method in `src/definition/store.zig`: transitions a definition from `DEPRECATED` to `ARCHIVED`, recording `archived_at` timestamp; returns `DefinitionError.InvalidTransition` (HTTP 409) if the definition is not currently `DEPRECATED`.
- `ARCHIVED` is a terminal state — no further lifecycle transitions are permitted; any attempt to transition out of `ARCHIVED` is rejected with HTTP 409 and a descriptive error body.
- New HTTP route `POST /api/v1/definitions/{id}/deprecate`: invokes `Store.deprecate()`; returns HTTP 200 on success, HTTP 404 if definition not found, HTTP 409 on invalid transition.
- New HTTP route `POST /api/v1/definitions/{id}/archive`: invokes `Store.archive()`; returns HTTP 200 on success, HTTP 404 if definition not found, HTTP 409 on invalid transition.
- Full lifecycle state machine enforcement: DRAFT → ACTIVE → DEPRECATED → ARCHIVED; all other transitions rejected with HTTP 409 and a machine-readable error body.
- Requirement: PD-04 (MUST, Stage 2) — RELEASED

### Added — PD-10 Definition search (2026-05-21)
- New `Store.search()` method in `src/definition/store.zig`: parameterized ILIKE search over definition names and descriptions, ranked by relevance (exact name = 3, partial name = 2, description-only = 1).
- New `SearchOptions` struct (query, limit, offset) with inline validation: empty query → HTTP 422 (`QueryEmpty`), query > 512 chars → HTTP 422 (`QueryTooLong`).
- New `SearchResult` struct wrapping `Definition` with a computed `rank: f32` field.
- New `DefinitionError` variants: `QueryEmpty` and `QueryTooLong`.
- New HTTP handler `handleSearch` in `src/api/routes/definitions.zig`: `GET /api/v1/definitions/search?q={query}&limit={n}&offset={n}` with API-06 pagination.
- SQL injection safe: query bound as `$1` (exact) and `$2` (ILIKE `%query%` pattern) via pg parameters — no string interpolation.
- No-match returns HTTP 200 with empty array.
- Requirement: PD-10 (COULD, Stage 2) — RELEASED

### Added — PD-09 Definition import/export (2026-05-21)
- New `src/definition/export_import.zig`: `ExportImportStore` providing `exportDefinition()` and `importDefinition()` for migrating definitions between environments.
- `exportDefinition()` produces a self-contained `ExportDocument` JSON with `bpm_export_schema_version = "bpm/definition/v1"`, all definition fields, and the full graph; works for definitions in any status.
- `importDefinition()` validates schema version, checks name+version uniqueness (HTTP 409 on conflict), re-validates CEL conditions via `validateEdgeConditions()` (HTTP 422 on invalid CEL), then creates the definition with `status = DRAFT`.
- New HTTP handlers `handleExport` and `handleImport` added to `src/api/routes/definitions.zig`.
- `src/bpm.zig` now exports `pub const export_import`.

## [Stage 1] — 2026-05-20

### Added
- DB module: connection pool (src/db/pool.zig), migration runner (src/db/migrations.zig)
- Event Store module: append, read, idempotency, global stream, type registry, point-in-time query, retention/archival (src/event_store/store.zig, src/event_store/registry.zig)
- Migration 013: UNIQUE index on events_archive(idempotency_key)
- Test specs: tests/specs/DB-01-04.md (13 cases), tests/specs/ES-01-08.md (22 cases)
- Test stubs: db_test.zig, event_store_test.zig, db_integration_test.zig, event_store_integration_test.zig

### Verified
- zig build exits 0
- zig build test exits 0 (38 unit stubs SKIP, engine placeholder PASS)
- zig build test-integration exits 0 (10 stubs SKIP — awaiting DB)

### [Stage 1 — Integration Tests Verified] — 2026-05-21
- Real PostgreSQL client integrated (vendor/pg)
- Integration test harness (tests/integration/helpers.zig) implemented
- All Stage 1 MUST integration tests pass against bpm_test DB (17/17 PASS, 5 consecutive stable runs)
- DB-01, DB-03, DB-04, ES-01..ES-08: integration tests confirmed PASS; test_run and tested_at recorded
- DB-02 (connection pooling): coverage gap — no dedicated integration test in current suite; pool exercised implicitly by all 17 tests but pool-size, exhaustion, and validation scenarios untested; follow-up required from TEST-DESIGNER

### [Stage 1 — Released] — 2026-05-21
- All Stage 1 MUST requirements promoted to RELEASED
- DB-01..DB-04: Schema init, connection pooling, transactional integrity, health check
- ES-01..ES-08: Append event, ordered read, idempotency, global stream, type registry,
  point-in-time query, retention policy, event metadata
- Provider errors (pg.zig / pool.zig) confirmed clean under Zig 0.16
- Stage 1 release gate passed (release-stage1-2026-05-21.json)

## [Stage 2] PD-08 — Definition Snapshot (2026-05-21)

- Added `src/definition/snapshot.zig` implementing `SnapshotStore.create()` and `SnapshotStore.getByInstanceId()`
- Added `instance_definition_snapshots` table (migration 004) — snapshots bound to instance_id PRIMARY KEY
- Snapshots are immutable: concurrent definition changes cannot affect running instances (FOR SHARE + ON CONFLICT DO NOTHING)
- Exported as `bpm.snapshot` from `src/bpm.zig`
- 4 unit tests passing (TC-PD-08-06u-01..04); 7 integration tests ready pending BPM_TEST_DB_URL
- Requirement: PD-08 (MUST, Stage 2) — RELEASED

## [Stage 2 — Process Definition] — 2026-05-21

### Released
- PD-01 (Create definition): UUID assignment, DRAFT status, duplicate name+version rejection, optional description
- PD-02 (Graph validation): START/END node checks, dangling edges, isolated nodes, duplicate node IDs, cycle detection with gateway exemption

### Released
- PD-03 (Version management): incremental versioning on definition save, atomic ACTIVE→DEPRECATED transition when a new version is activated, list-by-status returning exactly one ACTIVE version per name, idempotent re-activation guard

### Added
- Definition module: process definition creation and storage (src/definition/store.zig, src/definition/graph.zig)
- Graph validation: 9 distinct error codes covering all structural defects (src/definition/graph.zig)
- Version management: version column, activation/deprecation logic, filtered list queries (src/definition/store.zig)
- Test specs: tests/specs/PD-01-02.md (15 cases: 4 for PD-01, 11 for PD-02), tests/specs/PD-03.md (7 cases)

### Verified
- zig build exits 0
- zig build test exits 0 (12 PASS, 38 SKIP — pre-existing stubs)
- zig build test-integration exits 0 (34/34 PASS: 15 new PD tests + 19 Stage 1 regression tests)
- All Stage 1 regression tests (DB-01..DB-04, ES-01..ES-08) confirmed passing
- Stage 2 release gate passed (release-pd01-2026-05-21.json)

### Released — 2026-05-21
- PD-05 (Node types): NodeType enum updated and extended
  - `USER_TASK` renamed to `HUMAN_TASK`; `SCRIPT_TASK` renamed to `TIMER`
  - Full enum: `START`, `END`, `HUMAN_TASK`, `SERVICE_TASK`, `EXCLUSIVE_GATEWAY`, `PARALLEL_GATEWAY`, `TIMER`
  - New optional `attributes` field on `GraphNode` struct (key/value string map)

### Stage 2 — PD-07 — Definition retrieval (released 2026-05-21)

- Added `Store.getActiveByName()` to retrieve the currently ACTIVE version of a definition by name (`GET /definitions/active/:name`).
- Added `?stage=` filter support to `Store.list()` via new `stage` field in `ListOpts`.
- Added migration `014_definition_stage.sql` to add `stage` column to `process_definitions`.
- Implemented HTTP route handlers in `src/api/routes/definitions.zig`: `handleGetById`, `handleList`, `handleGetActiveByName`.
- API-06 cursor-based pagination implemented in `handleList` using base64url-encoded `created_at` timestamps.
- `?status=` and `?page_size=` validated at HTTP layer before reaching store.

### PD-06 — Edge conditions [RELEASED]
- Added `is_default: bool` field to `GraphEdge` struct
- Added `validateEdgeConditions()` to `graph.zig`: enforces CEL syntax validity and EXCLUSIVE_GATEWAY edge rules (CHK-EC-01 through CHK-EC-06)
- Added `isValidCelSyntax()` pure helper for structural CEL syntax checking
- `validateEdgeConditions()` integrated into `Store.create()` after `validateNodeAttributes()`
- Updated `web/src/types/api.ts` `GraphEdge` interface with `is_default?: boolean`
- 19 unit tests added in `tests/unit/graph_edge_conditions_test.zig`
  - New `validateNodeAttributes()` pure function in `src/definition/graph.zig`
  - Per-type mandatory attribute validation enforced at definition-save time:
    - `HUMAN_TASK`: requires `role` (non-empty string) → HTTP 422 / `HUMAN_TASK_MISSING_ROLE`
    - `SERVICE_TASK`: requires `endpoint` (non-empty string) and `timeout_ms` (integer 1..300000) → HTTP 422
    - `TIMER`: requires `duration_iso8601` (valid ISO 8601 duration; `P0D` accepted) → HTTP 422
  - Attribute violations surface as `GraphValidationFailed` (HTTP 422) alongside structural violations
  - Test spec: `tests/specs/PD-05.md`; test run: `WF02-pd05-20260521-run-01`

### OBS-03 - Audit log (RELEASED 2026-05-25)
- Implemented immutable audit logging for state-changing API operations with persisted actor, action, entity, and request-trace context for compliance and forensic traceability
- Added audit log read access with filterable retrieval for authorized operators, preserving append-only semantics on stored audit records
- Validation evidence passed in `tests/reports/report-20260524T225404Z-WF02-obs03-step04d-rework3.json` and release gate approval is recorded in `docs/status/release-OBS-03-20260524.json`
- Requirement: OBS-03 (MUST, Stage 6) - RELEASED


### SIM-05..SIM-08 - Scenario execution rerun release batch (RELEASED 2026-05-29)
- Released Stage 11 simulation scenario capabilities covering schema validation, assertion vocabulary coverage, scenario runner execution API behavior, and tenant-aware batch execution behavior.
- Release approval is recorded in docs/status/release-Stage11-SIM-05-08-rerun1-2026-05-29.json after WF-03 release-fix closure and WF-02 deterministic rerun validation.
- Validation evidence passed in tests/reports/report-20260529T122112Z-WF02-stage11-sim05-08-rerun1-20260529-step04.json.
- Requirements: SIM-05, SIM-06, SIM-07, SIM-08 (MUST, Stage 11) - RELEASED

