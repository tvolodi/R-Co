# BPM Platform — Extension Adaptations

**Version:** 0.4-draft
**Companion documents:**
- Original Functional Requirements (Stages 1–6) — **shipped, authoritative for existing behaviour**
- `01-architecture.md` v0.4 — extension architecture (Stages 6.5–11 in scope; 12–16 roadmap)
- `02-functional-requirements.md` v0.4 — extension requirements (Stages 6.5–11; Stage 12 deferred)

---

## 1. Purpose

The original Functional Requirements (Stages 1–6) describe code that is **already implemented and running**. This document does not modify them.

This document does three things:

1. States interpretation rules that resolve apparent conflicts between the original requirements and the extension (§3).
2. Defines a small set of **adaptation requirements** (`ADP-*`) that extend shipped subsystems additively, without changing any prior contract (§4).
3. Provides a schema migration outline for the additive columns (§5).

**For implementing agents:** When reading the original requirements, do not modify them. When the extension appears to conflict with an original, consult §3 first — the conflict is usually a scope clarification. When an additive change to a shipped subsystem is genuinely needed, it must appear as an `ADP-*` requirement in §4, never as an edit to the original.

---

## 2. Authority Hierarchy

When two documents disagree, resolution follows this order:

1. **This document (§3 interpretation rules)** — for resolving apparent conflicts
2. **Original Functional Requirements (Stages 1–6)** — for shipped subsystem behaviour
3. **This document (§4 adaptation requirements)** — for additive changes to shipped subsystems
4. **`02-functional-requirements.md` (Stages 7–12)** — for new subsystem behaviour
5. **`01-architecture.md`** — for structural questions not covered by the above

A requirement at a higher level overrides any conflict at a lower level. An adaptation requirement (`ADP-*`) overrides the extension stages where they disagree on how to interface with shipped code.

---

## 3. Interpretation Rules

Each rule resolves a class of apparent conflicts. Rules are normative.

### IR-01 — Tenancy is additive, not retroactive

The original requirements do not mention tenancy. This is **not** a conflict with the extension's multi-tenant model — it is an extension point.

**Interpretation:**
- Existing rows in event store, definition, instance, user, and audit tables are treated as belonging to a reserved **default tenant** with ID `00000000-0000-0000-0000-000000000000`.
- All shipped API endpoints continue to function unchanged for the default tenant. Clients without tenant context implicitly operate against the default tenant.
- New tenant-aware endpoints and behaviour are additive (see ADP-01 through ADP-04).
- Cross-tenant queries are prohibited by construction at the data layer for new tenants; the default tenant is treated as just another tenant in this respect.

**Affected originals:** ES-01, ES-02, ES-04, PD-01, PD-07, EE-01, IDN-01, all `API-*`.

---

### IR-02 — PD-08 snapshot is preserved; artifact hash is added alongside

PD-08 mandates that starting an instance stores a copy of the definition graph. REPO-01/02 introduce content-addressed immutable artifacts.

**Interpretation:**
- PD-08 remains in force. The platform continues to store the full definition JSON at instance start.
- Additionally, the platform records the artifact hash of that definition version on the instance row (ADP-05).
- The snapshot is the safety net; the hash is the audit-trail and deduplication anchor. Both coexist.
- For instances created before the artifact repository existed, the artifact hash field is `NULL`. This is valid.

**Affected originals:** PD-08.

---

### IR-03 — PD-04 governs global lifecycle; tenant activation is a separate concern

PD-04 specifies the lifecycle states `DRAFT → ACTIVE → DEPRECATED → ARCHIVED` and that only one version of a given definition name is ACTIVE at a time.

**Interpretation:**
- PD-04 governs the **global eligibility** of a definition version: a version in state ACTIVE is **eligible to be activated in any tenant**.
- Per-tenant activation (REPO-09) is a separate state, recorded in the tenant activation table.
- A definition can be globally ACTIVE without being activated in any tenant; it can be DEPRECATED globally while still active in some tenants (this is permitted but flagged for review).
- "Only one ACTIVE per name globally" continues to hold.
- "Only one activated version per name per tenant" is a new, parallel constraint introduced by REPO-09.

