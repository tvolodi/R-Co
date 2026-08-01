# Design: Fix PostgreSQL C42883 Type Casting Errors (ISS-0124)

## 1. Problem Summary

PostgreSQL error **C42883** (`operator does not exist: text = uuid`) is raised in two integration tests because SQL queries cast database columns to `text` but fail to cast their corresponding SQL parameters, creating an asymmetric type comparison.

**Affected Functions:**
- `resolveOwnerUserId()` in `src/webhook/subscription_store.zig` (line 189)
- `revokeToken()` in `src/identity/service.zig` (line 1410)

**Root Cause:**
When a column is cast to one type (e.g., `id::text`) but the parameter remains untyped or incompatible (e.g., `$1` as a raw UUID), PostgreSQL has no operator to resolve the comparison `text = uuid`. This violates type safety and causes the C42883 operator-not-found error.

**Tests Affected:**
- `tests/integration/ext02_webhook_dispatch_test.zig` (calling resolveOwnerUserId)
- `tests/integration/reports_run_query_test.zig` (or similar integration test calling revokeToken)

## 2. Affected Code Locations

### Location 1: Webhook Subscription Store
- **File:** `src/webhook/subscription_store.zig`
- **Function:** `resolveOwnerUserId()`
- **Line:** 189
- **Current Query:**
  ```sql
  SELECT id::text FROM users WHERE id::text = $1 LIMIT 1
  ```
- **Parameter Type:** `actor_id: []const u8` (passed as `&.{actor_id}`)
- **Issue:** Column cast (`id::text`) but parameter not cast; PostgreSQL cannot compare `text = uuid`

### Location 2: Identity Service
- **File:** `src/identity/service.zig`
- **Function:** `revokeToken()`
- **Line:** 1410
- **Current Query:**
  ```sql
  UPDATE api_tokens
  SET revoked_at = COALESCE(revoked_at, NOW())
  WHERE id::text = $1
  RETURNING id::text
  ```
- **Parameter Type:** `token_id: []const u8` (passed as `&[_][]const u8{token_id}`)
- **Issue:** Column cast (`id::text`) but parameter not cast; PostgreSQL cannot compare `text = uuid`

## 3. Current Buggy Patterns

Both locations exhibit the same anti-pattern:

```sql
-- PATTERN 1 (Location 1):
SELECT id::text FROM users WHERE id::text = $1 LIMIT 1

-- PATTERN 2 (Location 2):
WHERE id::text = $1
```

**Why This Is Broken:**
- `id` is a `UUID` column type in the database schema
- Casting it to `text` (`id::text`) forces PostgreSQL to coerce the column
- Parameter `$1` remains an untyped placeholder
- PostgreSQL looks for an operator that can compare `text = ?`
- No such operator exists for `text = uuid`, hence C42883

## 4. Fix Strategy

### Approach A: Recommended — Remove Column Cast, Cast Parameter to UUID

**Rationale:**
- The `id` column is natively a UUID type
- Casting the column to text is unnecessary overhead and creates type confusion
- Casting the parameter to UUID (`$1::uuid`) is explicit and type-safe
- Follows PostgreSQL best practice: preserve native column types, cast parameters as needed

**Pattern:**
```sql
-- LOCATION 1:
SELECT id::text FROM users WHERE id = $1::uuid LIMIT 1

-- LOCATION 2:
UPDATE api_tokens
SET revoked_at = COALESCE(revoked_at, NOW())
WHERE id = $1::uuid
RETURNING id::text
```

**Semantic:** Removes the asymmetry by comparing `uuid = uuid` (after parameter cast), then selecting `id::text` only in the result set if text output is needed.

---

### Approach B: Alternative — Cast Both to Text

**Rationale:**
- Simpler mental model: both sides explicitly cast to the same type
- Useful if the calling code always passes string representations and casting to UUID would be inefficient

**Pattern:**
```sql
-- LOCATION 1:
SELECT id::text FROM users WHERE id::text = $1::text LIMIT 1

-- LOCATION 2:
UPDATE api_tokens
SET revoked_at = COALESCE(revoked_at, NOW())
WHERE id::text = $1::text
RETURNING id::text
```

**Semantic:** Compares `text = text` after explicit parameter cast; less type-safe but avoids UUID coercion overhead.

---

**Recommended Selection:** **Approach A** — it preserves type safety and aligns with the database schema (id columns are UUID types, not text).

## 5. Why This Fixes C42883

**Before Fix:**
```sql
WHERE id::text = $1
```
- `id::text` = type `text`
- `$1` = untyped parameter
- PostgreSQL searches for operator `text = <unknown>`
- No such operator exists for that type combination
- **Result:** C42883 error

**After Fix (Approach A):**
```sql
WHERE id = $1::uuid
```
- `id` = type `uuid` (native column type)
- `$1::uuid` = type `uuid` (parameter explicitly cast)
- PostgreSQL searches for operator `uuid = uuid`
- **Such an operator exists** (standard PostgreSQL UUID equality)
- **Result:** Query succeeds

**After Fix (Approach B):**
```sql
WHERE id::text = $1::text
```
- `id::text` = type `text`
- `$1::text` = type `text` (parameter explicitly cast)
- PostgreSQL searches for operator `text = text`
- **Such an operator exists** (standard text equality)
- **Result:** Query succeeds

In both cases, **symmetry is restored**: both sides of the `=` operator have compatible, known types.

## 6. Acceptance Criteria

- [ ] Design artefact created at `src/design/ISS-0124-fix.md` (this file)
- [ ] No implementation code present (no Zig functions, no SQL DDL statements)
- [ ] Both affected locations (subscription_store.zig line 189 and service.zig line 1410) are addressed with consistent casting strategy
- [ ] Problem summary clearly states the C42883 error and its root cause
- [ ] Fix strategy presents two approaches (A recommended, B alternative) with rationale
- [ ] Explanation of why the fix resolves C42883 is provided with SQL before/after comparisons
- [ ] All SQL patterns shown are example patterns, not executable code statements
