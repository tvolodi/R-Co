# Process: Correlated Effect Re-entry Ordering

| Field | Value |
|-------|-------|
| Process ID | `sys-effect-reentry-ordering` |
| Platform Workflow | PW-07 |
| Requirements | ORD-01, ORD-02, ORD-03, ORD-04 |
| Owner | Platform Admin |
| Scope | System-wide (effect completion re-entry in every tenant schema) |
| Source | `docs/workflows.yaml` (PW-07) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.7 |

## Summary

An effect leaves the engine as an emitted event, is performed by the Effects
Worker, and re-enters through a completion row carrying a `correlation_id` and a
`sequence_no`. A single drainer guarantees the order completions are dispatched,
not the order they are applied. This process places three distinct guards between
a completion row and instance state: the **claim guard** stops two BPM Consumers
taking the same row, the **execute guard** stops two BPM Consumers being inside
one correlation at the same moment, and the **order guard** stops a completion
being applied before its predecessor. Completions in different correlations pass
all three concurrently and are applied in parallel.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Effects Worker | System | Performs the external call and inserts the completion row |
| BPM Consumer | System (N identical workers) | Claims, guards, and applies completions to instance state |
| Correlation Cursor | System (table `plat_correlation_cursor`) | Records the highest `sequence_no` applied per correlation |
| Scheduler | System | Runs the gap sweeper that dead-letters stalled correlations |
| Catch-event Matcher | System (engine) | Consumes applied completions in `sequence_no` order |
| PostgreSQL | Database | Provides row locks and transaction-scoped advisory locks |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `completion_id` | UUID | Primary key of `plat_effect_completion` |
| `correlation_id` | text | Assigned at emit; stable for the lifetime of the correlation |
| `sequence_no` | bigint | Assigned at emit, contiguous from 1 within one `correlation_id` |
| `status` | enum | `PENDING`, `APPLIED`, `DEAD` |
| `payload` | JSONB | The effect outcome as returned by the Effects Worker |
| `received_at` | timestamptz | Set by the Effects Worker on insert |
| `consumer_count` | integer | Number of BPM Consumers; default 8 |
| `gap_timeout_seconds` | integer | Default 300; age at which a blocked successor is swept |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Effects Worker | Insert the completion row with `status = 'PENDING'` and the emit-assigned `sequence_no` | `(correlation_id, sequence_no)` already present? | -> Insert is a no-op under `ON CONFLICT DO NOTHING`; the retried effect does not duplicate | ORD-03 |
| 2 | BPM Consumer | Open a transaction and run the claim guard: `SELECT completion_id, correlation_id, sequence_no FROM plat_effect_completion WHERE status = 'PENDING' ORDER BY correlation_id, sequence_no FOR UPDATE SKIP LOCKED LIMIT 1;` | A row returned? | -> No row: the consumer sleeps 200 ms and repeats. `SKIP LOCKED` means no two consumers hold the same row | ORD-01 |
| 3 | BPM Consumer | Run the execute guard in the same transaction: `SELECT pg_try_advisory_xact_lock(hashtext(correlation_id)::bigint);` | Returns `true`? | -> `false`: another consumer is inside this correlation. `ROLLBACK`, the row returns to `PENDING`, the consumer moves to the next correlation | ORD-02 |
| 4 | BPM Consumer | Run the order guard: read `applied_seq` from `plat_correlation_cursor` for this `correlation_id` under the advisory lock already held | `sequence_no = applied_seq + 1`? | -> Not equal: `ROLLBACK` without applying and without error. The row stays `PENDING` and waits for its predecessor | ORD-03 |
| 5 | BPM Consumer | Apply the completion: deliver `payload` to the Catch-event Matcher, which advances instance state | Apply raises a typed engine error? | -> `ROLLBACK`; the advisory lock releases with the transaction; the row stays `PENDING` and is retried under the effect retry policy | ORD-03 |
| 6 | BPM Consumer | Advance the cursor in the same transaction: `UPDATE plat_correlation_cursor SET applied_seq = $2 WHERE correlation_id = $1 AND applied_seq = $2 - 1;` | Exactly 1 row updated? | -> 0 rows: another transaction advanced the cursor; `ROLLBACK` and re-claim. The cursor advance and the apply commit or roll back together | ORD-03 |
| 7 | BPM Consumer | Set `status = 'APPLIED'` on the completion row and `COMMIT` | Commit succeeds? | -> The advisory lock releases at commit; the successor becomes eligible on the next claim | ORD-02 |
| 8 | BPM Consumer | Re-enter the claim loop immediately | Another `PENDING` row exists for a different `correlation_id`? | -> Claimed and applied in parallel by any free consumer; correlations do not serialise against one another | ORD-04 |
| 9 | Scheduler | Run the gap sweeper every 60 s: find rows `PENDING` for longer than `gap_timeout_seconds` whose `sequence_no > applied_seq + 1` | Predecessor still absent? | -> The whole correlation is moved to `status = 'DEAD'` and routed to the DLQ as one unit; partial application is never left behind | ORD-03 |
| 10 | Scheduler | Record per-correlation lag: `max(sequence_no) - applied_seq` and the age of the oldest `PENDING` row | Lag exceeds 100 or age exceeds `gap_timeout_seconds`? | -> Emit `EXECUTION_CORRELATION_LAG` and escalate to Platform Admin | ORD-04 |
| 11 | Scheduler | Record advisory-lock contention: count of `pg_try_advisory_xact_lock` returning `false` per minute per consumer | Contention exceeds 50 per cent of claim attempts? | -> Emit `EXECUTION_CORRELATION_CONTENTION`; the claim `ORDER BY correlation_id` is spreading consumers unevenly and `consumer_count` is reduced | ORD-04 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Three guards, three jobs | Claim (`FOR UPDATE SKIP LOCKED`) prevents duplicate row pickup. Execute (`pg_try_advisory_xact_lock`) prevents concurrent entry into one correlation. Order (`sequence_no = applied_seq + 1`) prevents out-of-sequence application. No guard substitutes for another. |
| Claim guard scope | `FOR UPDATE SKIP LOCKED` locks one row. It says nothing about whether a sibling row of the same correlation is being applied elsewhere. That is the execute guard's job. |
| Execute guard scope | `pg_try_advisory_xact_lock(hashtext(correlation_id)::bigint)` is transaction-scoped. It releases at `COMMIT` or `ROLLBACK` with no explicit unlock, so a crashed consumer cannot strand a correlation. |
| Hash collisions are safe | `hashtext` maps into int4 and two distinct `correlation_id` values can share a lock key. A collision serialises two unrelated correlations and costs throughput. It cannot cause misordering, because the order guard is evaluated per `correlation_id` against its own cursor row. |
| Order guard scope | The order guard is a value comparison, not a lock. It is evaluated only while the execute guard is held, so `applied_seq` cannot move between the read and the update. |
| Try, never wait | The execute guard uses `pg_try_advisory_xact_lock`, not `pg_advisory_xact_lock`. A consumer that loses the guard releases its claim and does other work rather than blocking a connection. |
| No error on out-of-order | A completion arriving before its predecessor is a normal event, not a failure. Step 4 rolls back silently and the row remains `PENDING`. Retry count is not incremented. |
| Apply and cursor are atomic | The state change and the cursor advance are in one transaction. Applied state and `applied_seq` cannot diverge. |
| Cursor advance is conditional | `WHERE applied_seq = $2 - 1` makes a double-apply impossible even if both guards were bypassed. |
| Sequence numbers are contiguous | `sequence_no` is assigned at emit, starting at 1 per `correlation_id`, with no gaps. A gap means a lost emit, which the sweeper dead-letters rather than skips. |
| Dead-lettering is per correlation | When the sweeper gives up, every `PENDING` row of that correlation moves to `DEAD` together. A correlation is never left half-applied. |
| Cross-correlation parallelism is preserved | Distinct `correlation_id` values take distinct advisory keys and distinct cursor rows. `consumer_count` correlations are applied concurrently. |
| Duplicate completions | `(correlation_id, sequence_no)` is unique. A retried Effects Worker insert is absorbed by `ON CONFLICT DO NOTHING`. |

