-- GBL-143: PRM-04 / INV-1 — drop the stray public.promotion_reviews shadow.
--
-- promotion_reviews is a PER_TENANT business table (canonical home =
-- tenant_default and every tenant schema; migration 096 is `-- scope:
-- tenant_only`). Before that scope header existed, migration 096 ran with the
-- default `.all_schemas` scope, so its public pass created a stray copy in
-- public with zero RLS policies and no per-tenant copies — a cross-tenant
-- leak reported by SECURITY-REVIEWER as INV-1 BLOCKER (WF-02
-- WF02-prm02-05-20260816 Step 2c).
--
-- This GBL (public-only pass) removes that shadow. Because 096 is now
-- tenant_only, a public.promotion_reviews occurrence is BY DEFINITION a stray
-- shadow and is dropped whenever present — no `also exists in tenant_default`
-- guard is needed (unlike GBL-142, where the canonical home had to be proven
-- first; here the migration ordering guarantees 096 can never legitimately
-- create the public table after this lands).
--
-- Safety properties (same as GBL-141/142 shadow drops):
--   1. current_schema() guard: defensive belt-and-suspenders — a re-entry
--      from an unexpected schema context is a no-op.
--   2. DROP TABLE IF EXISTS ... RESTRICT — never CASCADE; no FK dependents
--      are expected (1160_sol_definition_install_fk.sql and the 1156 FK are
--      tenant-side), and any unexpected dependent fails loudly instead of
--      cascading.
--   3. Not data-destructive on the canonical side: tenant-schema copies are
--      never touched.

DO $$
BEGIN
    IF current_schema() != 'public' THEN
        RAISE NOTICE 'GBL-143: not in public schema — skipping (defensive guard).';
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'public' AND table_name = 'promotion_reviews'
    ) THEN
        EXECUTE 'DROP TABLE public.promotion_reviews RESTRICT';
        RAISE NOTICE 'GBL-143: dropped public.promotion_reviews (stray per-tenant shadow).';
    ELSE
        RAISE NOTICE 'GBL-143: public.promotion_reviews absent — nothing to drop.';
    END IF;
END $$;