**Affected originals:** PD-03, PD-04.

---

### IR-04 — EXT-01 inline URL coexists with the service catalog

EXT-01 specifies that a SERVICE_TASK node configuration carries an HTTP endpoint URL. REPO-07 introduces a registered service catalog, and the capability model (Architecture §8) requires `service:call:<service_id>` grants.

**Interpretation:**
- EXT-01 remains in force for SERVICE_TASK nodes that carry inline URLs. These continue to execute as before.
- The node configuration is **extended** to optionally carry a `service_id` referencing the catalog (ADP-08).
- When `service_id` is present, the catalog entry is used and capability check applies.
- When only an inline URL is present, no capability check applies; the call executes per existing behaviour.
- The platform MUST log a warning when an inline-URL service task executes, indicating that catalog registration is preferred.
- The agent pipeline (Stage 12) MUST produce only `service_id`-referenced service tasks. Inline URLs are legacy and not generated by agents.

**Affected originals:** EXT-01.

---

### IR-05 — EXT-03 plugin interface is the deep escape hatch; Wasm is the default

EXT-03 specifies a stable internal interface for registering custom node type handlers at startup. Stage 9 (WASM-*) introduces Wasm-based custom node types.

**Interpretation:**
- EXT-03 remains in force. Compiled-in Zig handlers are the **escape hatch** for cases Wasm cannot serve (raw socket access, hardware interaction, kernel-level operations).
- Wasm modules (Stage 9) are the **default mechanism** for custom node types going forward.
- The agent pipeline MUST NOT produce EXT-03 handlers (they require Zig source linked into the platform binary, which the pipeline cannot do at runtime).
- EXT-03 handlers are added only by human developers, through the normal platform release process.

**Affected originals:** EXT-03.

---

### IR-06 — Agent identities use the existing user/token model

API-08 specifies Bearer token authentication. IDN-01 specifies the user registry. IDN-04 specifies API token management.

**Interpretation:**
- Each AI agent is registered as a user in the IDN-01 registry, with username convention `agent:<role>` (e.g., `agent:architect`, `agent:developer`, `agent:devops`).
- Each agent has a Bearer token issued via IDN-04, scoped to the roles it needs (a new role `AGENT_RUNNER` is introduced, see ADP-07).
- API-08 authentication applies unchanged to agent invocations.
- The audit log records the agent username as `actor_id` for any agent-initiated action.

**Affected originals:** API-08, IDN-01, IDN-03, IDN-04, OBS-03.

---

### IR-07 — Event retention archives remain queryable; replay uses them when needed

ES-07 specifies configurable retention with "archived, not deleted." XC-05 requires deterministic replay from event log.

**Interpretation:**
- ES-07 is unchanged. Archived events remain in the archive store and remain queryable.
- Replay (XC-05) MUST query the archive store transparently when events fall outside the live retention window.
- The platform MUST guarantee that an instance can always be replayed end-to-end as long as its events exist somewhere (live or archive).
- Operators MAY configure permanent retention for specific event types where replay is mandatory; this is recommended for all process-instance events.

**Affected originals:** ES-07.

---

### IR-08 — Audit log is extended, not replaced

OBS-03 specifies that state-changing API actions are recorded with actor, action, resource, timestamp, diff. The extension introduces cryptographic chaining (XC-02) and agent I/O capture (AGT-04).

**Interpretation:**
- OBS-03 remains the **minimum** audit contract.
- Additional fields are added to the audit table (ADP-09): `chain_hash`, `prev_chain_hash`, `pipeline_run_id`, `payload_full` (for agent I/O).
- For audit entries written before the chaining extension, `chain_hash` is `NULL`. Chain validation begins from the first non-null entry forward.
- Existing OBS-03 consumers continue to read the original columns and behave unchanged.

**Affected originals:** OBS-03.

---

### IR-09 — Webhook dispatch and projection coexist with agent monitoring

EXT-02 specifies outbound webhook dispatch on platform events. The extension adds agent-pipeline monitoring (OPS-08) that watches the same events.

