> **Extends:** FIL-01, binding storage accounting to the upload write.

> The `attachments` row insert, the `tenant_storage_usage.bytes_used` increment, and the `outbox` row carrying `AttachmentUploaded` SHALL be written in one database transaction. The platform SHALL reject an upload that would drive `bytes_used + size_bytes` above `tenant_storage_usage.bytes_quota` with HTTP 507 `tenant_quota_exhausted`, rolling back all three writes together. A quota breach therefore leaves no attachment row, no counter movement, and no outbox event.

**Acceptance Criteria:**
- GIVEN a tenant with `bytes_quota` of 1 GiB and `bytes_used` of 1020 MiB, WHEN a 10 MiB upload commits, THEN `bytes_used` reads 1030 MiB and exactly one `outbox` row carrying `AttachmentUploaded` exists for that `attachment_id`.
- GIVEN the same tenant at `bytes_used` of 1020 MiB, WHEN a 30 MiB upload is attempted, THEN the platform returns HTTP 507 `tenant_quota_exhausted`, `bytes_used` still reads 1020 MiB, and no `attachments` row exists for the generated `attachment_id`.
- GIVEN the transaction fails after the `attachments` insert, WHEN the failure is observed, THEN the counter increment and the outbox row are absent, and the orphaned storage object is collected by FIL-08.
- GIVEN two uploads for one tenant commit concurrently, WHEN both succeed, THEN `bytes_used` reflects both sizes; the counter row is updated under a row lock taken in the same transaction.
- GIVEN a successful sweep B purge (FIL-07), WHEN the purge transaction commits, THEN `bytes_used` is decremented by that attachment's `size_bytes` in the same transaction that sets state `purged`.
- The response body of HTTP 507 carries `bytes_used`, `bytes_quota`, and the rejected `size_bytes`.

**See:** FIL-01, FIL-04, FIL-07, FIL-08, TNT-01, OBS-03
