// Lint fixture (ISS-0605 / GH-537): the BAD pattern.
//
// This file simulates a test that inserts a SCHEMA-mode public.tenant row
// WITHOUT a co-located provisionTenantSchema() call. The T070 lint must
// BLOCK on this file.
//
// Consumed by:
//   python tools/lint_test_tenant_provisioning.py tests/integration/_fixtures/lint_tenant_provisioning/ --no-baseline
//
// Why a `test "..."` block and not just a free function:
//
//   The lint's design (§2.2 in src/design/iss0605-test-env-c4-orphan-selfheal.md)
//   scopes every check to a test block — find_test_blocks() is the unit of
//   inspection. To exercise the rule we therefore need a real `test` block.
//
// Why this is not wired into build.zig as a real zig test:
//
//   lint_test_wiring.py scans every `*.zig` under tests/integration/ that
//   contains a test block, and treats any such file as a unit of code that
//   must be reachable from a b.addTest(...) root in build.zig. Fixtures
//   are NOT meant to be run; they are lint inputs. The repository-wide
//   convention for such inputs is to place them under a `_fixtures/` (or
//   `fixtures/`) subdirectory, which is excluded from wiring scans.
//
// Note: lint_test_wiring.py's SCAN_DIRS = ("src", "tests") currently has no
// fixtures exclusion — see the global policy note below. This fixture relies
// on the convention, not the linter, to remain unwired.
const std = @import("std");

test "iss0605: orphan SCHEMA-mode INSERT into public.tenant (BAD fixture)" {
    // BAD pattern: raw INSERT INTO public.tenant with storage_mode='SCHEMA',
    // no co-located provisionTenantSchema() / bpm_provision_tenant_schema()
    // call inside this test block. The lint's _block_has_provision_call()
    // returns False here, so T070 BLOCKER fires.
    const sql =
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, storage_mode)
        \\VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bad-orphan', 'Bad', 'ACTIVE', 'realm-bad', 'SCHEMA')
    ;
    _ = sql;
}
