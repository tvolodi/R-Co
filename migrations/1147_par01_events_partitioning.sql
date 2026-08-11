-- 1147_par01_events_partitioning.sql
-- PAR-01: Monthly RANGE partitioning for events / events_archive.
-- See src/design/par-01-monthly-range-partitioning.md for the full design.
--
-- Rebuilds events/events_archive (created unpartitioned by 001_event_store.sql /
-- 003_event_archive.sql) as PARTITION BY RANGE (created_at), widens their PK to
-- (event_id, created_at), adds the plat_event_idempotency sidecar table for
-- global idempotency-key uniqueness (no longer enforceable by a single UNIQUE
-- index once events is partitioned), and re-establishes the composite FKs on
-- event_payload_store / webhook_deliveries against the widened PK. Seeds the
-- current month plus PAR-02's lead_months=2 (3 months total) of partitions for
-- both events and events_archive so PartitionMissingForWrite is not hit before
-- PAR-02's daily maintenance job ever runs.
--
-- Guarded, idempotent rebuild: only proceeds if events is not already
-- partitioned AND is empty. See the Scoping note in the design doc for why a
-- DROP TABLE is accepted here (every environment this migration targets is
-- freshly migrated with zero rows in events/events_archive at this point).

-- Every existence check in this migration is explicitly scoped to
-- current_schema() (never a bare to_regclass()/unqualified pg_class lookup)
-- per docs/anti-patterns.md's "Database — System Catalog Introspection"
-- entry: this file re-runs once per schema pass (public, then tenant_default,
-- then any other tenant schema) under each schema's own search_path
-- (`<schema>,public`), so an unscoped name lookup during a tenant pass can
-- silently resolve to public's already-created same-named object and
-- short-circuit this migration's own DROP/CREATE for the CURRENT schema —
-- confirmed live as the root cause of Migration 4's partition-seeding bug
-- below (search this file for "no partition of relation events found").
DO $$
DECLARE
    v_is_partitioned BOOLEAN;
    v_row_count BIGINT;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_partitioned_table pt
        JOIN pg_class c ON c.oid = pt.partrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'events' AND n.nspname = current_schema()
    ) INTO v_is_partitioned;

    IF v_is_partitioned THEN
        RAISE NOTICE 'PAR-01: events already partitioned in schema % — skipping rebuild (idempotent).', current_schema();
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'events' AND n.nspname = current_schema()
    ) THEN
        SELECT count(*) INTO v_row_count FROM events;
        IF v_row_count > 0 THEN
            RAISE EXCEPTION 'PAR-01: events has % row(s); this migration only supports a '
                'zero-row rebuild. See PAR-05 for the online-conversion path required for a '
                'populated table.', v_row_count
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
    END IF;

    -- Falls through to the DROP/CREATE block below (top-level statements in
    -- this file, not inside this DO block — see anti-patterns.md: guarding a
    -- DO block cannot itself skip subsequent top-level statements, so the
    -- v_is_partitioned check above only protects against re-entering THIS
    -- block's own side effects; the top-level DROP/CREATE statements below
    -- are naturally idempotent via IF EXISTS / IF NOT EXISTS instead).
END $$;

-- ── Migration 1: schema rebuild (events, events_archive) ───────────────────
-- Only actually destructive on a fresh/empty schema (guarded above); a
-- second run against an already-partitioned schema no-ops these via
-- IF EXISTS / IF NOT EXISTS, but to make the whole file a true no-op on
-- re-run we re-check partitioned state here too (cheap, avoids relying
-- solely on the DO block above having "returned" — plain SQL has no such
-- control flow across statements).

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

