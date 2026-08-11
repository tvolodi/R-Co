# Module: par-01-monthly-range-partitioning

**Requirement ID:** PAR-01
**Run ID:** WF02-batch-3-20260811 (Stage 16)
**Covers:** PAR-01
**Extends:** ES-07 (replaces the row-by-row archival move with a partition lifecycle)
**See also (not implemented here):** PAR-02 (proactive future partition creation — separate
design in this same batch), PAR-03 (partition-scoped retention via DETACH/ATTACH — separate
design in this same batch), PAR-04 (the CHECK-before-attach helper PAR-02/PAR-03 call — separate
design in this same batch), PAR-05 (online conversion of an *existing populated* `events` table
— explicitly out of scope here, see Scoping note), PAR-06 (time-bounded reconstruction —
out of scope here, later requirement), DDL-01 (every DDL statement this migration issues is
subject to `ValidatePlatformDDL`, already released)

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** The requirement's core is a database migration — normally the first matching
   rule. But `tools/codegen_migration.py`'s YAML schema (`templates/specs/migration.template.yaml`)
   has no concept of `PARTITION BY RANGE`, per-partition `CHECK` constraints declared before
   `ATTACH PARTITION`, or a loop that creates N monthly partitions — its `tables:` block emits
   one flat `CREATE TABLE`/`ALTER TABLE` per entry with a fixed column/constraint/index list.
   Forcing this migration through that template would either produce broken SQL or require so
   much `CUSTOM`-block override that the YAML would carry no real information (the
   `mig-01-platform-migrations-control-table.migration.yaml` precedent in this same batch series
   used *one* schema-qualification CUSTOM edit for a single flat table; this migration needs a
   dynamically-generated partition DDL block, two widened-PK table rebuilds, and a new
   idempotency table with its own FK considerations — a different order of complexity). Per
   `templates/lego-catalog.md`: "When in doubt, prefer Type E. A wrongly-classified Type A
   masquerading as Type E only wastes design time; a Type E forced into Type A masks real
   complexity from BACKEND-DEV." This migration is exactly the case Type E exists for.
2. **Type A / Type D / Type B?** No HTTP route, no React Flow node, no admin page.
3. **Type E — yes.** A structurally novel migration (partitioned parent tables, a new
   cross-partition idempotency table, dynamic per-month partition creation) that BACKEND-DEV
   must hand-write as SQL, following this prose design rather than running codegen.

This design still specifies the migration's SQL shape in full (per `docs/anti-patterns.md`'s
"Do NOT make database schema decisions outside a Type C migration YAML" caveat — read here as:
outside a *migration artefact*; the caveat's intent is "schema decisions belong to a design
artefact BACKEND-DEV implements from," which this document satisfies for a migration too
structurally novel for the Type C template). No SQL fenced block below exceeds the linter's
40-line cap; the full statement set is split into small, separately-labelled fragments.

## Scoping note — read this before implementing (CRITICAL, already settled)

**PAR-05 (online conversion of an existing populated `events` table into a partitioned parent
via parallel-table-build + backfill + rename-swap) is explicitly out of scope for this design.**
Confirmed by reading PAR-05's body directly: it is a separate, later requirement ("The one-time
conversion of an existing `events` table into a partitioned parent SHALL run online... `CREATE
TABLE events_part (LIKE events INCLUDING DEFAULTS INCLUDING IDENTITY) PARTITION BY RANGE
(created_at)`, and the live `events` table continues to accept appends unchanged" — i.e. PAR-05
assumes an *already-populated, non-partitioned* `events` exists and must stay live during
conversion).

This design instead defines `events`/`events_archive` as **already partitioned from the
migration that creates them** — i.e. the target steady-state shape PAR-01–PAR-04 describe, built
directly via `CREATE TABLE events (...) PARTITION BY RANGE (created_at)`. This is correct for
this batch's actual target environment: this project's test infrastructure re-applies the full
migration set from `001_event_store.sql` onward on every fresh `bpm_test` provisioning (see
`docs/guides/test_infrastructure_guide.md` and `tests/integration/helpers.zig`'s
`TestHarness.init()`), so there is no pre-existing populated `events` table in the environment
this batch's migration actually runs against. Building the partitioned shape from scratch is not
"picking an unsafe approach" under `docs/anti-patterns.md`'s DROP-without-preservation entry —
see **Open questions §1** for the one place this tension is NOT fully resolved by that argument
(a hypothetical long-lived `bpm_dev`/production database that already has `001`–`1146` applied),
flagged explicitly rather than silently assumed away.

