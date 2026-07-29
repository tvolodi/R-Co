# Process: File Attachment Lifecycle

| Field | Value |
|-------|-------|
| Process ID | `sys-file-attachment-lifecycle` |
| Platform Workflow | PW-09 |
| Owner | Platform Admin / Tenant Admin |
| Scope | System-wide (exercised inside tenant `swiftroute`) |
| Requirements | FIL-01, FIL-02, FIL-03, FIL-04, FIL-05, FIL-06, FIL-07, FIL-08 |
| Source | `docs/workflows.yaml` (PW-09) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.10 |

## Summary

Governs how a business user attaches a document to a human task, how that
document is downloaded through a time-limited HMAC-signed URL, and how it is
purged after a 30-day grace period. Storage consumption is counted against the
tenant quota in the same transaction that creates the attachment row. Object
keys are tenant-prefixed and enforced at the storage client layer, and a
request for another tenant's attachment returns 404 - identical to a request
for an attachment that never existed.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Dispatcher | Lena Vogel / Tobias Kern (SwiftRoute) | Attaches the signed delivery note to the `ops-review` task |
| Operations Manager | Marco Stein (SwiftRoute) | Downloads the delivery note while reviewing the shipment |
| BPM Platform | System | Validates size and quota, writes the attachment row, signs and verifies download URLs |
| Storage Client | System | Rejects any object key not prefixed with the calling tenant's slug |
| Object Store | System | Holds the byte payload under `<tenant_slug>/<attachment_id>/<sha256>` |
| Deletion Reaper | System (scheduled) | Runs the three sweeps that mark, purge, and reap attachment rows |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `task_id` | UUID | Must be an open human task in the caller's tenant |
| `file` | multipart body | Single part; must not exceed the tenant tier cap (FIL-04) |
| `filename` | string | 1-255 characters; stored verbatim, never used to build the object key |
| `content_type` | string | Must be one of `application/pdf`, `image/jpeg`, `image/png`, `text/csv` |
| `tenant_slug` | string | Derived from the authenticated session; never read from the request |
| `attachment_id` | UUID | Server-generated; the only identifier exposed to clients |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Dispatcher | Opens the shipment's `ops-review` task in the portal and selects a delivery note PDF | Caller holds `attachment.write` on the task? | No -> 403 `attachment_write_forbidden` | FIL-01 |
| 2 | Platform | Measures the uploaded part against the tenant tier cap | Size > tier cap (free 10 MiB, standard 50 MiB, enterprise 250 MiB)? | Yes -> 413 `upload_exceeds_tier_cap`; nothing is written | FIL-04 |
| 3 | Platform | Computes SHA-256 of the payload and builds the object key `<tenant_slug>/<attachment_id>/<sha256>` | Key prefix equals the calling tenant's slug? | No -> storage client raises `CrossTenantObjectKey`; request fails with 500 and no object is stored | FIL-02 |
| 4 | Storage Client | Writes the object to the store before any database transaction is opened | Store write fails? | -> 502 `storage_write_failed`; no database row exists | FIL-02, FIL-08 |
| 5 | Platform | Opens one transaction: inserts `attachments` (state `active`), increments `tenant_storage_usage.bytes_used`, inserts the `AttachmentUploaded` row into `outbox` | `bytes_used + size > tenant_storage_usage.bytes_quota`? | Yes -> transaction rolls back, orphan object is queued for sweep B; 507 `tenant_quota_exhausted` | FIL-03 |
| 6 | Platform | Commits and returns `201 Created` with `attachment_id`, `filename`, `size_bytes`, `sha256` | - | Delivery note is listed on the `ops-review` task | FIL-01, FIL-03 |
| 7 | Operations Manager | Requests a download link for the attachment | Attachment row exists in the caller's tenant? | No -> 404 `attachment_not_found` | FIL-05, FIL-06 |
| 8 | Platform | Signs the URL: `exp = now + 300s`, `sig = base64url(HMAC-SHA256(key[kid], "kid\nexp\nattachment_id\ntenant_slug"))` | - | Returns `200` with `GET /api/v1/attachments/{attachment_id}/download?kid=&exp=&sig=` | FIL-05 |
| 9 | Operations Manager | Follows the signed URL and reads the delivery note | `exp` in the past, or recomputed `sig` differs? | -> 403 `signature_invalid`; the object is never streamed | FIL-05 |
| 10 | Platform | Recomputes the payload using the slug derived from the session, not from the query string | Slug in the request path resolves to a different tenant? | -> 404 `attachment_not_found`, byte-identical to the unknown-id response | FIL-06 |
| 11 | Dispatcher | Removes the delivery note from the task | Caller holds `attachment.delete`? | No -> 403 `attachment_delete_forbidden`. Yes -> `delete_requested_at = now()`; state stays `active` | FIL-07 |
| 12 | Deletion Reaper | Sweep A: `UPDATE attachments SET state='pending_delete' WHERE state='active' AND delete_requested_at <= now() - interval '30 days'` | Row already `pending_delete`? | Predicate matches 0 rows; sweep is a no-op | FIL-07, FIL-08 |
| 13 | Deletion Reaper | Sweep B: issues the object-store DELETE first, then opens a transaction to set `state='purged'`, `purged_at=now()` and decrement `bytes_used` | Store DELETE fails? | Transaction is never opened; row stays `pending_delete` for the next sweep | FIL-07, FIL-08 |
| 14 | Deletion Reaper | Sweep C: `DELETE FROM attachments WHERE state='purged' AND purged_at <= now() - interval '7 days'` | - | Row leaves the projection; `AttachmentPurged` remains in the event log | FIL-07 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Tenant-prefixed keys | Every object key starts with the calling tenant's slug. The storage client compares the key prefix against the session tenant on every call and raises `CrossTenantObjectKey` on mismatch. No caller can supply a key. |
| Server-derived slug | `tenant_slug` in the signature payload comes from the authenticated session. A slug present in the URL or body is discarded before the payload is assembled. |
| Signature payload order | The HMAC payload is exactly `kid`, `exp`, `attachment_id`, `tenant_slug` joined by LF. Reordering or omitting a component produces a different signature and a 403. |
| Signed URL lifetime | 300 seconds. Expired links are rejected on `exp` before the signature is recomputed. |
| Key rotation | `kid` selects the signing key from the active key set. Retired keys verify existing links for 300 seconds after retirement, then fail with 403 `signature_invalid`. |
| Probe safety | A request for an attachment in another tenant returns 404 with the same body and headers as a request for an unknown UUID. 403 is never returned for a cross-tenant read. |
| Transactional quota | The `attachments` insert, the `tenant_storage_usage.bytes_used` increment, and the `outbox` row are one transaction. A quota breach rolls back all three. |
| Per-tier single-upload cap | free 10 MiB, standard 50 MiB, enterprise 250 MiB. The cap is checked on the streamed part before the object store is contacted. |
| Storage before transaction | The object-store call is issued before the transaction opens, on both upload and delete, so no database lock is held across a streaming transfer. |
| Reaper idempotency | Each sweep carries a `WHERE expected_state` predicate (`active`, `pending_delete`, `purged`). A re-run after a crash matches 0 rows. No advisory lock is taken. |
| Grace period | 30 days between `delete_requested_at` and sweep A. During that window the attachment stays readable and stays counted against quota. |
| Content type allowlist | Only `application/pdf`, `image/jpeg`, `image/png`, `text/csv` are accepted. Other types return 415 `content_type_not_allowed`. |

