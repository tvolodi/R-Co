> **Extends:** FIL-01, giving deletion a grace period and a staged reaper.

> Attachment deletion SHALL be a request, not an immediate removal. `DELETE /api/v1/attachments/{attachment_id}` sets `delete_requested_at` and leaves `state = 'active'`; the attachment stays readable and stays counted against quota for a 30-day grace period. A scheduled reaper SHALL then run three sweeps in the fixed order A, B, C on every tick: sweep A marks `active` rows past the grace period as `pending_delete`; sweep B deletes the storage object and then commits `state = 'purged'`, `purged_at = now()` together with the `bytes_used` decrement; sweep C deletes `purged` rows older than 7 days from the projection.

**Acceptance Criteria:**
- GIVEN a delete request at time T, WHEN the attachment is read at T plus 29 days, THEN it is still downloadable and `bytes_used` still includes its `size_bytes`.
- GIVEN `delete_requested_at` at T, WHEN sweep A runs after T plus 30 days, THEN `UPDATE attachments SET state='pending_delete' WHERE state='active' AND delete_requested_at <= now() - interval '30 days'` moves the row and a download attempt then returns HTTP 404 `attachment_not_found`.
- GIVEN a `pending_delete` row, WHEN sweep B completes, THEN the storage object is absent, `state` reads `purged`, `purged_at` is set, and `bytes_used` has been decremented by `size_bytes` in the same transaction as the state change.
- GIVEN a `purged` row with `purged_at` older than 7 days, WHEN sweep C runs, THEN the projection row is deleted and the `AttachmentPurged` entry remains in the event log.
- GIVEN a tick in which sweep B fails for one attachment, WHEN sweeps continue, THEN sweep C still runs for unrelated rows and the failed attachment stays `pending_delete` for the next tick.
- The reaper runs every 15 minutes and executes sweeps in the order A, B, C within one tick.

**See:** FIL-01, FIL-03, FIL-08, ES-07, ADP-11
