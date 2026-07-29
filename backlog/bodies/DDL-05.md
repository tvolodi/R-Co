> **Extends:** SPT-01, reserving an object namespace inside every tenant schema.

> The prefix `plat_` SHALL be reserved for platform-owned objects in every tenant schema. Tenant-authored DDL that creates, renames, or alters an object whose name begins with `plat_` SHALL be refused with HTTP 422 before any statement is executed. Every object the platform itself creates inside a tenant schema SHALL carry the prefix, so ownership is decidable from the name alone without a catalog lookup. The check runs inside `ValidatePlatformDDL` in the same pass as the lock-class and ordering checks.

**Acceptance Criteria:**
- GIVEN a tenant submits DDL creating a table named `plat_outbox`, WHEN validated, THEN `ReservedNamespace` is returned, the API responds 422 with the offending object name in the body, and no statement is executed.
- GIVEN a tenant submits `ALTER TABLE plat_correlation_cursor RENAME TO cursor_backup`, WHEN validated, THEN `ReservedNamespace` is returned and the API responds 422.
- GIVEN a platform migration creates an object in a tenant schema without the `plat_` prefix, WHEN validated, THEN `UnreservedPlatformObject` is returned and the file set is REJECTED.
- GIVEN a tenant creates a table named `platform_orders`, WHEN validated, THEN the verdict is ACCEPT; the reservation matches the exact prefix `plat_` and does not match a longer word sharing its first four characters.
- GIVEN a file set failing the namespace check and the lock-class check, WHEN validated, THEN the first failure in statement order is reported, so one plan run yields one deterministic verdict.

**See:** DDL-01 (the validating pass), SPT-01 (the schema-per-tenant layout this reservation partitions), MIG-01