---

## Outputs

| Output | Description |
|--------|-------------|
| `attachment_id` | UUID exposed to clients; the object key is never exposed |
| `attachments` row | `state` in `active` -> `pending_delete` -> `purged` |
| Object | Stored at `<tenant_slug>/<attachment_id>/<sha256>` until sweep B |
| `tenant_storage_usage.bytes_used` | Incremented on upload commit, decremented on sweep B commit |
| Signed download URL | `?kid=&exp=&sig=`, valid for 300 seconds |
| Event log entries | `AttachmentUploaded`, `AttachmentDeleteRequested`, `AttachmentPurged` |
| Outbox rows | One per attachment state change, emitted in the state-change transaction |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Signed URL lifetime | 300 seconds | Link issued | Link expires; the Operations Manager requests a new one |
| Delete grace period | 30 days | `delete_requested_at` set | Sweep A moves the row to `pending_delete` |
| Purged row retention | 7 days | `purged_at` set | Sweep C removes the projection row |
| Reaper cadence | Every 15 minutes | Scheduler tick | Each sweep runs in order A, B, C within one tick |
| Upload response | 500 ms for a 10 MiB part | Upload request | Platform NFR; exceeded uploads are recorded in the latency histogram |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 403 `attachment_write_forbidden` | Caller lacks `attachment.write` on the task | Request the permission from the tenant admin |
| 413 `upload_exceeds_tier_cap` | Single part above the tenant tier cap | Split the document or upgrade the tier |
| 415 `content_type_not_allowed` | Content type outside the allowlist | Convert the document to PDF and resubmit |
| 507 `tenant_quota_exhausted` | `bytes_used + size` above `bytes_quota` | Delete attachments and wait for sweep B, or raise the quota |
| 502 `storage_write_failed` | Object store rejects the write | No database row was created; the client retries the upload |
| 500 `CrossTenantObjectKey` | Storage client detects a key prefix outside the session tenant | Platform defect; the request is aborted before any write |
| 404 `attachment_not_found` | Unknown UUID, or an attachment owned by another tenant | Identical response in both cases; no existence signal is emitted |
| 403 `signature_invalid` | `exp` in the past, tampered `sig`, or a retired `kid` past its grace window | Request a fresh signed URL |
| Orphan object | Upload transaction rolls back after the object is stored | Sweep B deletes objects with no `attachments` row older than 24 hours |
| Sweep B partial failure | Object deleted, transaction commit fails | Row stays `pending_delete`; the next tick re-issues the delete and commits |
| Reaper crash mid-sweep | Process terminated between sweeps | Next tick re-runs all three sweeps; `WHERE expected_state` makes each a no-op on already-advanced rows |