**Interpretation:**
- EXT-02 webhooks fire for external consumers (CRM/ERP/HRM applications subscribing to platform events).
- Agent pipeline monitoring (OPS-08) reads events directly from the event stream or projection; it does not subscribe via the webhook mechanism.
- Both can be active simultaneously without interference.
- No change to EXT-02.

**Affected originals:** EXT-02.

---

## 4. Adaptation Requirements

These are **additive** changes to shipped subsystems. None modifies existing behaviour. Each names the original requirement(s) it extends and explicitly states what is preserved.

### Tenancy Additions

**ADP-01 — Tenant Column on Event Store (MUST)**
**Extends:** ES-01, ES-02, ES-04
**Preserves:** All existing event append/read semantics for the default tenant.

The event table MUST gain a `tenant_id UUID NOT NULL` column with default value `00000000-0000-0000-0000-000000000000`. All existing rows are backfilled to the default tenant via the schema migration. All new event appends MUST specify a tenant_id; if absent in the request, the platform MUST infer it from the authenticated token's tenant binding.

*Acceptance:* Existing event queries against the default tenant return the same results as before the migration. A new tenant's events are not visible from default-tenant queries.

---

**ADP-02 — Tenant Column on Definition, Instance, and Audit Tables (MUST)**
**Extends:** PD-01, PD-07, EE-01, OBS-03
**Preserves:** All existing CRUD semantics for the default tenant.

The definition, instance, task, transition, and audit tables MUST each gain a `tenant_id UUID NOT NULL` column with default value `00000000-0000-0000-0000-000000000000`. All existing rows are backfilled.

*Acceptance:* Existing endpoints serving the default tenant return identical results pre- and post-migration.

---

**ADP-03 — Tenant Context Resolution on API (MUST)**
**Extends:** API-08
**Preserves:** Token authentication unchanged; existing tokens continue to work and resolve to the default tenant.

Bearer tokens MUST be extensible with a `tenant_id` claim. Tokens without a `tenant_id` claim MUST resolve to the default tenant. Tokens with a `tenant_id` claim MUST scope all subsequent operations to that tenant. The platform MUST prevent any operation from crossing tenant boundaries within a single request.

After Stage 6.5 implementation, the `tenant_id` claim is populated by the identity provider per OIDC-13 (Keycloak protocol mapper at realm level). Before Stage 6.5, internal tokens may carry the claim via the platform's own token issuance.

*Acceptance:* A token without tenant_id behaves identically to pre-migration. A token with tenant_id can only see its tenant's data.

---

**ADP-04 — User Tenant Binding (MUST)**
**Extends:** IDN-01, IDN-02
**Preserves:** Existing users remain valid; they are bound to the default tenant.

The user table MUST gain `tenant_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'`. A user MAY be a member of exactly one tenant. Cross-tenant users are not supported (the same human being who needs access to two tenants gets two user records).

*Acceptance:* All pre-existing users remain authenticatable and operate against the default tenant.

---

**ADP-04a — External Identity Linkage on User (MUST)**
**Extends:** IDN-01
**Preserves:** Existing internal users continue to function with NULL external linkage.

The user table MUST gain:
- `external_id TEXT NULL` — the OIDC `sub` claim
- `external_realm TEXT NULL` — the realm/issuer identifier
- `auth_source TEXT NOT NULL DEFAULT 'internal'` — values: `internal`, `oidc`

A unique index over `(external_realm, external_id)` enforces one local user per external identity. The defaults preserve existing rows as `auth_source='internal'` with NULL externals.

*Acceptance:* Existing users have `auth_source='internal'` and NULL externals; new OIDC users get `auth_source='oidc'` with populated externals; lookup by `(realm, sub)` is unique.

---

**ADP-04b — Realm Binding on Tenant (MUST)**
**Extends:** ADP-04 (introduces tenant table)
**Preserves:** Existing default tenant row remains valid.

The tenant table MUST gain `idp_realm_id TEXT NULL` for the identity provider realm identifier. The default tenant's value is set to `bpm-default` on migration. Future tenants require this field to be populated at creation time.

