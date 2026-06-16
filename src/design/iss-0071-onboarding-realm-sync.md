# ISS-0071 — Onboarding Realm Sync: Dual Fix Design

**Issues addressed:** ISS-0071 (root causes A and B)  
**Run ID:** WF03-uat-onboarding-realm-sync-20260616  
**Agents:** FRONTEND-DEV (Fix A), BACKEND-DEV (Fix B)

---

## Module Purpose

This design covers two independent but related fixes that together allow the UAT-RUNNER to
drive the onboarding pipeline test with scenario-controlled inputs, and to detect
orphaned tenant DB records where the corresponding Keycloak realm has been deleted.

Fix A operates entirely in the Playwright test layer. Fix B operates in the Zig HTTP
handler layer. They share no code. They can be implemented and reviewed independently.

---

## Public Interface

### Fix A — Pipeline test slug injection (FRONTEND-DEV)

**File:** `web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts`

Two module-level constants replace the inline `randomUUID()` calls at the top of the
test file (lines 67–68), before the `test.describe` block:

```typescript
const INJECTED_SLUG: string | undefined = process.env.ONBOARDING_PIPELINE_SLUG
const INJECTED_ADMIN_USERNAME: string | undefined =
  process.env.ONBOARDING_PIPELINE_ADMIN_USERNAME
```

Inside the test body, replace the current random generation with a conditional:

```typescript
const uid      = randomUUID().slice(0, 8)
const slug     = INJECTED_SLUG ?? `pl-${uid}`
const hostname = `pl-tenant-${uid}.example.com`
```

The `admin_username` field (filled in Step 02 via `#admin_username`) is updated:

```typescript
await page.locator('#admin_username').fill(INJECTED_ADMIN_USERNAME ?? `pl-admin-${uid}`)
```

No other changes to the test body. All other fields (`admin_email`, `display_name`,
`admin_display_name`) continue to use the `uid` suffix for uniqueness, so running
multiple pipeline tests concurrently remains safe.

**Fallback path (backward compatible):** When neither env var is set, `INJECTED_SLUG`
and `INJECTED_ADMIN_USERNAME` are both `undefined`. The test falls back to the
existing random-generation behaviour, producing `pl-<uid>` and `pl-admin-<uid>`. The
`uid` is still generated (needed for derived fields). No external state is altered.

**Env var contract:**

| Variable | Type | Required | Semantics |
|---|---|---|---|
| `ONBOARDING_PIPELINE_SLUG` | `string` | No | Exact slug to use; must be a valid tenant slug (lowercase alphanumeric + hyphens) |
| `ONBOARDING_PIPELINE_ADMIN_USERNAME` | `string` | No | Exact Keycloak admin username to create in the new realm |

Both are read once at module load time (as top-level constants), not inside test hooks.
This ensures the values are stable for the lifetime of a single test run.

---

### Fix B — Realm-existence guard in GET onboarding endpoint (BACKEND-DEV)

#### New types and interface additions

**File:** `src/identity/provider/types.zig`

New input struct:

```zig
pub const CheckRealmExistsInput = struct {
    realm_id: []const u8,
};
```

**File:** `src/identity/provider/interface.zig`

New function pointer field added to the `IdentityProvider` struct, following the
existing pattern for `deleteRealmFn`:

```zig
checkRealmExistsFn: *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    input: types.CheckRealmExistsInput,
) errors.ProviderError!bool,
```

New dispatch method on `IdentityProvider`:

```zig
pub fn checkRealmExists(
    self: IdentityProvider,
    allocator: std.mem.Allocator,
    input: types.CheckRealmExistsInput,
) errors.ProviderError!bool
```

**File:** `src/identity/provider/manager.zig`

New forwarding method on `Manager` (same pattern as `deleteRealm`):

```zig
pub fn checkRealmExists(
    self: Manager,
    allocator: std.mem.Allocator,
    input: types.CheckRealmExistsInput,
) errors.ProviderError!bool
```

#### Keycloak adapter implementation

**File:** `src/identity/provider/adapters/keycloak/provider.zig`

The Keycloak adapter implements `checkRealmExistsFn` by calling the Keycloak Admin
REST API. The call uses the existing `sendRequest` helper (already used by
`deleteRealm` and `provisionRealm`).

HTTP call specification:
- Method: `GET`
- URL: `{admin_base_url}/admin/realms/{realm_id}` (no URL path encoding needed;
  realm IDs are already slug-safe)