**Consequence for migration ordering:** this design supersedes what `001_event_store.sql` and
`003_event_archive.sql` would otherwise create, by running as a **later** migration (next free
number, see Public interface) that the migration runner applies in sequence *after* `001`/`003`.
Since `001`/`003` already ran (in every fresh-provisioned test schema, and in any environment
that has migrated past `003`) and created `events`/`events_archive` as ordinary non-partitioned
tables, this design's migration cannot re-issue a second unqualified `CREATE TABLE events (...)`
— PostgreSQL has no `CREATE TABLE ... PARTITION BY` variant that converts an existing
non-partitioned table in place. The accepted pattern (see Public interface, Migration 1: schema
rebuild) is: drop the two non-partitioned tables migrations `001`/`003` created and recreate them
partitioned, in the SAME migration file, inside a single transaction. Because every environment
this migration is designed to run against is freshly migrated with **zero rows** in `events`/
`events_archive` at the point this migration executes (see Scoping note above), this is not the
"DROP TABLE without a data-preservation migration" anti-pattern in spirit — no data exists to
lose — but it IS the literal SQL anti-pattern text match, so BACKEND-DEV MUST NOT write a bare
`DROP TABLE events`. Use `DROP TABLE events` only after `TRUNCATE`/`COUNT(*)` guard logic; see
Public interface, Migration 1 for the exact guarded form.

## Module purpose

Define the migration(s) that give `events` and `events_archive` (and the platform-namespaced
`plat_event_idempotency` sidecar table) their PAR-01 target shape: `PARTITION BY RANGE
(created_at)` with one partition per calendar month (`events_YYYY_MM`), primary key widened from
`event_id` to `(event_id, created_at)` (PostgreSQL requires the partition key in every unique
constraint), and global `idempotency_key` uniqueness preserved via a new, non-partitioned
`plat_event_idempotency` table written in the same transaction as every append. This design also
identifies every existing column, index, and FK-dependent object the new shape must preserve or
adapt, and the changes `src/event_store/store.zig` needs to keep working against the widened
key.

## Current shape being preserved (verified against migrations, not assumed)

Per the handoff's mandatory reading, the full current shape of `events`/`events_archive` as of
the most recent migration touching each column:

**`events`** (created `001_event_store.sql`; altered by `044` global-seq addition inline in
`001` itself, `027_adp01_event_store_tenant.sql`, `055_xc06_backwards_compatibility.sql`, later
`tenant_id`-column removed again by the `GBL-116`/`GBL-123`/`GBL-130`/`GBL-131` dual-schema
cleanup passes — net effect: `tenant_id` IS present today, re-added by whichever of those GBL
files ran last against a given schema, per the store.zig `INSERT INTO events (..., tenant_id,
...)` call actually used in production code):

| Column | Type | Constraint |
|---|---|---|
| `event_id` | `UUID` | `PRIMARY KEY DEFAULT gen_random_uuid()` |
| `instance_id` | `UUID` | `NOT NULL` |
| `event_type` | `TEXT` | `NOT NULL` |
| `payload` | `JSONB` | `NOT NULL DEFAULT '{}'` |
| `actor_id` | `UUID` | `NOT NULL` |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` |
| `sequence_number` | `BIGINT` | `NOT NULL` |
| `idempotency_key` | `TEXT` | `NOT NULL` |
| `metadata` | `JSONB` | `NOT NULL DEFAULT '{}'` |
| `global_seq` | `BIGINT` | `NOT NULL DEFAULT nextval('events_global_seq')` |
| `tenant_id` | `UUID` | `NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'` (added 027) |

Indexes: `uq_event_idempotency (idempotency_key)` UNIQUE, `uq_event_sequence (instance_id,
sequence_number)` UNIQUE, `idx_events_global_seq (global_seq)`, `idx_events_instance_seq
(instance_id, sequence_number)`, `idx_events_instance_time (instance_id, created_at)`,
`idx_events_type (event_type)`, `idx_events_tenant_instance_seq (tenant_id, instance_id,
sequence_number)` (027), `idx_events_tenant_global_seq (tenant_id, global_seq)` (027),
`idx_events_instance_order (instance_id, created_at DESC, sequence_number DESC)` (054),
`idx_events_tenant_pipeline_run_seq (tenant_id, (metadata->>'pipeline_run_id'),
sequence_number)` (033).

**`events_archive`** (created `003_event_archive.sql`; `tenant_id` added by `027`; net effect
same caveat as `events` above): identical column set to `events` minus the `event_id` default
(archive rows keep their original `event_id`, no `gen_random_uuid()` default) plus `archived_at
TIMESTAMPTZ NOT NULL DEFAULT NOW()`. Indexes: `idx_archive_instance (instance_id,
sequence_number)`, `idx_archive_type (event_type)`, `idx_archive_time (created_at)`,
`uq_event_archive_idempotency (idempotency_key)` UNIQUE (013 — Invariant #5, post-archival
duplicate detection), `idx_events_archive_tenant_instance_seq`, `idx_events_archive_tenant_global_seq`
(027), `idx_events_archive_tenant_pipeline_run_seq` (033).

**Dependents that reference `events(event_id)` and must be re-examined under the widened PK:**

