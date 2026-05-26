# Test Spec: ADP-09 -- Tamper-evident audit chain

**Requirement:** ADP-09 -- The audit table gains `chain_hash` and `prev_chain_hash` where `chain_hash` is SHA-256 over canonical current-entry content plus `prev_chain_hash`, and validation recomputes and verifies chain integrity per tenant.
**Priority:** MUST
**Test layer:** integration

## Acceptance Criteria Coverage

- Chain schema/migration primitives exist and preserve additive compatibility.
- Chain linkage is deterministic and tenant-scoped.
- Tampering at a row fails validation at that row and propagates forward.
- Legacy pre-chain rows (`chain_hash=NULL`, `prev_chain_hash=NULL`) remain compatible.
- Canonical content normalization yields stable hash output for semantically equivalent JSON payloads.

## Test Cases

### TC-ADP-09-01: migration adds nullable chain columns, functions, and indexes
**Given:** A migrated test database.
**When:** Schema metadata for `audit_entries` and ADP-09 SQL primitives is queried.
**Then:** `chain_hash` and `prev_chain_hash` exist as nullable columns, validation/computation functions exist, and chain lookup/uniqueness indexes exist.
**Layer:** integration
**Acceptance criterion mapped:** ADP-09 additive schema + validation primitive availability.
**Implemented by:** `tests/integration/adp09_tamper_evident_audit_chain_test.zig` test `TC-ADP-09-01: migration adds nullable chain columns and validation primitives`.

### TC-ADP-09-02: tenant-scoped predecessor linkage and deterministic recomputation
**Given:** Two tenants each append two audit rows after migration.
**When:** Inserted rows are inspected for `prev_chain_hash` and `chain_hash`, and row 2 hash is recomputed via canonical function.
**Then:** Each tenant's first row has `prev_chain_hash=NULL`; each second row links to its own tenant predecessor; recomputed hash equals stored `chain_hash`.
**Layer:** integration
**Acceptance criterion mapped:** Per-tenant predecessor semantics and deterministic chain computation.
**Implemented by:** `tests/integration/adp09_tamper_evident_audit_chain_test.zig` test `TC-ADP-09-02: new rows chain deterministically with tenant-scoped predecessors`.

### TC-ADP-09-03: tamper detection fails at modified row and propagates to descendants
**Given:** A three-row chained segment for one tenant.
**When:** Middle row content is modified after insert and chain validation is executed.
**Then:** First issue is `ChainHashMismatch` on tampered row; next issue is `PrevHashMismatch` on descendant row, proving forward-failure progression.
**Layer:** integration
**Acceptance criterion mapped:** "Tampered row breaks validation at that row and forward."
**Implemented by:** `tests/integration/adp09_tamper_evident_audit_chain_test.zig` test `TC-ADP-09-03: chain validation reports tampered row first and descendants after`.

### TC-ADP-09-04: legacy/null-chain compatibility boundary handling
**Given:** A legacy pre-chain row inserted with both chain fields NULL, followed by first post-migration chained insert for same tenant.
**When:** Validation runs for that tenant.
**Then:** Boundary row starts chain cleanly (`prev_chain_hash=NULL` and non-null `chain_hash`), and validator reports no issues for leading legacy rows.
**Layer:** integration
**Acceptance criterion mapped:** Compatibility behavior for legacy/null-chain rows.
**Implemented by:** `tests/integration/adp09_tamper_evident_audit_chain_test.zig` test `TC-ADP-09-04: legacy pre-chain rows remain valid and boundary row starts cleanly`.

### TC-ADP-09-05: canonical hash stable across semantically equal JSON key ordering
**Given:** Two canonical hash computations with identical non-JSON fields and semantically equal JSON documents that differ only in key order.
**When:** `bpm_audit_compute_chain_hash` is executed for both inputs.
**Then:** Hashes are identical and 64-char lowercase hex, proving canonical JSON normalization behavior.
**Layer:** integration
**Acceptance criterion mapped:** Canonical chain computation expectations.
**Implemented by:** `tests/integration/adp09_tamper_evident_audit_chain_test.zig` test `TC-ADP-09-05: canonical hash computation is stable for semantically equal JSON`.

## Traceability Matrix

| ADP-09 acceptance area | Deterministic evidence |
|---|---|
| Additive schema and validation primitive availability | `TC-ADP-09-01` |
| Tenant-scoped predecessor linkage + deterministic hash recomputation | `TC-ADP-09-02` |
| Tamper detection row-of-change + forward propagation | `TC-ADP-09-03` |
| Legacy/null-chain compatibility | `TC-ADP-09-04` |
| Canonicalization stability expectations | `TC-ADP-09-05` |

## Execution Notes For TEST-RUNNER

- Primary target: `zig build test-integration` (with `BPM_TEST_DB_URL` set).
- Focus file: `tests/integration/adp09_tamper_evident_audit_chain_test.zig`.
- Focus filters: `TC-ADP-09-*`.
