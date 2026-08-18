# Fix Design: ISS-QRY-ALLOWLIST-KIND-01, ISS-QRY-RESPONSE-FIELD-NAME-01, ISS-QRY-CURSOR-PARSE-01, ISS-QRY-AUDIT-SCHEMA-01

**Run ID:** WF03-qry01-04-bugs-20260818  
**Date:** 2026-08-18  
**GitHub issues:** #823, #824, #825, #826  
**Artefact type:** Type E (prose) — four bug fixes to existing novel module  
**Parent design:** `src/design/qry-01-04-entity-query.md`  
**Affected files:**
- `src/entities/query/allowlist.zig` (issues #823)
- `src/entities/query/compiler.zig` (issue #824)
- `src/api/routes/entity_query.zig` (issue #824)
- `src/entities/query/cursor.zig` (issue #825)
- `tests/integration/query_qry01_04_test.zig` (issue #826)

---

## Module purpose

This batch corrects four confirmed bugs in the QRY-01-04 entity query module. The allowlist loader (Issue 1) omits typed columns declared in `entity_definitions.definition_json` and discards the `tenant_id` parameter required to scope the cross-schema lookup to the correct tenant. The filter-rejection error path (Issue 2) loses the field name before the HTTP response is constructed, making the 400 non-actionable for callers. The cursor decoder (Issue 3) uses a first-colon split that collides with colons embedded in fingerprint text, corrupting every cursor that carries a sort directive and causing all pagination to fail. Two integration test queries (Issue 4) reference a non-existent `created_at` column on `audit_entries`, producing spurious test failures. No new migrations, module boundaries, or features are introduced; all changes are confined to the four files already within the QRY-01-04 module boundary.

---

## Issue 1 — ISS-QRY-ALLOWLIST-KIND-01 (#823): Allowlist missing typed columns + tenant scoping

### Confirmed root cause

`loadAllowlist` in `src/entities/query/allowlist.zig`:

1. Executes only one query (against `entity_filterable_keys`) and assigns every row `.kind = .jsonb_key`. Typed columns from `entity_definitions.definition_json.fields` are never loaded — only the four hard-coded `BUILTIN_FIELDS` are `.typed_column`. Any additional typed columns declared in `definition_json` are invisible to the allowlist, so the compiler cannot emit correct SQL for them.

2. Discards `tenant_id` with `_ = tenant_id`. This means the second query (against `entity_definitions` in the public schema, which has a `tenant_id` column) cannot be correctly scoped to the calling tenant, creating a cross-tenant data exposure risk.

Note: `entity_filterable_keys` is a per-tenant-schema table (migration `1168_qry_filterable_keys.sql`, `scope: tenant_only`). It has **no** `tenant_id` column — tenant isolation is provided by the connection's `search_path` (SPT-03 pattern), set by `pool.zig::applyRequestStorageRouting`. The `tenant_id` SQL predicate is therefore not applicable to that table.

### Fix design

**Function signature** — unchanged externally (tenant_id was already a declared parameter):

```zig
pub fn loadAllowlist(
    allocator:  std.mem.Allocator,
    conn:       *db.Conn,
    tenant_id:  []const u8,   // must NOT be discarded
    entity_key: []const u8,
) AllowlistError!EntityAllowlist;
```

**Step 1 — Query 1: JSONB key fields from `entity_filterable_keys`**

Tenant isolation: SPT-03 search_path (no `tenant_id` column exists in this table). The parameter is `entity_key` only.

SQL shape:
```sql
SELECT key_name, storage_type, is_sortable
FROM entity_filterable_keys
WHERE entity_key = $1
ORDER BY key_name
```

Params: `[$1 = entity_key]`

Result rows produce `AllowlistedField` entries with `.kind = .jsonb_key`.

**Step 2 — Query 2: typed columns from `entity_definitions.definition_json`**

`entity_definitions` lives in the `public` schema and has a `tenant_id` UUID column. Tenant scoping is via explicit WHERE predicate. `tenant_id` must be passed as a positional parameter.

SQL shape:
```sql
SELECT definition_json
FROM entity_definitions
WHERE tenant_id = $1::uuid
  AND name      = $2
  AND status    = 'ACTIVE'
LIMIT 1
```

Params: `[$1 = tenant_id, $2 = entity_key]`

If zero rows are returned (entity not registered for this tenant), the function proceeds with an empty typed-column list — this is not an error.

The `definition_json` column is JSONB. Its `fields` key is a JSON array. For each element where `queried = true`, extract:
- `name` (string) — the column name
- `storage_type` (string, optional) — one of `"text" | "numeric" | "boolean" | "timestamptz"`; default to `.text` if absent or unrecognised

Each qualifying element produces `AllowlistedField{.kind = .typed_column, .name = field.name, .storage_type = parsed_type, .is_sortable = true}`.

**Step 3 — Merge rule**

The final `EntityAllowlist.fields` slice is assembled in the following priority order (earlier entries shadow later ones for the same `name`):

1. `BUILTIN_FIELDS` (record_id, tenant_id, created_at, updated_at) — always `.typed_column`.
2. Dynamic typed columns from Query 2 — `.typed_column`. Skip any name already present in builtins.
3. JSONB key entries from Query 1 — `.jsonb_key`. Skip any name already present in builtins or dynamic typed columns.

This enforces the QRY-02 invariant: a typed column shadows a same-name JSONB key declaration.

**Error handling:**

`db.Conn.queryRow` failure on either query → return `AllowlistError.DbError`. Allocation failure at any point → return `AllowlistError.OutOfMemory`.

---

## Issue 2 — ISS-QRY-RESPONSE-FIELD-NAME-01 (#824): Field name lost at FilterFieldNotAllowlisted error boundary

### Confirmed root cause

`CompileError` is a Zig error set. Error sets carry no payload. When `compile()` returns `error.FilterFieldNotAllowlisted`, the field name that was rejected is gone. The handler in `entity_query.zig` produces the response body `{"error":"filter_field_not_allowlisted"}` with no field name, making it impossible for the caller to identify which field was rejected.

### Fix design

**Approach:** Add an output parameter `rejected_filter_field: *?[]const u8` to `compile()`. This out-parameter is populated — as an allocator-owned duplicate of the field name — only when the function returns `error.FilterFieldNotAllowlisted`. It is `null` in all other error paths and on success. The caller takes ownership of the slice and must free it when non-null.

This avoids rebuilding the `CompileError` return type or introducing a separate tagged union result wrapper, while keeping the change minimal and backward-compatible with all other call sites (they pass a local `?[]const u8` and always free if non-null).

**New `compile()` signature** (`src/entities/query/compiler.zig`):

```zig
pub fn compile(
    allocator:             std.mem.Allocator,
    table:                 []const u8,
    al:                    allowlist.EntityAllowlist,
    request:               types.EntityQueryRequest,
    tenant_id:             []const u8,
    rejected_filter_field: *?[]const u8,  // new — caller-owned, free when non-null
) CompileError!CompiledQuery;
```

`rejected_filter_field.*` is initialised to `null` at the top of `compile()`. When `al.find(f.field)` returns `null` for a filter node:
- Attempt `allocator.dupe(u8, f.field)` and assign the result to `rejected_filter_field.*` if allocation succeeds. If allocation fails, leave `rejected_filter_field.*` as `null` (the error response will omit the `"field"` key in that case).
- Return `error.FilterFieldNotAllowlisted`.

**Handler changes** (`src/api/routes/entity_query.zig`):

Declare before calling `compile()`:
```
var rejected_filter_field: ?[]const u8 = null;
```

Pass `&rejected_filter_field` as the final argument to `compile()`.

After the `compile()` call returns, if it returned an error, free `rejected_filter_field` after using it:
```
defer if (rejected_filter_field) |n| allocator.free(n);
```

In the `error.FilterFieldNotAllowlisted` branch of the compile error switch, construct a custom JSON response body (not the generic `problemBadRequest` builder):

```
{"error":"filter_field_not_allowlisted","field":"<field_name>"}
```

If `rejected_filter_field` is `null` (allocation failure at dupe time), omit the `"field"` key:

```
{"error":"filter_field_not_allowlisted"}
```

The response body must be built with `std.fmt.allocPrint`. HTTP status remains 400.

**JSON response shape for this error only:**

| Case | Body |
|---|---|
| Field name available | `{"error":"filter_field_not_allowlisted","field":"<name>"}` |
| Field name unavailable (dupe OOM) | `{"error":"filter_field_not_allowlisted"}` |

All other `CompileError` variants continue to use the existing `problemBadRequest` path unchanged.

---

## Issue 3 — ISS-QRY-CURSOR-PARSE-01 (#825): Colon-ambiguous cursor separator corrupts fingerprint decode

### Confirmed root cause

The raw cursor format (before outer base64url encoding) is:

```
QE:<issued_at_us>:<fingerprint>:<val1>|<val2>|…
```

The fingerprint value (e.g., `"created_at:desc,record_id:asc"`) is a comma-separated list of `<field>:<dir>` pairs — it contains colons. `decodeCursor` locates the fingerprint boundaries using `std.mem.indexOf(u8, rest_after_ts, ":")` which finds the **first** colon inside the fingerprint text, not the colon that terminates it. The fingerprint is truncated, producing a mismatch with the expected fingerprint and returning `CursorSortMismatch` for all valid cursors.

For the no-sort case, the effective fingerprint is `"record_id:asc"`. This splits as `fp_raw = "record_id"` (wrong) and `values_raw = "asc:<val1>|…"` (wrong).

### Fix design

**Approach (option b from the task):** Base64url-encode the fingerprint text before embedding it in the raw cursor. The base64url alphabet (`A–Z`, `a–z`, `0–9`, `-`, `_`) contains no `:` or `|` characters, making all outer `:` separators unambiguous without changing the overall cursor structure or the outer base64url wrapping.

**New raw cursor format** (before outer base64url):

```
QE:<issued_at_us>:<b64url_fingerprint>:<val1>|<val2>|…
```

Where `<b64url_fingerprint>` is the standard base64url-no-pad encoding of the `fingerprint.value` UTF-8 string.

The outer base64url encoding of the whole raw string is unchanged.

**`encodeCursor` change** (`src/entities/query/cursor.zig`):

Before appending the fingerprint field to the raw buffer, base64url-encode `fingerprint.value`:

```
intermediate = std.base64.url_safe_no_pad.Encoder.encode(fingerprint.value)
```

Append `intermediate` between the second and third `:` separators.

The encoded length is `std.base64.url_safe_no_pad.Encoder.calcSize(fingerprint.value.len)` bytes. Allocate temporarily, encode, append, then free.

**`decodeCursor` change** (`src/entities/query/cursor.zig`):

After locating `colon1` (end of `issued_at_us`) and `colon2` (end of `<b64url_fingerprint>`) using `std.mem.indexOf`, the bytes `rest_after_ts[0..colon2]` are the base64url-encoded fingerprint. Decode them:

```
decoded_fp_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(fp_b64_raw) catch
    return CursorDecodeError.CursorMalformed;
fp_decoded = allocator.alloc(u8, decoded_fp_len) catch return CursorDecodeError.OutOfMemory;
defer allocator.free(fp_decoded);
std.base64.url_safe_no_pad.Decoder.decode(fp_decoded, fp_b64_raw) catch
    return CursorDecodeError.CursorMalformed;
```

Compare `fp_decoded` (the decoded fingerprint text) with `fingerprint.value` using `std.mem.eql`. Mismatch → `CursorDecodeError.CursorSortMismatch`.

The remainder of `decodeCursor` (tuple split on `|`, percent-decode `%7C`, count validation) is unchanged.

**No-sort default case:**

Fingerprint text: `"record_id:asc"` (unchanged — built by `buildFingerprint`).  
Embedded as: `std.base64.url_safe_no_pad.Encoder.encode("record_id:asc")` = `cmVjb3JkX2lkOmFzYw` (no colons, no pipes).  
`decodeCursor` locates `colon2` correctly at the boundary between `cmVjb3JkX2lkOmFzYw` and the tuple values section.

**Wire format compatibility:**

This change is a **breaking change** to the cursor wire format. Any cursor issued before this fix is base64url-decoded to a raw string containing `QE:<ts>:<unencoded_fp>:<vals>`. After the fix, the decoder attempts to base64url-decode the fingerprint segment, which will fail for the old format → `CursorMalformed`. This is the correct and safe behaviour: the client receives a 400 with `cursor_malformed` and restarts pagination from page 1. No data loss occurs.

**`buildFingerprint` is unchanged.** It produces the plain-text fingerprint string. Only `encodeCursor` and `decodeCursor` change.

---

## Issue 4 — ISS-QRY-AUDIT-SCHEMA-01 (#826): Test uses non-existent column `created_at` on `audit_entries`

### Confirmed root cause

The `audit_entries` table (migration `020_obs03_audit_entries.sql`) defines its timestamp column as `timestamp` (type `TIMESTAMPTZ`). There is no `created_at` column on this table. The two test queries at lines 560 and 985 of `tests/integration/query_qry01_04_test.zig` use `ORDER BY created_at DESC LIMIT 1`, which fails at runtime with a PostgreSQL column-not-found error, causing the audit verification assertions to fail spuriously.

### Fix design

**File:** `tests/integration/query_qry01_04_test.zig`  
**Change count:** 2 one-line replacements.

**Line 560:**
```sql
-- before
"ORDER BY created_at DESC LIMIT 1"
-- after
"ORDER BY timestamp DESC LIMIT 1"
```

**Line 985:**
```sql
-- before
"ORDER BY created_at DESC LIMIT 1"
-- after
"ORDER BY timestamp DESC LIMIT 1"
```

No other changes to the test file are required.

---

## Data flow impact summary

| Issue | Component | Change type |
|---|---|---|
| #823 | `allowlist.zig::loadAllowlist` | Add second DB query; remove `_ = tenant_id`; merge typed_column entries |
| #824 | `compiler.zig::compile` | Add `rejected_filter_field: *?[]const u8` out-param; set on FilterFieldNotAllowlisted |
| #824 | `entity_query.zig::handleEntityQuery` | Read out-param; emit `{"error":…,"field":…}` body for this error |
| #825 | `cursor.zig::encodeCursor` | Base64url-encode fingerprint before embedding in raw cursor |
| #825 | `cursor.zig::decodeCursor` | Base64url-decode fingerprint segment before comparing to expected fingerprint |
| #826 | `query_qry01_04_test.zig` (×2) | `ORDER BY created_at` → `ORDER BY timestamp` |

---

## Dependencies

All changes stay within the existing module boundary. No new imports, tables, or migrations are required.

- Fix #823 reuses the existing `db.Conn.queryRow` call pattern already used in `entity_query.zig`.
- Fix #824 does not change `CompileError`. The `*?[]const u8` out-parameter is the only interface addition.
- Fix #825 uses `std.base64.url_safe_no_pad` already imported by `cursor.zig`.
- Fix #826 is a test-file-only change.

---

## Error taxonomy

The table below lists every error code that is **new** or **changed** by this fix batch. Error codes from other paths in the module that are entirely unchanged are omitted.

| Error code | Source | HTTP status | Condition | Status |
|---|---|---|---|---|
| `filter_field_not_allowlisted` | `compiler.zig::compile` → `entity_query.zig::handleEntityQuery` | 400 | A filter node references a field not in the allowlist | **Changed** — response body gains `"field":"<name>"` key when the field name could be duplicated; key is omitted only on allocation failure at dupe time |
| `cursor_malformed` | `cursor.zig::decodeCursor` | 400 | Outer base64url decode fails, fingerprint segment fails base64url decode, or `calcSizeForSlice` returns an error | **Changed** — now also raised for any cursor issued before this fix (old format embeds raw fingerprint text; decoder now expects base64url-encoded segment, so old cursors fail here) |
| `AllowlistError.DbError` | `allowlist.zig::loadAllowlist` | N/A (propagated up) | Either DB query in `loadAllowlist` fails | Unchanged in semantics; the new Query 2 (against `entity_definitions`) is an additional site that can produce this error |
| `AllowlistError.OutOfMemory` | `allowlist.zig::loadAllowlist` | N/A (propagated up) | Allocation failure during merge of typed columns or JSONB keys | Unchanged |
| `CursorDecodeError.CursorSortMismatch` | `cursor.zig::decodeCursor` | 400 | Decoded fingerprint text does not match the expected fingerprint | Unchanged in semantics; comparison now operates on decoded bytes rather than raw base64url bytes |
| `CursorDecodeError.OutOfMemory` | `cursor.zig::decodeCursor` | 400 | Allocation failure while decoding the fingerprint segment | Unchanged |

---

## Open questions

None. All four root causes are confirmed with line-level evidence. No requirement ambiguity exists.