*Acceptance:* The default tenant has `idp_realm_id = 'bpm-default'`; new tenants cannot be created without an `idp_realm_id` once OIDC is in use.

---

### Artifact and Pipeline Tracking Additions

**ADP-05 — Artifact Hash Reference on Instance (MUST)**
**Extends:** PD-08, EE-01
**Preserves:** Definition snapshot copy continues to be stored.

The instance table MUST gain a nullable `definition_artifact_hash TEXT` column. When a new instance is started after the artifact repository becomes operational, this field MUST be populated with the hash of the definition version artifact. For instances created earlier, the field is `NULL`, and this is valid.

*Acceptance:* New instances carry the hash; replay can reconstruct from artifact hash when available.

---

**ADP-06 — Pipeline Run Correlation on Audit and Events (SHOULD)**
**Extends:** OBS-03, ES-08
**Preserves:** Existing audit and event semantics.

The audit table SHOULD gain a nullable `pipeline_run_id UUID` column. The event metadata (already free-form per ES-08) SHOULD carry `pipeline_run_id` when an event was caused by a pipeline-driven action. Events not caused by the pipeline have no such metadata, which is valid.

*Acceptance:* All audit/event records produced by pipeline runs are queryable by `pipeline_run_id`.

---

### Identity and Role Additions

**ADP-07 — Agent Role and Reserved Usernames (MUST)**
**Extends:** IDN-01, IDN-03
**Preserves:** Existing roles (`PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`) unchanged.

A new role `AGENT_RUNNER` MUST be added. Usernames prefixed with `agent:` are reserved for AI agent identities. The platform MUST reject creation of `agent:*` usernames except by `PLATFORM_ADMIN`. Agent users MUST be granted `AGENT_RUNNER` plus any additional roles the pipeline policy requires.

*Acceptance:* A regular user cannot register `agent:foo`; admin can. AGENT_RUNNER is a new, granted role.

---

### Service Task Additions

**ADP-08 — Service Task Catalog Reference (MUST)**
**Extends:** EXT-01
**Preserves:** Inline URL service task behaviour unchanged.

The SERVICE_TASK node configuration schema MUST be extended to accept either:
- `url: string` (legacy, behaviour per EXT-01), OR
- `service_id: string` (new, references catalog entry per REPO-07)

When both are present, `service_id` takes precedence and `url` is ignored with a logged warning. When `service_id` is used, the capability check `service:call:<service_id>` applies. When `url` is used (legacy), no capability check applies.

*Acceptance:* Legacy definitions execute unchanged; new definitions use `service_id` and obey the capability model.

---

### Audit Chaining Additions

**ADP-09 — Tamper-Evident Audit Chain (MUST)**
**Extends:** OBS-03
**Preserves:** All existing audit fields and queries.

The audit table MUST gain:
- `chain_hash TEXT NULL` — SHA-256 over the current entry's canonical content plus `prev_chain_hash`
- `prev_chain_hash TEXT NULL` — `chain_hash` of the immediately preceding audit row, per tenant

Existing rows have NULL for both fields. The first new audit row written after migration has `prev_chain_hash = NULL` and `chain_hash` computed over its own content. Subsequent rows chain forward. Chain validation walks the table and verifies each `chain_hash` matches recomputation.

*Acceptance:* Inserting a tampered audit row anywhere after migration breaks chain validation at that row and forward.

---

**ADP-10 — Agent I/O Capture in Audit (MUST)**
**Extends:** OBS-03
**Preserves:** Existing audit fields and queries.

The audit table MUST gain a nullable `payload_full JSONB` column. For agent invocations, this column MUST contain the full input, output, tool calls, and (where compliance permits) raw LLM messages. For non-agent actions, the column is `NULL`.

*Acceptance:* Agent invocations appear in audit with full I/O; non-agent actions are unchanged.

---

### Event Retention Adjustments

**ADP-11 — Replay-Safe Retention Policy (MUST)**
**Extends:** ES-07
**Preserves:** Retention configurability per event type.

