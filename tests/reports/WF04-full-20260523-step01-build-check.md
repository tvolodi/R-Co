# Test Report: WF-04 Step 1 — Build Check

**Run ID:** WF04-full-20260523
**Date:** 2026-05-23T06:08:30Z
**Agent:** TEST-RUNNER
**Status:** FAIL

---

## Summary

| Check | Status | Exit Code |
|---|---|---|
| `zig build` | ✅ PASS | 0 |
| `npm run type-check` | ✅ PASS | 0 |
| `npm run build` | ❌ FAIL | 2 |

Backend compiles cleanly. Frontend type-check passes (`tsc --noEmit`), but the production build (`tsc -b && vite build`) fails with 13 TypeScript errors across 6 files.

---

## Failure Details

### Issue 1: `ImportMeta.env` type not recognized (BLOCKER)

**Files:**
- `web/src/api/client.ts:11` — `error TS2339: Property 'env' does not exist on type 'ImportMeta'.`
- `web/src/hooks/useTasks.ts:29` — `error TS2339: Property 'env' does not exist on type 'ImportMeta'.`

**Root cause:** Vite client types (`vite/client`) are not included in the TypeScript configuration used by `tsc -b`. The `tsc --noEmit` check may use a different tsconfig that includes these types.

**Severity:** BLOCKER

---

### Issue 2: Unused variable (MINOR)

**File:** `web/src/api/identity.ts:54`
```
error TS6133: 'userIds' is declared but its value is never read.
```

**Severity:** MINOR

---

### Issue 3: Possibly undefined access (MAJOR)

**File:** `web/src/pages/admin/AuditLogPage.tsx:34`
```
error TS18048: 'e.actor_id' is possibly 'undefined'.
```

**Severity:** MAJOR

---

### Issue 4: Missing property `components` on `HealthStatus` (BLOCKER)

**File:** `web/src/pages/admin/HealthDashboardPage.tsx:36`
```
error TS2339: Property 'components' does not exist on type 'HealthStatus'.
```

**Severity:** BLOCKER

---

### Issue 5: Missing property `revoked_at` on `ApiToken` (BLOCKER)

**File:** `web/src/pages/admin/TokensPage.tsx:91,92,96`
```
error TS2339: Property 'revoked_at' does not exist on type 'ApiToken'.
```

**Severity:** BLOCKER

---

### Issue 6: Possibly undefined `instance_id` (MAJOR)

**File:** `web/src/pages/dlq/DlqPage.tsx:56`
```
error TS18048: 'e.instance_id' is possibly 'undefined'.
```

**Severity:** MAJOR

---

### Issue 7: Missing property `next_retry_at` on `DlqEntry` (BLOCKER)

**File:** `web/src/pages/dlq/DlqPage.tsx:63` (2 occurrences)
```
error TS2339: Property 'next_retry_at' does not exist on type 'DlqEntry'.
```

**Severity:** BLOCKER

---

### Issue 8: Missing property `items` on `WebhookSubscription[]` (BLOCKER)

**File:** `web/src/pages/dlq/WebhooksPage.tsx:83`
```
error TS2339: Property 'items' does not exist on type 'WebhookSubscription[]'.
```

**Severity:** BLOCKER

---

### Issue 9: Possibly undefined `event_types` (MAJOR)

**File:** `web/src/pages/dlq/WebhooksPage.tsx:86`
```
error TS18048: 'w.event_types' is possibly 'undefined'.
```

**Severity:** MAJOR

---

## Next Action

Route to **FRONTEND-DEV** to fix all 13 TypeScript errors, then re-run Step 1.
