> The scheduler SHALL run `plat_partition_maintenance` daily at 00:15 UTC in every tenant schema and SHALL keep `lead_months` future monthly partitions attached at all times, default 2. Partition creation SHALL be idempotent: creating a partition that already exists and is attached is a no-op. No append SHALL ever be the operation that creates a partition.

**Acceptance Criteria:**
- GIVEN today is the 20th of month N and partitions exist through month N, WHEN `plat_partition_maintenance` runs, THEN partitions for months N+1 and N+2 are created and attached before the job returns.
- GIVEN `plat_partition_maintenance` runs twice within the same day, WHEN the second run executes, THEN it creates nothing, raises no error, and leaves the partition set unchanged.
- GIVEN the count of attached future partitions falls to 1, WHEN maintenance evaluates lead time, THEN a WARN is raised; falling to 0 raises a BLOCKER before any append can fail with `PartitionMissingForWrite`.
- GIVEN the maintenance run is missed because the platform was down, WHEN the platform restarts, THEN the run is recovered on the SCH-05 path and the full lead horizon is restored before ingress resumes.
- Each creation appends `EXECUTION_PARTITION_CREATED` carrying the partition name and its range bounds.

**See:** PAR-01 (the partitioned tables), PAR-04 (constraints declared at creation time), SCH-05 (recovery of a missed maintenance run), DDL-01 (partition DDL passes the validator first)
