-- 1157_prm09_solution_pack_update.sql
-- PRM-09: solution pack update three-way diff state.
--
-- Global tables (public schema): install records are cross-tenant
-- infrastructure. They reference public.tenant for cascade-on-delete
-- correctness.
--
-- Three tables:
--   1. solution_pack_installs        — one row per (tenant, pack, installed_version)
--   2. solution_pack_artefact_bases  — exact base content snapshot for each
--                                       artefact at install time (Vb)
--   3. pack_update_resolutions      — keep_local / take_incoming / merged
--                                       decision per conflicting artefact
--
-- Conflict-resolution status is not stored on promotion_assertion_runs; the
-- PRM-09 design routes it through pack_update_resolutions directly so the
-- apply pipeline can enforce PRM-09 AC6 (any conflict without a resolution
-- blocks apply).
--
-- scope: public.

CREATE TABLE IF NOT EXISTS public.solution_pack_installs (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID        NOT NULL REFERENCES public.tenant(id) ON DELETE CASCADE,
    pack_id           TEXT        NOT NULL,
    installed_version TEXT        NOT NULL,
    installed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    installed_by      UUID        NOT NULL,
    CONSTRAINT uq_solution_pack_installs_tenant_pack_version
        UNIQUE (tenant_id, pack_id, installed_version)
);

CREATE INDEX IF NOT EXISTS public.idx_solution_pack_installs_tenant_pack
    ON public.solution_pack_installs (tenant_id, pack_id);

CREATE TABLE IF NOT EXISTS public.solution_pack_artefact_bases (
    id            UUID   PRIMARY KEY DEFAULT gen_random_uuid(),
    install_id    UUID   NOT NULL REFERENCES public.solution_pack_installs(id) ON DELETE CASCADE,
    artefact_id   TEXT   NOT NULL,
    artefact_kind TEXT   NOT NULL,
    base_content  JSONB  NOT NULL,
    CONSTRAINT uq_artefact_bases_install_artefact
        UNIQUE (install_id, artefact_id)
);

CREATE INDEX IF NOT EXISTS public.idx_solution_pack_artefact_bases_install
    ON public.solution_pack_artefact_bases (install_id);

CREATE TABLE IF NOT EXISTS public.pack_update_resolutions (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID        NOT NULL REFERENCES public.tenant(id) ON DELETE CASCADE,
    pack_id          TEXT        NOT NULL,
    incoming_version TEXT        NOT NULL,
    artefact_id      TEXT        NOT NULL,
    resolution_kind  TEXT        NOT NULL
        CHECK (resolution_kind IN ('keep_local','take_incoming','merged')),
    merged_content   JSONB,
    resolved_by      UUID        NOT NULL,
    resolved_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_pack_update_resolution_per_artefact
        UNIQUE (tenant_id, pack_id, incoming_version, artefact_id)
);

CREATE INDEX IF NOT EXISTS public.idx_pack_update_resolutions_lookup
    ON public.pack_update_resolutions (tenant_id, pack_id, incoming_version);