Event types belonging to the set `{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}` MUST have either "retain forever" or "archive and remain queryable" retention. Configuring these event types for hard deletion MUST be rejected at configuration time.

*Acceptance:* Attempting to set hard deletion on INSTANCE_STARTED is rejected with a structured error.

---

### Compatibility Verification

**ADP-12 — Default-Tenant Regression Suite (MUST)**
**Extends:** All Stages 1–6
**Preserves:** Confidence that adaptation migrations do not regress shipped behaviour.

Before and after applying the schema migration in §5, the platform MUST pass an automated regression suite exercising every Stage 1–6 endpoint against the default tenant. Diffs in response payloads (status, body, headers excluding new informational fields) MUST be zero.

*Acceptance:* Regression suite passes pre- and post-migration with byte-equal responses for the default tenant.

---

## 5. Schema Migration Outline

This DDL sketch describes the additive migrations implied by §4. It is **non-normative**: column names follow the conventions of the actual shipped schema, which may differ slightly. The implementing agent should adapt names to the existing schema while preserving semantics.

The migration is structured as a single forward-only sequence. All statements are idempotent (`IF NOT EXISTS` where supported) so re-runs are safe.

```sql
-- ============================================================================
-- Migration: extension_adaptations_v1
-- Applies adaptation requirements ADP-01 through ADP-11.
-- All changes are additive. No existing column is dropped or renamed.
-- All existing rows are backfilled to the default tenant.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- ADP-01: Tenant column on event store
-- ----------------------------------------------------------------------------
ALTER TABLE event
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000';

CREATE INDEX IF NOT EXISTS idx_event_tenant_instance
    ON event (tenant_id, instance_id, sequence_no);

-- ----------------------------------------------------------------------------
-- ADP-02: Tenant column on definition, instance, task, transition, audit
-- ----------------------------------------------------------------------------
ALTER TABLE definition
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000';

ALTER TABLE instance
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000';

ALTER TABLE task
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000';

ALTER TABLE transition
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000';

ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000';

CREATE INDEX IF NOT EXISTS idx_definition_tenant_name
    ON definition (tenant_id, name);
CREATE INDEX IF NOT EXISTS idx_instance_tenant_status
    ON instance (tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_task_tenant_assignee_status
    ON task (tenant_id, assignee_id, status);
CREATE INDEX IF NOT EXISTS idx_audit_tenant_time
    ON audit_log (tenant_id, created_at DESC);

-- ----------------------------------------------------------------------------
-- ADP-04: User tenant binding
-- ----------------------------------------------------------------------------
ALTER TABLE app_user
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
        DEFAULT '00000000-0000-0000-0000-000000000000';

-- Reserved tenant record (so foreign keys, if added later, resolve)
CREATE TABLE IF NOT EXISTS tenant (
    id            UUID PRIMARY KEY,
    name          TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'ACTIVE',
    idp_realm_id  TEXT NULL,                 -- ADP-04b: realm at identity provider
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO tenant (id, name, status, idp_realm_id)
VALUES ('00000000-0000-0000-0000-000000000000', 'default', 'ACTIVE', 'bpm-default')
ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- ADP-04a: External identity linkage on user
-- ----------------------------------------------------------------------------
ALTER TABLE app_user
    ADD COLUMN IF NOT EXISTS external_id     TEXT NULL,
    ADD COLUMN IF NOT EXISTS external_realm  TEXT NULL,
    ADD COLUMN IF NOT EXISTS auth_source     TEXT NOT NULL DEFAULT 'internal';

-- Unique constraint: one local user per external identity
CREATE UNIQUE INDEX IF NOT EXISTS uq_app_user_external
    ON app_user (external_realm, external_id)
    WHERE external_id IS NOT NULL;

-- Index for OIDC login lookup
CREATE INDEX IF NOT EXISTS idx_app_user_auth_source
    ON app_user (auth_source);

-- ----------------------------------------------------------------------------
-- ADP-05: Definition artifact hash on instance
-- ----------------------------------------------------------------------------
ALTER TABLE instance
    ADD COLUMN IF NOT EXISTS definition_artifact_hash TEXT NULL;

-- ----------------------------------------------------------------------------
-- ADP-06: Pipeline run correlation on audit
-- ----------------------------------------------------------------------------
ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS pipeline_run_id UUID NULL;

CREATE INDEX IF NOT EXISTS idx_audit_pipeline_run
    ON audit_log (pipeline_run_id)
    WHERE pipeline_run_id IS NOT NULL;

-- Note: pipeline_run_id in event metadata is stored in the existing
-- metadata JSONB column (per ES-08); no schema change needed there.

-- ----------------------------------------------------------------------------
-- ADP-07: Agent role
-- ----------------------------------------------------------------------------
-- If roles are stored in a role table:
INSERT INTO role (name, description)
VALUES ('AGENT_RUNNER', 'Identity used by AI pipeline agents')
ON CONFLICT (name) DO NOTHING;

-- If roles are an enum, add to enum (PostgreSQL):
-- ALTER TYPE role_enum ADD VALUE IF NOT EXISTS 'AGENT_RUNNER';
-- (Cannot be done in a transaction in PG <12; if so, run in a separate non-transactional migration step.)

-- ----------------------------------------------------------------------------
-- ADP-08: Service task catalog reference
-- ----------------------------------------------------------------------------
-- The node configuration is stored in the definition's JSONB graph.
-- No DDL change required; the change is in the validation logic accepting
-- service_id alongside url. Document and enforce at the application layer.
-- A check constraint or trigger MAY be added if desired:
-- (no DDL; see service_catalog table introduced by REPO-07 in extension)

-- ----------------------------------------------------------------------------
-- ADP-09: Tamper-evident audit chain
-- ----------------------------------------------------------------------------
ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS chain_hash TEXT NULL,
    ADD COLUMN IF NOT EXISTS prev_chain_hash TEXT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_chain_lookup
    ON audit_log (tenant_id, created_at)
    WHERE chain_hash IS NOT NULL;

-- ----------------------------------------------------------------------------
-- ADP-10: Agent I/O capture in audit
-- ----------------------------------------------------------------------------
ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS payload_full JSONB NULL;

-- ----------------------------------------------------------------------------
-- ADP-11: Retention policy guard
-- ----------------------------------------------------------------------------
-- Application-layer enforcement; no DDL.
-- If retention is configured in a table, add a CHECK:
-- ALTER TABLE event_retention_policy
--     ADD CONSTRAINT chk_no_hard_delete_critical CHECK (
--         NOT (
--             event_type LIKE 'INSTANCE_%' OR
--             event_type LIKE 'TASK_%' OR
--             event_type LIKE 'GATEWAY_%' OR
--             event_type LIKE 'EXECUTION_%'
--         )
--         OR action != 'HARD_DELETE'
--     );

-- ----------------------------------------------------------------------------
-- Migration record
-- ----------------------------------------------------------------------------
INSERT INTO schema_migration (name, applied_at)
VALUES ('extension_adaptations_v1', now())
ON CONFLICT (name) DO NOTHING;

COMMIT;
```