- Auth: bearer token obtained via the existing admin credentials flow
  (same flow used by `deleteRealm`)
- Expected responses:
  - 200 — realm exists → return `true`
  - 404 — realm not found → return `false`
  - Any other status → return `error.ProviderUnexpectedResponse`
  - Network failure → propagate the underlying `anyerror` as `error.NetworkError`

No body parsing is required. The status code alone determines the result.

The no-op transport (used in unit tests) must also implement this function pointer.
Its stub should return `true` (realm exists) to ensure existing tests are unaffected.

#### Updated handleGetOnboarding signature

**File:** `src/api/routes/onboarding.zig`

The function signature acquires one new parameter — the IDP manager — inserted after
`service` and before `allocator`:

```zig
pub fn handleGetOnboarding(
    service: *identity_service.Service,
    manager: provider_manager_mod.Manager,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    onboarding_id: []const u8,
) HandlerResult
```

The import of `provider_manager_mod` at the top of `routes/onboarding.zig` follows the
pattern already used by `src/api/middleware/auth.zig`.

**File:** `src/main.zig` (call site, line 1335)

The existing call is updated to pass `id_mgr` (the `Manager` already constructed in
main):

```zig
const r = onboarding_routes.handleGetOnboarding(id_svc, id_mgr, req_alloc, actor, seg4);
```

#### Realm-existence check logic (inside handleGetOnboarding)

After the existing record-not-found guard and before returning the 200 response, the
following logic is inserted. The insertion point is immediately after `record_val` is
bound and before the final `body` is constructed (currently line ~299):

1. **Gate on state.** The check runs only when `record_val.state == .completed`. For
   `pending` or `failed` records, skip the check and return the stored body as-is.

2. **Extract idp_realm_id from response_body_json.** Parse `record_val.response_body_json`
   using `std.json.parseFromSlice` to read the `"idp_realm_id"` string field.  
   On parse failure (malformed JSON or missing field): log a warning, skip the check,
   and return the stored body — the guard must not fail an otherwise healthy GET.

3. **Probe realm existence.** Call:
   ```zig
   manager.checkRealmExists(allocator, .{ .realm_id = idp_realm_id })
   ```
   On `ProviderError`: treat as transient failure; skip the check and return the stored
   body as-is (network blip must not corrupt the onboarding record).

4. **If realm is missing:** call `markOnboardingRealmMissing` (new private function,
   see below) to transition the DB record to `failed` with `error = "realm_missing"`.
   Return a synthesised 200 response body reflecting the new state.

5. **If realm exists:** continue with the normal flow — return the stored body.

#### New helper: markOnboardingRealmMissing

**File:** `src/api/routes/onboarding.zig` (private function, not exported)

```zig
fn markOnboardingRealmMissing(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    onboarding_id: []const u8,
) void
```

This function updates the `onboarding_registry` row using a prepared statement:

```sql
UPDATE tenant_default.onboarding_registry
SET state        = 'failed',
    response_body = (COALESCE(response_body, '{}'::jsonb)
                     || '{"state":"failed","error":"realm_missing"}'::jsonb),
    completed_at  = NOW()
WHERE onboarding_id = $1::uuid
  AND state = 'completed'
```

The `AND state = 'completed'` predicate is a safety guard: if two concurrent GET
requests race to apply the transition, only one will update a row (the second finds
no matching row). The function discards the result row count — a no-op on the second
attempt is intentional.

The `response_body` JSONB merge (`||` operator) preserves all existing fields (slug,
oidc_authority, etc.) and adds / overwrites `"state"` and `"error"`. The frontend
receives a consistent object, not a stripped-down stub.

The return type is `void`; any DB error is silently discarded (consistent with
`persistOnboardingResult` which also returns void and discards errors). A failed
DB write on the transition must not prevent the client from receiving the 200
response reflecting the detected inconsistency.

---

## Data Flow Diagrams

### Fix A — Env var injection at test startup

```
UAT-RUNNER sets env
  ONBOARDING_PIPELINE_SLUG=swiftroute
  ONBOARDING_PIPELINE_ADMIN_USERNAME=alice.bauer
         │
         ▼
Module load (const INJECTED_SLUG, INJECTED_ADMIN_USERNAME)
         │
         ▼
test body: slug = INJECTED_SLUG ?? `pl-${uid}`         ← uses "swiftroute"
           adminUsername = INJECTED_ADMIN_USERNAME ?? … ← uses "alice.bauer"
         │
         ▼
Step 02: form filled with slug="swiftroute", admin_username="alice.bauer"
         │
         ▼
Step 04: result screen asserts page.getByText("swiftroute") → PASS
```