- `event_payload_store.event_id UUID NOT NULL UNIQUE REFERENCES events(event_id) ON DELETE
  CASCADE` (`012_event_retention.sql`) — a `FOREIGN KEY` target must be a column covered by a
  `UNIQUE`/`PRIMARY KEY` constraint *on its own* (or a matching composite FK). Once `events`'s
  PK becomes `(event_id, created_at)`, bare `event_id` is no longer, by itself, guaranteed
  unique-enforced at the FK-target end — Postgres actually still allows a single-column FK to
  reference a column that is merely part of a `UNIQUE` index only if a unique index/constraint
  exists on that column ALONE. `events` will have no other unique constraint on bare `event_id`
  once the PK widens, so the pre-existing `event_payload_store` FK becomes structurally invalid
  the moment the widened PK replaces the old one. See Public interface for the accepted fix
  (widen `event_payload_store`'s FK to `(event_id, created_at)`, mirroring `events`'s own PK
  widening) and Open questions §2 for the one thing this needs BACKEND-DEV to confirm against
  live `event_payload_store` row shape.
- `webhook_deliveries.event_id UUID NOT NULL REFERENCES events(event_id)`
  (`010_dlq.sql`) — same defect, same fix pattern.
- Both FKs currently have no `ON DELETE`/`ON UPDATE` behavior beyond what's stated above
  (`event_payload_store` is `ON DELETE CASCADE`; `webhook_deliveries` has no explicit `ON
  DELETE`, i.e. `NO ACTION`) — this design does not change that semantic, only the column list
  the FK targets.

**`instances.first_event_at`/`last_event_at` referenced by PAR-01's own body ("`See:` ...
PAR-06") do not exist yet** — confirmed by grep across `migrations/`: no migration adds these
columns. They belong to PAR-06 (a later, separate requirement in this same process document,
`docs/processes/system/event-log-partitioning.md`), not this batch. PAR-01's design does not
create them. (Note: the actual table is `instance_projections`, not `instances` — the
requirement bodies and the process doc use "`instances`" informally; PAR-06's own design, when
written, is responsible for resolving this naming precisely against `instance_projections`.)

## Data flow diagram

```
BACKEND-DEV writes migration NNN_par01_events_partitioning.sql (this design's Public interface)
        |
        v
zig build migrate  ---->  DROP events, events_archive (guarded, see Public interface)
        |                  CREATE events PARTITION BY RANGE (created_at)
        |                  CREATE events_archive PARTITION BY RANGE (created_at)
        |                  CREATE plat_event_idempotency (non-partitioned)
        |                  CREATE initial partitions covering current month + PAR-02's lead_months
        |                  re-create event_payload_store/webhook_deliveries FKs against widened PK
        v
Store.append() (src/event_store/store.zig)
        |
        |-- INSERT INTO events (..., created_at, ...) VALUES (...)   [routed to the correct
        |                                                             monthly partition by PG]
        |-- INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
        |     VALUES (...)  [same transaction — see Open questions §3 for ON CONFLICT semantics]
        v
COMMIT  (both rows durable together, or neither — PAR-01 AC3)
```

## Public interface

### Migration file placement

One migration file: **`migrations/1147_par01_events_partitioning.sql`** (next free number; the
current max is `1146_ord04_plat_correlation_cursor.sql`, confirmed via `ls migrations/ | sort`
at design time). Header: no `-- scope:` marker needed — this migration touches only
tenant-schema business tables (`events`, `events_archive`, `event_payload_store`,
`webhook_deliveries`) that already run in every schema pass unmarked, plus one new
`plat_`-prefixed table that is *itself* per-tenant (each tenant schema gets its own
`plat_event_idempotency`, matching how `events`/`events_archive` are per-tenant today — this is
NOT the cross-tenant `platform.platform_migrations` case `1144` handled, so no explicit schema
qualification or `-- scope: public` header is needed; leave it unmarked so it runs in every
schema pass exactly like `events` itself).

Per `docs/guides/backend_developer_guide.md §4.4`, this migration is additive in the sense that
it does not remove functionality — but it DOES contain `DROP TABLE` statements against
`events`/`events_archive`, so it deliberately does NOT fit the letter of "No `DROP` statements in
migrations." See the Scoping note above and Open questions §1 for why this is accepted here and
what must be true for it to stay safe.