### Migration Notes

- **Defaults make the migration zero-impact for shipped clients.** Every new column has a default value or is nullable. Existing INSERTs that don't mention the new columns continue to work.
- **No DROP, no RENAME, no type change.** This is forward-compatible only. Rollback is by `DROP COLUMN` of the additions; existing data is unaffected.
- **The migration is idempotent.** Re-running is safe.
- **Indexes are created concurrently if running on a live system.** Replace `CREATE INDEX` with `CREATE INDEX CONCURRENTLY` (outside the transaction) for zero-downtime production migration. The DDL above shows the transactional form for clarity.
- **Enum changes (AGENT_RUNNER) require a separate non-transactional step** on PostgreSQL versions prior to 12. Plan accordingly if using enums.

### Verification Steps

After applying the migration, the regression suite required by ADP-12 must run. The minimum check matrix:

| Check | Expected |
|---|---|
| `SELECT count(*) FROM event` matches pre-migration count | Yes |
| `SELECT count(*) FROM event WHERE tenant_id = '00000000-...'` matches pre-migration count | Yes |
| Sample GET on each shipped endpoint with a default-tenant token returns byte-identical body | Yes (modulo any new informational fields the platform was previously emitting) |
| `INSERT` into event without tenant_id succeeds and gets default tenant | Yes |
| New audit entries have non-null `chain_hash` from first post-migration row onward | Yes |
| Old audit entries retain `chain_hash IS NULL` | Yes |