### Fix B — Realm guard in GET handler

```
GET /api/v1/onboarding/:id
         │
         ▼
selectOnboardingById → record
         │
    record == null? → 404
         │
    state != completed? → return stored body (200)
         │
         ▼
parse response_body_json → idp_realm_id
         │
    parse error? → return stored body (200, guard skipped)
         │
         ▼
manager.checkRealmExists(realm_id=idp_realm_id)
         │
    ProviderError? → return stored body (200, guard skipped)
         │
    realm exists? → return stored body (200)
         │
         ▼
markOnboardingRealmMissing(onboarding_id)  ← DB UPDATE
         │
         ▼
return synthesised body: {state:"failed", error:"realm_missing", …}  (200)
```

---

## Error Taxonomy

### OnboardingError (src/identity/onboarding.zig)

New variant added:

| Variant | Meaning | HTTP status |
|---|---|---|
| `RealmMissing` | DB record shows completed but Keycloak realm was not found during GET | n/a (internal only — manifests as state transition, not an error HTTP response) |

The `RealmMissing` variant is used only inside `handleGetOnboarding` as a local sentinel
to decide whether to call `markOnboardingRealmMissing`. It is never returned to the
caller — the handler always returns 200 with a JSON body reflecting the updated state.

### ProviderError extensions (src/identity/provider/errors.zig)

No new variants needed. `ProviderError.ProviderUnexpectedResponse` (already exists)
covers non-200/404 responses from the realm check endpoint.

### Response body error codes (onboarding_registry.response_body.error)

New value:

| Value | Meaning | Visible to frontend |
|---|---|---|
| `"realm_missing"` | Keycloak realm was deleted after onboarding completed | Yes — frontend should display a re-provision action |

Existing values `"validation_failed"`, `"realm_provisioning_failed"`, etc. are unchanged.

---

## State Transitions

The onboarding state machine gains one new transition path:

```
pending ──saga──▶ completed ──GET realm check──▶ failed (error=realm_missing)
                ↗
pending ──saga──▶ failed
```

The `completed → failed` transition fires lazily on the first GET request after the
realm disappears. It does not require a background scanner. It is idempotent: a second
GET on the same record finds `state == failed` and skips the check.

The `transition.zig` module is NOT modified. This transition is a side-effect-bearing
I/O operation (DB write + HTTP call). The pure function rule prohibits I/O in
`src/engine/transition.zig`. The transition lives entirely in the routes handler.

---

## Dependencies

### Fix A
- `web/tests/e2e/pipeline.ts` — no changes
- `web/playwright.config.ts` — no changes
- No new npm packages

### Fix B

| Module | Change |
|---|---|
| `src/identity/provider/types.zig` | Add `CheckRealmExistsInput` |
| `src/identity/provider/interface.zig` | Add `checkRealmExistsFn` pointer and `checkRealmExists` dispatch |
| `src/identity/provider/manager.zig` | Add `checkRealmExists` forwarding method |
| `src/identity/provider/adapters/keycloak/provider.zig` | Implement `checkRealmExistsFn` |
| `src/identity/onboarding.zig` | Add `RealmMissing` to `OnboardingError` |
| `src/api/routes/onboarding.zig` | Update `handleGetOnboarding` signature; add `markOnboardingRealmMissing` |
| `src/main.zig` | Pass `id_mgr` to `handleGetOnboarding` at call site |

**Must NOT depend on:**
- `src/engine/transition.zig` — pure function module; no I/O permitted
- Any new external HTTP library — use the existing `keycloak.HttpTransport` pattern

---

## Lego Catalog Classification

Both fixes are **Type E** (novel / cross-cutting).

Fix A touches test harness injection — explicitly listed as "Auth / identity / OIDC
flows" which always stays Type E. The pipeline test is not a standard list page or
CRUD endpoint.

Fix B touches the identity/OIDC provider interface (adding a new interface method) and
the onboarding saga error taxonomy. Cross-module orchestration sagas are explicitly
listed as Type E in `templates/lego-catalog.md §What stays in Type E`.

---

## Open Questions

None. Both root causes are fully diagnosed in ISS-0071 with sufficient evidence to
specify the fix without ambiguity.