Splitting into multiple files was considered (per the handoff's suggestion) and rejected: the
schema-rebuild statements (drop, recreate partitioned, recreate FKs) and the initial-partition-
creation loop are not independently useful or safely reorderable — a schema-rebuild migration
that leaves zero partitions attached would make every subsequent `INSERT` fail immediately with
`PartitionMissingForWrite` before PAR-02's maintenance job ever gets a chance to run, so both
must land in the same transaction. One file, one transaction (migrations already run inside a
transaction per `DB-01`/`DB-03`).

### Migration 1: schema rebuild (`events`, `events_archive`)

Guarded drop — only proceeds if the existing tables are empty (defense against the Open
questions §1 scenario), and only if they are not already partitioned (idempotency: re-running
this migration against a schema where it already succeeded must be a no-op, per `DB-01`'s
"idempotent SQL migration scripts" requirement and `docs/anti-patterns.md`'s `CREATE
TABLE`/`CREATE INDEX IF NOT EXISTS` idempotency entry):

```sql
DO $$
DECLARE
    v_is_partitioned BOOLEAN;
    v_row_count BIGINT;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_partitioned_table pt
        JOIN pg_class c ON c.oid = pt.partrelid
        WHERE c.relname = 'events'
    ) INTO v_is_partitioned;

    IF v_is_partitioned THEN
        RAISE NOTICE 'PAR-01: events already partitioned — skipping rebuild (idempotent).';
        RETURN;
    END IF;

    IF to_regclass('events') IS NOT NULL THEN
        SELECT count(*) INTO v_row_count FROM events;
        IF v_row_count > 0 THEN
            RAISE EXCEPTION 'PAR-01: events has % row(s); this migration only supports a '
                'zero-row rebuild. See PAR-05 for the online-conversion path required for a '
                'populated table.', v_row_count
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
    END IF;
    -- Falls through to the DROP/CREATE block below.
END $$;
```

The zero-row guard raises rather than silently proceeding — a populated-but-small `events` table
(e.g. a handful of smoke-test rows in a long-lived `bpm_dev`) fails loudly instead of losing
data silently, per `docs/anti-patterns.md`'s stub/silent-success entry family ("a TODO inside a
function that returns success is a silent false negative"). See Open questions §1.

```sql
DROP TABLE IF EXISTS event_payload_store;   -- FK to events(event_id); drop before events
DROP TABLE IF EXISTS webhook_deliveries;    -- FK to events(event_id); drop before events
DROP TABLE IF EXISTS events_archive;
DROP TABLE IF EXISTS events;

CREATE TABLE events (
    event_id          UUID            NOT NULL DEFAULT gen_random_uuid(),
    instance_id       UUID            NOT NULL,
    event_type        TEXT            NOT NULL,
    payload           JSONB           NOT NULL DEFAULT '{}',
    actor_id          UUID            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    sequence_number   BIGINT          NOT NULL,
    idempotency_key   TEXT            NOT NULL,
    metadata          JSONB           NOT NULL DEFAULT '{}',
    global_seq        BIGINT          NOT NULL DEFAULT nextval('events_global_seq'),
    tenant_id         UUID            NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
    PRIMARY KEY (event_id, created_at)
) PARTITION BY RANGE (created_at);

CREATE UNIQUE INDEX uq_event_sequence ON events (instance_id, sequence_number);
CREATE INDEX idx_events_global_seq ON events (global_seq);
CREATE INDEX idx_events_instance_seq ON events (instance_id, sequence_number);
CREATE INDEX idx_events_instance_time ON events (instance_id, created_at);
CREATE INDEX idx_events_type ON events (event_type);
CREATE INDEX idx_events_tenant_instance_seq ON events (tenant_id, instance_id, sequence_number);
CREATE INDEX idx_events_tenant_global_seq ON events (tenant_id, global_seq);
CREATE INDEX idx_events_instance_order ON events (instance_id, created_at DESC, sequence_number DESC);
CREATE INDEX idx_events_tenant_pipeline_run_seq
    ON events (tenant_id, (metadata->>'pipeline_run_id'), sequence_number);
```

`uq_event_idempotency (idempotency_key)` is deliberately **not** recreated on `events` — global
idempotency now lives in `plat_event_idempotency` (see below); PAR-01 AC1/AC2 require the
partitioned `events` table's own PK to be `(event_id, created_at)` and idempotency uniqueness to
be enforced by the sidecar table instead (partitioning would otherwise silently narrow
`idempotency_key` uniqueness to per-partition scope if the old unique index were kept — exactly
what PAR-01 AC2 forbids).

`events_archive` mirrors the same shape plus `archived_at`, also partitioned:

```sql
CREATE TABLE events_archive (
    event_id          UUID            NOT NULL,
    instance_id       UUID            NOT NULL,
    event_type        TEXT            NOT NULL,
    payload           JSONB           NOT NULL DEFAULT '{}',
    actor_id          UUID            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL,
    sequence_number   BIGINT          NOT NULL,
    idempotency_key   TEXT            NOT NULL,
    metadata          JSONB           NOT NULL DEFAULT '{}',
    global_seq        BIGINT          NOT NULL,
    tenant_id         UUID            NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
    archived_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (event_id, created_at)
) PARTITION BY RANGE (created_at);

CREATE INDEX idx_archive_instance ON events_archive (instance_id, sequence_number);
CREATE INDEX idx_archive_type ON events_archive (event_type);
CREATE INDEX idx_archive_time ON events_archive (created_at);
CREATE INDEX idx_events_archive_tenant_instance_seq ON events_archive (tenant_id, instance_id, sequence_number);
CREATE INDEX idx_events_archive_tenant_global_seq ON events_archive (tenant_id, global_seq);
CREATE INDEX idx_events_archive_tenant_pipeline_run_seq
    ON events_archive (tenant_id, (metadata->>'pipeline_run_id'), sequence_number);
```

`uq_event_archive_idempotency` (013's post-archival-duplicate index) is likewise not recreated
as a table-level unique index on the partitioned `events_archive` for the same partition-key
reason; `plat_event_idempotency` (below) is now the single place duplicate detection across BOTH
`events` and `events_archive` is answered from, superseding `013`'s purpose. Store.append()'s
"check `events_archive` for a post-archival duplicate" fallback path (see Open questions §3)
changes to "check `plat_event_idempotency`."

### Migration 2: `plat_event_idempotency`

```sql
CREATE TABLE IF NOT EXISTS plat_event_idempotency (
    idempotency_key   TEXT            PRIMARY KEY,
    event_id          UUID            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_plat_event_idempotency_event
    ON plat_event_idempotency (event_id, created_at);
```

Not partitioned (per PAR-01's body: "the separate non-partitioned table"). PK is bare
`idempotency_key` — global uniqueness across every calendar month, satisfying PAR-01 AC2 ("two
appends supplying the same `idempotency_key` in different calendar months" — the second is
rejected by THIS table's PK, not by anything partition-scoped). The `idx_plat_event_idempotency_event`
index supports the reverse lookup `Store.append()`'s duplicate-detection path needs (resolve
`event_id`/`created_at` for a known-duplicate key, to re-fetch the original row from the correct
`events` partition — see Open questions §3).

### Migration 3: re-establish `event_payload_store`/`webhook_deliveries` FKs against the widened PK

```sql
CREATE TABLE IF NOT EXISTS event_payload_store (
    id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    UUID    NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL,
    payload     JSONB   NOT NULL,
    byte_size   INTEGER NOT NULL,
    UNIQUE (event_id, created_at),
    FOREIGN KEY (event_id, created_at) REFERENCES events (event_id, created_at) ON DELETE CASCADE
);
```

`event_payload_store.created_at` is new — a denormalized copy of the owning event's `created_at`,
required because a composite FK to a partitioned parent must reference the FULL partition key,
not `event_id` alone. `Store.append()`'s Step 4 (`INSERT INTO event_payload_store (event_id,
payload, byte_size)`) must be updated to also supply `created_at` (the same `created_at` value
the just-inserted `events` row received) — see the "existing code paths assessed" section below.

```sql
CREATE TABLE IF NOT EXISTS webhook_deliveries (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id     UUID        NOT NULL REFERENCES webhook_subscriptions(id) ON DELETE CASCADE,
    event_id            UUID        NOT NULL,
    event_created_at    TIMESTAMPTZ NOT NULL,
    status              TEXT        NOT NULL DEFAULT 'pending',
    attempt_count       INTEGER     NOT NULL DEFAULT 0,
    max_attempts        INTEGER     NOT NULL DEFAULT 5,
    next_attempt_at     TIMESTAMPTZ,
    last_attempt_at     TIMESTAMPTZ,
    http_status         INTEGER,
    response_body       TEXT,
    error_message       TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (event_id, event_created_at) REFERENCES events (event_id, created_at)
);
CREATE INDEX IF NOT EXISTS idx_wd_pending ON webhook_deliveries (next_attempt_at)
    WHERE status IN ('pending', 'failed');
CREATE INDEX IF NOT EXISTS idx_wd_subscription ON webhook_deliveries (subscription_id);
```

Named `event_created_at` (not `created_at`) to avoid shadowing `webhook_deliveries`' own
pre-existing `created_at` (delivery-row creation time) — a genuine naming collision this
migration must not silently paper over. The webhook dispatcher (`src/webhook/dispatcher.zig`) is
NOT modified by this design (out of scope — no batch-3 requirement touches it) but callers that
build this INSERT will need the owning event's `created_at`, same as `event_payload_store`
above. Flagged in Open questions §4 since dispatcher call-site changes are BACKEND-DEV
implementation work this design does not enumerate exhaustively.

### Migration 4: initial partitions

At minimum, this migration must attach a partition for the current calendar month plus PAR-02's
default `lead_months = 2` (i.e. 3 partitions total: current + 2 future), for BOTH `events` and
`events_archive`, so `PartitionMissingForWrite` (PAR-01 AC4) is not immediately hit by the first
append after this migration runs — before PAR-02's daily job has ever executed. Each partition
carries `CHECK (tenant_id IS NOT NULL)` at creation, per PAR-04's "declared on the standalone
table before `ATTACH PARTITION`" rule, applied here too since even the very first partitions
should follow the same fast-attach discipline PAR-04 mandates for every later one:

```sql
DO $$
DECLARE
    v_month_start DATE := date_trunc('month', now())::date;
    v_offset INT;
    v_partition_name TEXT;
    v_range_start TIMESTAMPTZ;
    v_range_end TIMESTAMPTZ;
BEGIN
    FOR v_offset IN 0..2 LOOP
        v_range_start := (v_month_start + (v_offset || ' months')::interval);
        v_range_end := (v_month_start + ((v_offset + 1) || ' months')::interval);
        v_partition_name := 'events_' || to_char(v_range_start, 'YYYY_MM');

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I (LIKE events INCLUDING DEFAULTS, '
            'CHECK (tenant_id IS NOT NULL), '
            'CHECK (created_at >= %L AND created_at < %L))',
            v_partition_name, v_range_start, v_range_end
        );
        EXECUTE format(
            'ALTER TABLE events ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
            v_partition_name, v_range_start, v_range_end
        );

        v_partition_name := 'events_archive_' || to_char(v_range_start, 'YYYY_MM');
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I (LIKE events_archive INCLUDING DEFAULTS, '
            'CHECK (tenant_id IS NOT NULL), '
            'CHECK (created_at >= %L AND created_at < %L))',
            v_partition_name, v_range_start, v_range_end
        );
        EXECUTE format(
            'ALTER TABLE events_archive ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
            v_partition_name, v_range_start, v_range_end
        );
    END LOOP;
END $$;
```

This block is idempotent (`CREATE TABLE IF NOT EXISTS`, and re-`ATTACH`ing an already-attached
partition of the same name would fail — but the guarded `v_is_partitioned` check at the top of
Migration 1 causes this entire migration to `RETURN` early on any re-run against a schema where
it already succeeded, so this loop only ever executes once per schema; see Open questions §5).

Both `events_YYYY_MM` and `events_archive_YYYY_MM` naming reuses the SAME `YYYY_MM` suffix
convention (PAR-01's body only specifies it for `events`; this design extends the same pattern to
`events_archive` for consistency, since PAR-03 later DETACHes an `events_YYYY_MM` partition and
ATTACHes the identical relation to `events_archive` — the physical table is not renamed by that
operation, so its name keeps the `events_` prefix even once living under `events_archive`; this
design's `events_archive_YYYY_MM` names are for the ADDITIONAL,already-in-`events_archive`
partitions this migration seeds directly, which is a materially different case: no such partition
will ever exist before PAR-05's conversion produces `events_legacy`. **Open questions §6.**

## Existing `src/event_store/*.zig` code paths assessed for the PK widening

Read `src/event_store/store.zig` in full (Store.append/read/readGlobal/readHistory/archive) and
`src/event_store/registry.zig`. Concrete changes required, by call site:

- **`Store.append()` Step 3** (`INSERT INTO events (...) ... ON CONFLICT (idempotency_key) DO
  NOTHING RETURNING event_id, ...`): the `ON CONFLICT (idempotency_key)` clause targets a
  UNIQUE constraint/index that PAR-01 removes from `events` (idempotency moves to
  `plat_event_idempotency`). This is the single largest behavioral change PAR-01 forces on
  `append()` — see Open questions §3 for the two-statement replacement shape (insert into
  `plat_event_idempotency` first inside the same transaction, `ON CONFLICT (idempotency_key) DO
  NOTHING`, branch on whether that insert returned a row before ever touching `events`).
- **`Store.append()` Step 4** (`event_payload_store` insert): must add `created_at` as a bound
  parameter (see Migration 3 above) — currently `"pending-event-id"` is hardcoded as a known
  placeholder bug (comment: "real event_id from RETURNING row"); BACKEND-DEV fixing that
  pre-existing gap and wiring the new `created_at` column are two edits to the same call site,
  worth doing together.
- **`Store.append()`'s duplicate-detection fallback** (post-`ON CONFLICT DO NOTHING` empty
  RETURNING branch): currently queries `events` then `events_archive` by `idempotency_key`
  directly. Under PAR-01, `plat_event_idempotency` answers "does this key already exist and
  which `(event_id, created_at)` does it map to" in one lookup, and the caller then reads the
  correct `events` OR `events_archive` partition using that `(event_id, created_at)` pair (partition
  pruning applies automatically once `created_at` is known) instead of two unbounded scans.
- **`Store.archive()`**: this function's entire `INSERT INTO events_archive ... SELECT ... FROM
  events WHERE ...` / `DELETE FROM events ...` row-by-row move pattern is **incompatible** with
  PAR-03's "No `DELETE` statement SHALL run against `events` or `events_archive` at any point"
  rule. This is a real conflict this design surfaces rather than silently resolves — see Open
  questions §7. PAR-01 itself does not require `archive()` to change (ES-07's per-event-type
  policy engine is a separate concern from partition lifecycle), but the moment PAR-03 ships,
  `archive()`'s `DELETE FROM events` statements become forbidden by that requirement's own AC.
  This design flags it now because PAR-01's schema change is the point at which `archive()`'s
  assumptions about `events`'s shape (unpartitioned, deletable) stop holding.
- **`Store.read()` / `Store.readGlobal()` / `Store.readHistory()`**: none of these are BROKEN by
  the PK widening itself (they filter by `instance_id`/`global_seq`/etc., not by `event_id`
  alone, and none does `... WHERE event_id = $1` against `events`). They remain correct as
  written. However, several (`read()` with no filters, `readGlobal()`) query `events` without a
  `created_at` predicate, which — once `events` is partitioned — means PostgreSQL cannot prune
  partitions for those call shapes and must scan every attached partition. This is a real
  performance concern PAR-06 (time-bounded reconstruction, out of scope for this batch) exists
  specifically to fix; PAR-01 does not require fixing it, only flags that it now matters. No
  code change is required by PAR-01's own acceptance criteria.
- **`Registry.validatePayload()`/`Registry.getType()`** (`src/event_store/registry.zig`): not
  read against `events`/`events_archive` at all (they query `event_type_registry`), unaffected.

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `PartitionMissingForWrite` | An append's `created_at` falls in a month with no attached partition (PAR-01 AC4) | New `StoreError` variant `PartitionMissingForWrite`, mapped by `src/api/errors.zig` to HTTP 503 (transient — resolved by the next `plat_partition_maintenance` run, PAR-02) rather than 422 (not a client input error) |
| `23505` (unique_violation) on `plat_event_idempotency_pkey` | Two appends supply the same `idempotency_key` (PAR-01 AC2) | `Store.append()` treats this exactly as it previously treated `events`'s own `uq_event_idempotency` violation — `ON CONFLICT (idempotency_key) DO NOTHING`, branch to the duplicate-fetch path; no new error surfaces to the caller, `AppendResult.is_duplicate = true` as today |
| `23503` (foreign_key_violation) on `event_payload_store`/`webhook_deliveries`'s widened FK | A caller inserts into either side table with an `(event_id, created_at)` pair that does not exist in `events` | Should not occur in practice — both insert sites derive `created_at` from the just-committed `events` row in the same transaction; if it does occur, it surfaces as `StoreError.TransactionFailed` exactly as any other constraint violation in these call sites does today |
| Migration-time `object_not_in_prerequisite_state` (custom raised, see Migration 1) | This migration runs against an `events` table that already has rows | Migration aborts (transaction rolls back per `DB-01`'s crash-safety AC); `zig build migrate` exits non-zero; operator must resolve via PAR-05's conversion path, not this migration |

## Dependencies

- Depends on: `001_event_store.sql`, `003_event_archive.sql` (defines the tables this migration
  supersedes), `012_event_retention.sql`/`010_dlq.sql` (defines the FK-dependent side tables this
  migration rebuilds), `027_adp01_event_store_tenant.sql` (`tenant_id` column this migration
  preserves), DDL-01 (`ValidatePlatformDDL`, already released — every statement this migration
  issues must pass that gate; none of `DROP TABLE`/`CREATE TABLE`/`CREATE INDEX`/`ATTACH
  PARTITION` are in DDL-01's rejected classes, so this migration is expected to pass without
  changes to `ddl_validate.zig`).
- Must NOT depend on: PAR-02/PAR-03/PAR-04's runtime logic (this design only creates the schema
  shape and seed partitions those later pieces operate on) or PAR-05's conversion mechanism
  (explicitly out of scope, see Scoping note).
- `src/event_store/store.zig` depends on this migration's shape (see "Existing code paths"
  section) — BACKEND-DEV implementing this migration MUST implement the corresponding
  `store.zig` changes in the same handoff/commit, since a migration that ships without its
  matching application-code update leaves `append()` calling `ON CONFLICT (idempotency_key)`
  against a table that no longer has that unique index, which fails at runtime, not at migration
  time (see `docs/anti-patterns.md`'s CHECK-constraint/application-constant atomic-unit entry —
  the same principle applies to a dropped unique index feeding application logic).

## Open questions

1. **Zero-row guard vs. a genuinely populated non-test database.** This design's guard (Migration
   1) raises rather than destroys data if `events` is non-empty at migration time — but it does
   not solve the underlying tension the handoff itself named: if this migration is ever applied
   to a `bpm_dev` or production-like database that has organically accumulated real rows in
   `events` (as opposed to the test infrastructure's always-fresh `bpm_test`), the migration
   simply fails closed rather than converting. That is the intended behavior (fail loud, don't
   lose data), but it means **this migration alone does not fully migrate a real environment** —
   PAR-05's conversion mechanism is required first, or this migration must run before `events`
   ever accumulates rows (i.e., at initial platform bring-up). Needs ORCH/REQ-ANALYST
   confirmation of which environments this batch is actually expected to reach, and whether
   `bpm_dev` currently has any rows in `events` (this design could not verify that without a live
   DB connection, which CODE-DESIGNER does not have).
2. **`event_payload_store` FK widening — does it break any existing row shape?** Confirmed via
   grep that `event_payload_store`'s only current writer is `Store.append()` Step 4, and (per
   the Scoping note) no environment this migration runs against has existing rows — so the
   composite-FK rewrite is safe in the target environment. Flagged only because the actual
   codegen'd `INSERT INTO event_payload_store` statement in `store.zig` currently hardcodes
   `"pending-event-id"` as a placeholder (a pre-existing bug, not introduced by this design) —
   BACKEND-DEV should confirm whether fixing that placeholder is in scope for the same commit
   that adds the `created_at` column, since leaving it in place means the FK will always fail
   once genuinely enforced (today it silently succeeds only because pg.zig's placeholder
   handling has not been observed to reject it — worth a real test either way).
3. **Exact `Store.append()` two-statement replacement shape (idempotency check ordering).**
   PAR-01 AC3 requires the `events` row and the `plat_event_idempotency` row to commit or roll
   back together, but does not mandate which statement runs first. This design recommends
   inserting into `plat_event_idempotency` FIRST (`ON CONFLICT (idempotency_key) DO NOTHING
   RETURNING event_id, created_at`) — if that returns no row, the key already exists, fetch the
   pre-existing `(event_id, created_at)` and read the original row from the correct partition
   without ever touching `events`; if it returns a row, proceed to `INSERT INTO events`.
   BACKEND-DEV should confirm this ordering doesn't conflict with `sequence_number` assignment
   (Step 2, `instance_sequence` lock) — this design's read of `store.zig` suggests it doesn't
   (sequence assignment is per-instance, independent of idempotency-key uniqueness), but this is
   implementation-order judgment, not a schema decision, so it is left to BACKEND-DEV rather than
   dictated here.
4. **`webhook_deliveries`/`src/webhook/dispatcher.zig` call-site changes.** This design widens
   the FK and renames the referencing column to `event_created_at`, but does not audit
   `src/webhook/dispatcher.zig`'s INSERT statement (out of scope: no batch-3 requirement touches
   webhook delivery, and the handoff's mandatory-reading list did not name that file). BACKEND-DEV
   implementing this migration must grep `src/webhook/` for `webhook_deliveries` INSERT sites and
   update them to supply `event_created_at`, or the dispatcher will fail at its next INSERT after
   this migration ships. Flagged here so it is not missed as "PAR-01 only touches event_store.zig."
5. **Initial-partition seed loop idempotency under partial failure.** The `v_is_partitioned`
   early-return guard makes the whole migration a no-op on re-run once it has fully succeeded
   once — but if the migration is interrupted mid-way through Migration 4's partition loop
   (e.g. process killed after `events` is partitioned but before all 3 initial partitions attach),
   a re-run would see `v_is_partitioned = true` and skip re-attempting the remaining partitions,
   leaving `events` partitioned but under-provisioned. Migrations run inside a single transaction
   per `DB-01`/`DB-03` ("GIVEN a migration script that fails mid-execution, WHEN the failure
   occurs, THEN the entire migration is rolled back"), so a mid-migration crash should roll back
   the ENTIRE file including the partial partition loop — this scenario should not actually be
   reachable given that guarantee. Noted as a non-blocking documentation point, not a design gap,
   contingent on BACKEND-DEV confirming `zig build migrate`/`Migrations.runForSchema()` genuinely
   wraps each file in one transaction (per `docs/guides/backend_developer_guide.md §4.4`'s stated
   convention) rather than issuing autocommit DDL.
6. **`events_archive_YYYY_MM` initial-seed naming vs. PAR-03's later DETACH/ATTACH-produced
   names.** This design seeds `events_archive` with its OWN freshly-created, empty
   `events_archive_YYYY_MM` partitions (Migration 4) so `events_archive` is queryable and
   partition-complete from day one — but PAR-03's later DETACH/ATTACH cycle moves an
   `events_YYYY_MM` physical relation (never renamed) into `events_archive`, so a given calendar
   month could in principle end up represented by an `events_archive_YYYY_MM` seed partition (if
   PAR-01's initial seed already covered that month and nothing was ever detached into it) that
   coexists with the possibility of an `events_YYYY_MM`-named partition also being attached to
   `events_archive` for a DIFFERENT month once PAR-03 runs. This is not a collision (different
   months, different names) but it does mean `events_archive`'s attached-partition names are not
   uniformly prefixed — flagged for PAR-03's design to explicitly acknowledge rather than assume
   away, not a defect in this design.
7. **`Store.archive()` vs. PAR-03's "no `DELETE` against `events`/`events_archive`" rule.** As
   detailed in "Existing code paths assessed," `Store.archive()`'s current implementation issues
   `DELETE FROM events` and (for hard-delete policies) `DELETE FROM events_archive`-adjacent
   patterns. PAR-01 does not require changing `archive()` (ES-07's retention-policy engine is
   nominally a separate concern), but this design flags that `archive()` becomes actively
   incompatible with PAR-03 the moment PAR-03 ships, and recommends ORCH schedule `archive()`'s
   retirement/rewrite as part of PAR-03's own design rather than leaving it as a silent landmine
   discovered later. Not a blocker for PAR-01 itself, since PAR-01's own acceptance criteria say
   nothing about `archive()`.