---

## 6. Cross-Reference Table

This table summarises every original requirement that the extension or adaptations touch.

| Original | Relationship | Reference |
|---|---|---|
| ES-01 | Extended additively (tenant column) | ADP-01 |
| ES-02 | Extended additively (tenant scope on read) | ADP-01 |
| ES-04 | Extended additively (tenant scope on global stream) | ADP-01 |
| ES-07 | Constrained for critical event types | ADP-11, IR-07 |
| ES-08 | Extended via existing metadata field | ADP-06 |
| PD-01 | Extended additively (tenant column) | ADP-02 |
| PD-03 | Coexists with tenant activation | IR-03 |
| PD-04 | Reinterpreted as global lifecycle | IR-03 |
| PD-07 | Extended additively (tenant scope) | ADP-02 |
| PD-08 | Preserved; hash recorded additionally | ADP-05, IR-02 |
| EE-01 | Extended additively (tenant column, artifact hash) | ADP-02, ADP-05 |
| (new) Tenant table | Introduced by ADP-04; extended for OIDC by ADP-04b | ADP-04, ADP-04b |
| IDN-01 | Extended additively (tenant binding, external identity, agent usernames) | ADP-04, ADP-04a, ADP-07, IR-06 |
| IDN-02 | Coexists with tenant scoping | ADP-04 |
| IDN-03 | Extended with AGENT_RUNNER role | ADP-07, IR-06 |
| IDN-04 | Used for agent token issuance; coexists with OIDC tokens | IR-06, OIDC-33 |
| API-08 | Extended for OIDC token verification | ADP-03, OIDC-05, OIDC-07, IR-06 |
| OBS-03 | Extended additively (chaining, agent I/O, pipeline correlation) | ADP-06, ADP-09, ADP-10, IR-08 |
| EXT-01 | Coexists with catalog-referenced service tasks | ADP-08, IR-04 |
| EXT-02 | Unchanged; agent monitoring independent | IR-09 |
| EXT-03 | Preserved as deep escape hatch | IR-05 |
| All Stages 1–6 | Regression suite required | ADP-12 |

---

## 7. Open Questions Specific to Adaptations

1. **Enum vs. table for roles.** Does the shipped schema store roles as an enum or as a referenced table? Affects ADP-07 migration form. The DDL above assumes a table; if it's an enum, the migration must be split into a non-transactional step.
2. **Existing token format.** Does the shipped Bearer token use JWT or an opaque token? ADP-03 assumes a claims-bearing format; if tokens are opaque, the tenant binding is in the token-to-user lookup record, not in the token itself.
3. **`app_user` table name.** The DDL uses `app_user` as a placeholder; the actual shipped name (`users`, `accounts`, etc.) should be substituted by the implementing agent based on the existing schema.
4. **Service catalog availability.** ADP-08 assumes REPO-07 is in place. If REPO-07 is being implemented in parallel, ADP-08 enforcement of `service_id` validation must wait until the catalog exists. Until then, only the schema acceptance of `service_id` is implemented; validation is added when the catalog is queryable.
5. **Audit chain rebuild on bulk imports.** If audit rows are ever inserted in bulk (e.g., disaster recovery), the chain must be rebuilt in order. Define the rebuild procedure as part of operational documentation.

These should be resolved before applying the migration to a production environment. Resolutions are recorded as design notes, not as edits to this document.

---

## 8. Document Status

This document is **0.4-draft**, paired with the 0.4-draft extension documents. Once the adaptations land and the regression suite passes, this document's status moves to **0.4-applied**. Subsequent extension waves will produce new adaptation documents, never edits to this one.
