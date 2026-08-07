// Lint fixture (ISS-0605 / GH-537): the GOOD pattern.
//
// This file simulates a test that inserts a SCHEMA-mode public.tenant row
// WITH a co-located provisionTenantSchema() call. The T070 lint must NOT
// block on this file (it's the well-formed version of the pattern).
//
// Consumed by:
//   python tools/lint_test_tenant_provisioning.py tests/integration/_fixtures/lint_tenant_provisioning/ --no-baseline
//
// See bad_orphan_insert_test.zig for the design rationale (why a test block,
// why unwired).
const std = @import("std");

// Stand-in reference for the production helper exposed via the bpm module.
// Naming convention matches the lint's PROVISION_CALL regex target.
extern fn bpm_provision_tenant_schema(tenant_id: [*:0]const u8) void;

test "iss0605: well-formed SCHEMA-mode INSERT into public.tenant (GOOD fixture)" {
    // GOOD pattern: the canonical provisioner call is co-located with the
    // INSERT, so the lint sees the INSERT and the call in the same scope.
    const sql =
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, storage_mode)
        \\VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'good-provisioned', 'Good', 'ACTIVE', 'realm-good', 'SCHEMA')
    ;
    _ = sql;

    // Co-located provisioner call satisfies the lint's T070 rule.
    bpm_provision_tenant_schema("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
}
