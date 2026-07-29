> **Extends:** FIL-07, fixing the ordering and idempotency conventions the reaper depends on.

> Every storage call SHALL be issued before the surrounding database transaction is opened, on the upload path and on the deletion path alike, so no database lock is held across a streaming transfer and a storage failure leaves no database write. Reaper idempotency SHALL come from a `WHERE expected_state` predicate on each sweep rather than from an advisory lock or a row lock held across the storage call. A re-run after a crash therefore matches zero rows for work already advanced. Storage objects with no `attachments` row and an age above 24 hours SHALL be collected as orphans by sweep B.

**Acceptance Criteria:**
- GIVEN an upload, WHEN execution is traced, THEN the object-store write completes before `BEGIN` is issued for the FIL-03 transaction; no transaction is open while payload bytes are transferred.
- GIVEN sweep B, WHEN execution is traced, THEN the object-store DELETE completes before `BEGIN` is issued for the state-change transaction; a failed DELETE means no transaction is opened and the row stays `pending_delete`.
- GIVEN sweep A is re-run immediately after a successful run, WHEN the statement executes, THEN `WHERE state='active' AND delete_requested_at <= now() - interval '30 days'` matches 0 rows and the sweep commits without effect.
- GIVEN the reaper process is terminated between sweep B's storage delete and its commit, WHEN the next tick runs, THEN sweep B re-issues the storage DELETE, treats a missing object as success, and commits the state change and the counter decrement.
- GIVEN two reaper instances tick concurrently, WHEN both run sweep B for one row, THEN the `WHERE state='pending_delete'` predicate lets exactly one commit the state change and the other updates 0 rows; no advisory lock is taken.
- GIVEN a storage object with no `attachments` row and an age above 24 hours, WHEN sweep B runs, THEN the object is deleted as an orphan.

**See:** FIL-02, FIL-03, FIL-07, ADP-05, OBS-03