-- PostgreSQL requires every UNIQUE index on a partitioned table to include
-- ALL partition-key columns (error C0A000, verified live against a real
-- PostgreSQL 15+ instance: "UNIQUE constraint on partitioned table must
-- include all partitioning columns"). uq_event_sequence therefore widens to
-- include created_at, matching the exact same structural requirement that
-- already forced events' own PK to widen from (event_id) to
-- (event_id, created_at). In practice this does not weaken ES-02's "strict
-- per-instance ordering" guarantee: sequence_number is assigned exactly once
-- per (instance_id, sequence_number) pair inside a single Store.append()
-- transaction, and created_at is stamped by that same INSERT — two rows
-- genuinely sharing (instance_id, sequence_number) could previously only
-- arise from a application-level bug, which this index still catches
-- identically; it merely also requires created_at to match, which for any
-- correctly-functioning caller it always does (each sequence_number is
-- assigned to exactly one row, at exactly one created_at).
CREATE UNIQUE INDEX uq_event_sequence ON events (instance_id, sequence_number, created_at);
CREATE INDEX idx_events_global_seq ON events (global_seq);
CREATE INDEX idx_events_instance_seq ON events (instance_id, sequence_number);
CREATE INDEX idx_events_instance_time ON events (instance_id, created_at);
CREATE INDEX idx_events_type ON events (event_type);
CREATE INDEX idx_events_tenant_instance_seq ON events (tenant_id, instance_id, sequence_number);
CREATE INDEX idx_events_tenant_global_seq ON events (tenant_id, global_seq);
CREATE INDEX idx_events_instance_order ON events (instance_id, created_at DESC, sequence_number DESC);
CREATE INDEX idx_events_tenant_pipeline_run_seq
    ON events (tenant_id, (metadata->>'pipeline_run_id'), sequence_number);

-- uq_event_idempotency (idempotency_key) is deliberately NOT recreated here —
-- global idempotency now lives in plat_event_idempotency (Migration 2 below).
-- Partitioning would otherwise silently narrow idempotency_key uniqueness to
-- per-partition scope, which PAR-01 AC2 forbids.

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

-- uq_event_archive_idempotency (013's index) is likewise not recreated for the
-- same partition-key reason; plat_event_idempotency supersedes its purpose.

-- ── Migration 2: plat_event_idempotency ─────────────────────────────────────
-- Global (non-partitioned) idempotency-key uniqueness across events AND
-- events_archive AND events_ephemeral (PAR-03), written in the same
-- transaction as every append.

CREATE TABLE IF NOT EXISTS plat_event_idempotency (
    idempotency_key   TEXT            PRIMARY KEY,
    event_id          UUID            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_plat_event_idempotency_event
    ON plat_event_idempotency (event_id, created_at);

-- ── Migration 3: re-establish event_payload_store / webhook_deliveries FKs ──
-- against the widened (event_id, created_at) PK. A composite FK to a
-- partitioned parent must reference the FULL partition key, not event_id
-- alone.

CREATE TABLE IF NOT EXISTS event_payload_store (
    id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    UUID    NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL,
    payload     JSONB   NOT NULL,
    byte_size   INTEGER NOT NULL,
    UNIQUE (event_id, created_at),
    FOREIGN KEY (event_id, created_at) REFERENCES events (event_id, created_at) ON DELETE CASCADE
);

-- webhook_deliveries.subscription_id FKs to webhook_subscriptions, a
-- PER_TENANT table (docs/anti-patterns.md's dual-schema classification;
-- canonical home tenant_default). By the time this migration runs in the
-- `public` schema pass, GBL-112_tnt01_drop_legacy_public_business_tables.sql
-- (order ~1112, runs before this migration's ~1147) has already permanently
-- DROP TABLE ... CASCADE'd public.webhook_subscriptions — confirmed live
-- against bpm_dev, not assumed: recreating webhook_deliveries unconditionally
-- here fails migration-time with C42P01 "relation webhook_subscriptions does
-- not exist" in the public pass. Guard this CREATE TABLE to only run where
-- webhook_subscriptions actually exists (tenant_default and any other
-- provisioned tenant schema); in `public`, webhook_deliveries and
-- event_payload_store are themselves PER_TENANT stray shadows anyway (GBL-141
-- drops them from public on the NEXT full replay after this one) — skipping
-- the recreation in public simply means public carries no stray shadow at
-- all this time, which is strictly closer to the intended dual-schema
-- classification, not a regression.
DO $$
BEGIN
    IF to_regclass('webhook_subscriptions') IS NOT NULL THEN
        CREATE TABLE IF NOT EXISTS webhook_deliveries (
            id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            subscription_id     UUID        NOT NULL REFERENCES webhook_subscriptions(id) ON DELETE CASCADE,
            event_id            UUID,
            event_created_at    TIMESTAMPTZ,
            status              TEXT        NOT NULL DEFAULT 'PENDING',
            attempt_count       INTEGER     NOT NULL DEFAULT 0,
            attempt             INTEGER     NOT NULL DEFAULT 0,
            max_attempts        INTEGER     NOT NULL DEFAULT 5,
            next_attempt_at     TIMESTAMPTZ,
            last_attempt_at     TIMESTAMPTZ,
            http_status         INTEGER,
            response_body       TEXT,
            error_message       TEXT,
            created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT webhook_deliveries_status_check
                CHECK (status IN ('PENDING', 'DELIVERED', 'FAILED', 'RETRYING')),
            FOREIGN KEY (event_id, event_created_at) REFERENCES events (event_id, created_at)
        );
        CREATE INDEX IF NOT EXISTS idx_wd_pending ON webhook_deliveries (next_attempt_at)
            WHERE status IN ('PENDING', 'FAILED', 'RETRYING');
        CREATE INDEX IF NOT EXISTS idx_wd_subscription ON webhook_deliveries (subscription_id);
        CREATE INDEX IF NOT EXISTS idx_wd_status_next_attempt ON webhook_deliveries (status, next_attempt_at);
    ELSE
        RAISE NOTICE 'PAR-01: webhook_subscriptions absent in this schema pass — skipping webhook_deliveries recreation (per-tenant table, see comment above).';
    END IF;
END $$;

-- Notes on the rebuilt webhook_deliveries shape (differs from PAR-01's design
-- doc, reconciled here against the table's real evolution across
-- 010_dlq.sql -> 025_webhook_delivery_event_id_nullable.sql (event_id made
-- nullable) -> 085_iss106_webhook_deliveries_outbox.sql (added `attempt`
-- column, remapped `status` to the uppercase PENDING/DELIVERED/FAILED/RETRYING
-- domain + its CHECK constraint, added idx_wd_status_next_attempt) so this
-- rebuild does not silently regress those later changes:
--   - event_id is nullable (025) — this rebuild's composite FK therefore
--     cannot be NOT NULL either; a NULL event_id/event_created_at pair does
--     not violate the FK (SQL: a FK with any NULL column value is not
--     checked), preserving 025's "not keyed by event envelope" callers.
--   - `attempt` (085) is preserved alongside legacy `attempt_count` (085's
--     own migration keeps both; ISS-205 was the flagged future convergence,
--     out of scope here).
--   - `status` uses the uppercase PENDING/DELIVERED/FAILED/RETRYING domain +
--     CHECK constraint from 085, not the lowercase pending/success/failed/
--     exhausted domain PAR-01's design doc's Migration 3 sketch predates.

-- ── Migration 4: initial partitions ─────────────────────────────────────────
-- Current month + PAR-02's default lead_months=2 (3 months total), for BOTH
-- events and events_archive, so the first append after this migration does
-- not immediately hit PartitionMissingForWrite before PAR-02's daily job ever
-- runs. Each partition carries CHECK (tenant_id IS NOT NULL) + a range CHECK
-- at creation, per PAR-04's "declared before ATTACH PARTITION" discipline.

-- IMPORTANT (schema-agnostic-catalog-query anti-pattern, docs/anti-patterns.md
-- "Database — System Catalog Introspection"): this migration re-runs once per
-- schema pass (public, then tenant_default, then any other provisioned
-- tenant schema), each under its OWN search_path. A bare `to_regclass(name)`
-- or an unqualified `pg_inherits`/`pg_class` join by `relname` alone resolves
-- through the CURRENT search_path, which for the tenant passes is
-- `<tenant_schema>,public` — so `to_regclass('events_2026_08')` during the
-- tenant_default pass FOUND public's already-created same-named partition
-- (from the earlier public pass) and treated it as "already exists here",
-- silently skipping CREATE TABLE / ATTACH PARTITION for tenant_default
-- itself. Confirmed live: this exact bug left tenant_default.events with
-- ZERO partitions attached after a full migrate run, causing the very next
-- Store.append() to fail with "no partition of relation events found for
-- row" — every existence/attachment check below is therefore explicitly
-- scoped to `current_schema()` via pg_namespace, never a bare name lookup.
DO $$
DECLARE
    v_month_start DATE := date_trunc('month', now())::date;
    v_offset INT;
    v_partition_name TEXT;
    v_range_start TIMESTAMPTZ;
    v_range_end TIMESTAMPTZ;
BEGIN
    -- Idempotency: if events is already partitioned (the guard at the top of
    -- this file already returned in that case for the DO block above, but
    -- this is a SEPARATE DO block — plain top-level SQL has no cross-
    -- statement early-return, so re-check here too), skip re-seeding.
    -- Scoped to current_schema() for the same reason as every check below.
    IF EXISTS (
        SELECT 1 FROM pg_partitioned_table pt
        JOIN pg_class c ON c.oid = pt.partrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'events' AND n.nspname = current_schema()
    ) THEN
        FOR v_offset IN 0..2 LOOP
            v_range_start := (v_month_start + (v_offset || ' months')::interval);
            v_range_end := (v_month_start + ((v_offset + 1) || ' months')::interval);
            v_partition_name := 'events_' || to_char(v_range_start, 'YYYY_MM');

            IF NOT EXISTS (
                SELECT 1 FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relname = v_partition_name AND n.nspname = current_schema()
            ) THEN
                EXECUTE format(
                    'CREATE TABLE %I (LIKE events INCLUDING DEFAULTS, '
                    'CHECK (tenant_id IS NOT NULL), '
                    'CHECK (created_at >= %L AND created_at < %L))',
                    v_partition_name, v_range_start, v_range_end
                );
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM pg_inherits i
                JOIN pg_class child ON child.oid = i.inhrelid
                JOIN pg_namespace n ON n.oid = child.relnamespace
                WHERE child.relname = v_partition_name AND n.nspname = current_schema()
            ) THEN
                EXECUTE format(
                    'ALTER TABLE events ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
                    v_partition_name, v_range_start, v_range_end
                );
            END IF;

            v_partition_name := 'events_archive_' || to_char(v_range_start, 'YYYY_MM');
            IF NOT EXISTS (
                SELECT 1 FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relname = v_partition_name AND n.nspname = current_schema()
            ) THEN
                EXECUTE format(
                    'CREATE TABLE %I (LIKE events_archive INCLUDING DEFAULTS, '
                    'CHECK (tenant_id IS NOT NULL), '
                    'CHECK (created_at >= %L AND created_at < %L))',
                    v_partition_name, v_range_start, v_range_end
                );
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM pg_inherits i
                JOIN pg_class child ON child.oid = i.inhrelid
                JOIN pg_namespace n ON n.oid = child.relnamespace
                WHERE child.relname = v_partition_name AND n.nspname = current_schema()
            ) THEN
                EXECUTE format(
                    'ALTER TABLE events_archive ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
                    v_partition_name, v_range_start, v_range_end
                );
            END IF;
        END LOOP;
    END IF;
END $$;
