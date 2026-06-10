# Test Spec: TNT-04 — Public schema contains only routing and registry tables

**Requirement:** TNT-04 — The `public` schema SHALL be the platform's routing and cluster
management layer only. Any table not on the permitted list found in `public` at startup or
detected by the schema linter SHALL cause a startup warning logged at ERROR level.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-TNT-04-01: auditPublicSchema logs INFO "public schema audit: CLEAN" when no unexpected tables
**Given:** The test database has been migrated; only the 10 permitted tables are present
in `public` (no additional tables have been created for this test)  
**When:** `auditPublicSchema(allocator, &pool)` is called  
**Then:** The function returns without error; the structured logger receives an INFO-level
call with message `"public schema audit: CLEAN"`; no ERROR or WARN log entries are emitted
for unexpected tables  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN the audit finds all tables on the permitted list
and nothing else, THEN the platform logs an INFO-level message `public schema audit: CLEAN`"

### TC-TNT-04-02: auditPublicSchema logs ERROR naming the unexpected table and does not panic
**Given:** A temporary table named `unexpected_test_table_<uuid>` is created in `public`
before calling the audit; the `migration_window_active` flag is FALSE  
**When:** `auditPublicSchema(allocator, &pool)` is called  
**Then:** The function returns without error (no hard stop / no panic); the structured
logger receives an ERROR-level call with message `"public schema audit: unexpected table"`
and a `table_name` field equal to `unexpected_test_table_<uuid>`; the cleanup `DROP TABLE`
in the `defer` block runs after the test  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN the audit finds a table not on the permitted list,
THEN the platform logs an ERROR-level message naming the unexpected table and continues
(no hard stop)"

### TC-TNT-04-03: auditPublicSchema does not hard-stop — server continues after ERROR
**Given:** An unexpected table exists in `public` as in TC-TNT-04-02  
**When:** `auditPublicSchema` is called  
**Then:** The function returns (does not call `std.process.exit` or `unreachable`);
subsequent code after the call executes normally; no panic occurs  
**Layer:** integration  
**Acceptance criterion mapped:** "continues (no hard stop, to allow zero-downtime
migration windows)"

### TC-TNT-04-04: auditPublicSchema with migration_window_active=true logs WARN not ERROR
**Given:** An unexpected table exists in `public`; the `migration_window_active` column
in `public.onboarding_registry` is set to `TRUE` for at least one row  
**When:** `auditPublicSchema(allocator, &pool)` is called  
**Then:** The structured logger receives a WARN-level call (not ERROR) for the unexpected
table; the WARN message includes `"migration window active"` context  
**Layer:** integration  
**Acceptance criterion mapped:** "During the migration window … the audit produces a
WARNING rather than ERROR during this window"

### TC-TNT-04-05: AuditError.PoolExhausted is returned when no pool connection is available
**Given:** All pool connections are acquired and none are idle  
**When:** `auditPublicSchema` is called  
**Then:** The function returns `AuditError.PoolExhausted`; the caller logs at WARN level
and the server continues (no crash)  
**Layer:** integration  
**Acceptance criterion mapped:** AuditError taxonomy — `PoolExhausted` → logged at WARN,
audit skipped, server continues
