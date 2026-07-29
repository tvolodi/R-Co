---
id: OBS-05
title: Dead letter queue
stage: 6
priority: MUST
status: RELEASED
---

# OBS-05 — Dead letter queue `[MUST]`

> Events or timer firings that fail processing after N retries (configurable, default 3) SHALL be moved to a dead letter store with full context. Operators with PROCESS_OPERATOR role or above SHALL be able to inspect, retry, or discard dead-letter items via API.

**Acceptance Criteria:**
- GIVEN a processing failure (SERVICE_TASK, webhook dispatch, or timer firing) that has exceeded N retries (default 3), WHEN the N-th retry fails, THEN the item is moved to the dead letter store with full context: original payload, instance_id, error chain, timestamp.
- `GET /dlq` returns dead-letter items, paginated, filterable by `instance_id` and `item_type`. Requires PROCESS_OPERATOR or above.
- `POST /dlq/:id/retry` re-submits the item for processing; retry counter is reset to 0. Requires PROCESS_OPERATOR or above.
- `POST /dlq/:id/discard` permanently removes the item from the DLQ and appends an audit record per OBS-03. Requires PROCESS_OPERATOR or above.

**See:** EXT-01 (SERVICE_TASK exhausted retries feed DLQ), EXT-02 (webhook failures feed DLQ), OBS-03 (discard generates audit record), OBS-06 (DLQ depth threshold triggers alerting hook)

**Edge cases:**
- Retrying a DLQ item that belongs to a CANCELLED instance: the retry is rejected with HTTP 409; the item is discarded.
- Retrying a DLQ item that succeeds: item is removed from DLQ; instance resumes.
