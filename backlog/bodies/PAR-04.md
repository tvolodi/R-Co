> Every partition SHALL carry `CHECK (tenant_id IS NOT NULL)` and a CHECK matching its own range bounds, both declared on the standalone table before `ATTACH PARTITION` is issued. With both constraints present PostgreSQL validates the attach from the catalog and takes `SHARE UPDATE EXCLUSIVE`; without them it scans the partition under a stronger lock. An attach against a partition missing either constraint SHALL be refused with `AttachScanRequired`.

**Acceptance Criteria:**
- GIVEN a standalone partition carrying both CHECKs, WHEN `ATTACH PARTITION` runs, THEN it acquires `SHARE UPDATE EXCLUSIVE` on the parent, scans no partition rows, and completes in under 50 ms whatever the partition size.
- GIVEN a standalone partition missing `CHECK (tenant_id IS NOT NULL)`, WHEN an attach is attempted, THEN `AttachScanRequired` is returned and the attach does not run.
- GIVEN an attach exceeds 1 s, WHEN the duration is observed, THEN it is reported as `AttachScanRequired`, since only a missing matching constraint causes the scan.
- GIVEN an attached partition, WHEN a row with `tenant_id IS NULL` is inserted, THEN the insert is rejected by the partition-level CHECK, so the tenant scoping invariant holds per partition and not only on the parent.
- The range CHECK on each partition matches the `FOR VALUES FROM ... TO ...` bounds used in the attach exactly; a mismatch is detected and rejected before the statement is issued.

**See:** PAR-01, PAR-02 (constraints declared at creation time), PAR-03 (the attach archival depends on), DDL-01
