> Partition pruning is driven by `created_at` while instance reconstruction identifies work by `instance_id`. The platform SHALL resolve this by bounding every reconstruction query with a time predicate, not by accepting per-partition index fan-out. `instances.first_event_at` and `instances.last_event_at` SHALL be maintained in the same transaction as every append, and the reconstruction query SHALL be `SELECT * FROM events WHERE instance_id = $1 AND created_at >= $2 AND created_at < $3 ORDER BY sequence_num`, with `$2` and `$3` taken from those two columns.

**Acceptance Criteria:**
- GIVEN an instance whose events all fall in one calendar month and 13 partitions are attached, WHEN reconstruction runs, THEN the query plan shows exactly one partition scanned and the other 12 pruned.
- GIVEN an instance whose lifetime crosses into a month already moved to `events_archive`, WHEN reconstruction runs, THEN the same bounded predicate is applied to `events_archive`, the two result sets are merged by `sequence_num`, and the result is identical to reconstruction performed before that partition was aged out.
- GIVEN `instances.first_event_at` or `instances.last_event_at` is NULL, WHEN reconstruction is requested, THEN `ReconstructionWindowMissing` is returned, the projection row is repaired by one scan of the event log for that instance, and the bounded query is retried.
- GIVEN an append for an instance, WHEN it commits, THEN `last_event_at` is advanced in the same transaction, so the window can never exclude a committed event.
- GIVEN a reconstruction submitted without a time predicate, WHEN it is received, THEN it is refused rather than executed; unbounded reconstruction is not a supported query form.
- The upper bound is `last_event_at` plus one microsecond, so the exclusive `<` comparison still includes the final event.

**See:** PAR-01, PAR-03, XC-05 (deterministic replay depends on reconstruction returning the same events), IR-07 (archived partitions remain queryable), ES-07
