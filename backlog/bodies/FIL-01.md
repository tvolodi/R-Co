> **Extends:** API-10, adding a document-bearing sub-resource to the human task surface.

> The platform SHALL accept a file attachment against an open human task through `POST /api/v1/tasks/{task_id}/attachments` as a single multipart part. The caller MUST hold `attachment.write` on the task. The platform generates `attachment_id` as a UUID, computes the SHA-256 of the payload, stores `filename` verbatim, and returns `201 Created` with `{attachment_id, filename, size_bytes, sha256, content_type}`. `filename` is a display value only and is never used to construct the storage object key. `content_type` MUST be one of `application/pdf`, `image/jpeg`, `image/png`, `text/csv`.

**Acceptance Criteria:**
- GIVEN a caller without `attachment.write` on the task, WHEN it posts an attachment, THEN the platform returns HTTP 403 `attachment_write_forbidden`, writes no `attachments` row, and stores no object.
- GIVEN a multipart part with `content_type` outside the allowlist, WHEN it is posted, THEN the platform returns HTTP 415 `content_type_not_allowed` and names the received type in the response body.
- GIVEN a successful upload, WHEN the response is read, THEN it carries a server-generated `attachment_id` and the computed `sha256`, and it carries no storage object key, bucket name, or storage URL.
- GIVEN a `filename` containing `../` or an absolute path prefix, WHEN the attachment is stored, THEN the string is persisted verbatim in the `attachments.filename` column and the object key is built solely from `tenant_slug`, `attachment_id`, and `sha256`.
- GIVEN `task_id` names a task in another tenant, WHEN an attachment is posted, THEN the platform returns HTTP 404 and creates no row.
- `GET /api/v1/tasks/{task_id}/attachments` lists `attachment_id`, `filename`, `size_bytes`, `content_type`, and `state` for attachments in state `active`.

**See:** API-10, IDN-05, TNT-01, FIL-02, FIL-03, FIL-04, FIL-05, FIL-06
