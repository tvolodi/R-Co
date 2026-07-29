> **Extends:** TNT-01, pushing tenant isolation down into the object storage client.

> Every attachment object SHALL be stored under the key `<tenant_slug>/<attachment_id>/<sha256>`. The storage client SHALL compare the key prefix against the tenant slug of the authenticated session on every call it makes, and SHALL raise `CrossTenantObjectKey` when the prefix does not match. No caller-supplied value reaches the key: `tenant_slug` is derived from the session, `attachment_id` is server-generated, and `sha256` is computed from the payload bytes. The isolation check lives in the storage client, not in the route handler, so every call path is covered by one check.

**Acceptance Criteria:**
- GIVEN a session bound to tenant `swiftroute`, WHEN the storage client is called with a key whose first path segment is `vortex`, THEN it raises `CrossTenantObjectKey`, issues no request to the object store, and the caller receives HTTP 500.
- GIVEN an upload, WHEN the object key is assembled, THEN it equals `<tenant_slug>/<attachment_id>/<sha256>` with `tenant_slug` taken from the session claim and never from the request path, body, query string, or header.
- GIVEN two tenants upload byte-identical files, WHEN both objects are stored, THEN the keys differ in their first path segment and neither read path can reach the other object.
- GIVEN any code path that reads, writes, or deletes an attachment object, WHEN it calls the storage client, THEN the prefix check executes; no path bypasses the client to address the object store directly.
- `CrossTenantObjectKey` is recorded to the event log with the session tenant and the offending key prefix.

**See:** TNT-01, XC-05, FIL-01, FIL-05, FIL-06, FIL-08
