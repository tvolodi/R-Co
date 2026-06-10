# Test Spec: TNT-03 — Connection pool sets search_path per tenant on checkout

**Requirement:** TNT-03 — The connection pool SHALL set `search_path = <tenant_schema>, public`
on every connection immediately after resolving the tenant context for a request. No query
issued within that request SHALL access a different tenant's schema. The `search_path` MUST
be reset to a safe default when the connection is returned to the pool.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-TNT-03-01: Pool checkout for resolved tenant includes tenant schema in search_path
**Given:** A real pool connected to the test database  
**When:** The tenant context is set to a non-empty UUID (e.g. a per-test UUID), and
`pool.acquire()` is called  
**Then:** `SHOW search_path` on that connection returns a value that contains
`tenant_<uuid_no_hyphens>` before `public`  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN a request is resolved to tenant, WHEN a connection
is acquired from the pool, THEN the pool issues `SET search_path = <tenant_schema>,public`
before returning the connection"

### TC-TNT-03-02: After release and re-acquire with no tenant, search_path is public only
**Given:** A pool connection is acquired with a tenant context, used, then released via `pool.release()`  
**When:** The tenant context is cleared (empty string) and a new connection is acquired  
**Then:** `SHOW search_path` returns `public` only; no tenant schema name appears in the path  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN a connection is returned to the pool after a request
completes, THEN the pool resets `search_path = public`" and "GIVEN a request with no resolved
tenant, WHEN a connection is acquired, THEN `search_path = public` is set and no tenant schema
is prepended"

### TC-TNT-03-03: Two concurrent connections for different tenants have independent search_paths
**Given:** Two fresh per-test UUIDs representing tenant A and tenant B  
**When:** Connection A is acquired with tenant A context, and connection B is acquired with
tenant B context (before either is released)  
**Then:** `SHOW search_path` on connection A shows `tenant_<A_schema>` only;
`SHOW search_path` on connection B shows `tenant_<B_schema>` only; neither appears
in the other's search_path  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN two concurrent requests for different tenants A and B,
WHEN both acquire connections from the pool simultaneously, THEN each connection has its own
`search_path` set independently"

### TC-TNT-03-04: No-tenant connection (empty tenant context) shows public only
**Given:** The tenant context is set to an empty string  
**When:** `pool.acquire()` is called  
**Then:** `SHOW search_path` on that connection returns a value containing only `public`;
no `tenant_` prefix schema is present  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN a request with no resolved tenant (bootstrap token,
platform-admin system call), WHEN a connection is acquired, THEN `search_path = public` is
set and no tenant schema is prepended"

### TC-TNT-03-05: Unqualified table query on tenant connection resolves to tenant schema
**Given:** Tenant A is provisioned; a connection is acquired with tenant A's context  
**When:** `SELECT COUNT(*) FROM events` is executed on that connection  
**Then:** The query succeeds without a "relation does not exist" error, confirming that
`events` resolves to `tenant_A.events` (the tenant schema) rather than `public.events`  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN any SQL query issued on that connection that
references an unqualified table name, THEN PostgreSQL resolves it to
`tenant_schema.table`, not `public.table`"