---

## Outputs

| Output | Description |
|--------|-------------|
| `plat_effect_completion` | One row per completion with `status` in `PENDING`, `APPLIED`, `DEAD` |
| `plat_correlation_cursor` | One row per `correlation_id` carrying `applied_seq` |
| Instance state advance | Catch-event matching driven strictly in `sequence_no` order within each correlation |
| DLQ entry | One entry per dead-lettered correlation, carrying every unapplied `sequence_no` |
| `EXECUTION_EFFECT_APPLIED` | Event appended to the log with `correlation_id` and `sequence_no` |
| `EXECUTION_CORRELATION_LAG` | Event emitted when per-correlation lag or age crosses its threshold |
| `EXECUTION_CORRELATION_CONTENTION` | Event emitted when advisory-lock rejection exceeds half of claim attempts |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Claim poll interval | 200 ms when the claim guard returns no row |
| Apply latency | A completion whose predecessor is already applied is applied within 1 s of insert |
| Guard rejection | A consumer losing the execute guard moves to another correlation within the same poll cycle; no backoff |
| Gap timeout | 300 s. A successor waiting longer than this for an absent predecessor is swept |
| Sweeper cadence | Every 60 s |
| Lag threshold | Per-correlation lag above 100 unapplied completions raises `EXECUTION_CORRELATION_LAG` |
| Contention threshold | Advisory-lock rejection above 50 per cent of claim attempts per minute reduces `consumer_count` by 2, floor 2 |
| Dead-letter escalation | Every dead-lettered correlation pages Platform Admin with its `correlation_id` and its unapplied `sequence_no` list |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| `ClaimContention` | Every `PENDING` row is locked by another consumer | `SKIP LOCKED` returns no row; consumer sleeps 200 ms and repeats |
| `CorrelationBusy` | `pg_try_advisory_xact_lock` returns `false` | Transaction rolls back, row returns to `PENDING`, consumer takes the next correlation |
| `OutOfOrderCompletion` | `sequence_no != applied_seq + 1` | Silent rollback, row stays `PENDING`, no retry-count increment, applied when the predecessor lands |
| `CursorRaceLost` | Conditional cursor update reports 0 rows | Rollback and re-claim; the winning transaction already applied that `sequence_no` |
| `ApplyFailed` | Catch-event matching returns a typed engine error | Rollback; the advisory lock releases; the effect retry policy governs the next attempt |
| `CorrelationStalled` | Predecessor absent beyond `gap_timeout_seconds` | Whole correlation set to `DEAD` and routed to the DLQ as one unit; Platform Admin paged |
| `DuplicateCompletion` | Effects Worker re-inserts the same `(correlation_id, sequence_no)` | Absorbed by `ON CONFLICT DO NOTHING`; no second apply |
| `MissingCursorRow` | No `plat_correlation_cursor` row for the `correlation_id` | Row inserted with `applied_seq = 0` inside the same transaction; sequence 1 then satisfies the order guard |
| `ConsumerCrash` | A consumer dies holding a claim and an advisory lock | Both are transaction-scoped; the backend exit releases them and the row returns to `PENDING` |
| `SequenceGapAtEmit` | Emit assigned a non-contiguous `sequence_no` | Sweeper dead-letters the correlation rather than skipping the gap; the emit path is repaired before replay |
