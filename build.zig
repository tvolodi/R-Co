const std = @import("std");
// ISS-0161 / GH #485: LuaJIT static build (LUA-01). See vendor/luajit/build.zig
// for the three-stage bootstrap and the two toolchain workarounds it needs.
const luajit_build = @import("vendor/luajit/build.zig");

/// ISS-0148 (GitHub #477): construct a run artifact for an integration/regression
/// test binary with the test-database cleanup sweep attached as a true ordering
/// PREDECESSOR.
///
/// Before this helper existed, `clean_test_db.step` and the `run_*` artifacts hung
/// off the same aggregating step as SIBLINGS. Zig's build runner imposes no ordering
/// edge between siblings of one step, so it was free to run `tools/clean_test_db.py`
/// concurrently with a test binary. The sweep's orphan pass enumerates tenant schemas
/// by name shape alone (`LIKE 'tenant\_%'`) and cannot distinguish a leaked schema
/// from one a live test is migrating right now, so it would `DROP SCHEMA ... CASCADE`
/// an in-flight schema mid-migration. `Migrations.runForSchema` then kept applying
/// files against a schema that no longer existed, failing with 42P01 on whichever
/// file happened to be next — which is why both the failing file and the named
/// relation varied run to run.
///
/// The edge MUST be attached to the run ARTIFACT, not to the aggregating step:
/// - 30 binaries reach `test-integration` only transitively through the
///   `test-integration-others-internal` barrier, which has no `clean_test_db` edge
///   of its own. A per-step fix would miss all of them.
/// - `dependOn` edges are a GLOBAL property of a Step in Zig's build graph, not
///   scoped to the path by which that Step was reached. An edge on the artifact
///   therefore holds on every path that can reach it — narrow step, umbrella and
///   barrier alike.
///
/// Folding the three repeated setup lines (create / setCwd / BPM_MIGRATIONS_DIR) into
/// this helper is what makes the ordering edge impossible to omit: once this is the
/// only construction path for an integration run artifact, a future contributor adding
/// a suite gets the edge automatically and cannot reintroduce the defect by forgetting
/// a line.
///
/// Acyclicity: every edge added here points from a run artifact to `clean_test_db`,
/// and `clean_test_db` has no edge into any run artifact (it depends only on
/// `lint_test_table_refs`). The added edges form a star into a sink-side node and
/// cannot close a cycle with the ISS-0106 barrier's existing edges.
///
/// See src/design/iss0148_clean_test_db_ordering_and_lock.md.
fn addIntegrationRun(
    b: *std.Build,
    test_artifact: *std.Build.Step.Compile,
    migrations_dir: []const u8,
    clean_test_db: *std.Build.Step.Run,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(test_artifact);
    run.setCwd(b.path("."));
    run.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);
    // The ordering edge that fixes ISS-0148: no integration binary may start
    // until the cleanup sweep has finished.
    run.step.dependOn(&clean_test_db.step);
    return run;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const adp12_phase = b.option([]const u8, "phase", "ADP-12 phase filter (pre|post)");
    // ISS-0607 / GH-542: gate the vendored pg client's stderr print on
    // PostgreSQL ErrorResponse messages. Default false so `zig test` does
    // not treat every negative-path integration test as a binary-level
    // failure. Pass `-Dlog-pg-errors=true` to restore the historical
    // behaviour for post-mortem debugging.
    const log_pg_errors = b.option(bool, "log-pg-errors", "Print PostgreSQL ErrorResponse payloads to stderr") orelse false;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "platform_version", "0.1.0");
    build_options.addOption(?[]const u8, "adp12_phase", adp12_phase);
    build_options.addOption([]const u8, "migrations_dir", b.path("migrations").getPath(b));
    build_options.addOption(bool, "log_pg_errors", log_pg_errors);
    const build_options_mod = build_options.createModule();
    const migrations_dir = b.path("migrations").getPath(b);

    // ---------------------------------------------------------------------------
    // Vendor dependencies
    // ---------------------------------------------------------------------------
    const http_dep = b.dependency("http", .{});
    const cel_dep = b.dependency("cel", .{});

    // ISS-0607 / GH-542: re-create pg_mod so that vendor/pg/pg.zig can
    // `@import("build_options")` and read `log_pg_errors`. The vendor
    // package itself does not declare imports — it is a pure single-file
    // module — so re-binding it here with an additional `build_options`
    // import is safe and propagates to every consumer below via the
    // pg_mod reference.
    const pg_mod = b.createModule(.{
        .root_source_file = b.path("vendor/pg/pg.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const http_mod = http_dep.module("http");
    const cel_mod = cel_dep.module("cel");
    const tenant_context_mod = b.createModule(.{
        .root_source_file = b.path("src/api/tenant_context.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pipeline_context_mod = b.createModule(.{
        .root_source_file = b.path("src/api/pipeline_context.zig"),
        .target = target,
        .optimize = optimize,
    });
    const obs_metrics_mod = b.createModule(.{
        .root_source_file = b.path("src/obs/metrics.zig"),
        .target = target,
        .optimize = optimize,
    });
    // ISS-0155 / GH #473: src/event_store/registry.zig performs real ES-05 JSON
    // Schema validation via this validator. registry.zig lives under the
    // `event_store` module (root src/event_store/store.zig), so it cannot reach
    // ../tools/json_schema.zig by relative @import — expose it as a named module.
    const json_schema_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/json_schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pool_root_mod = b.createModule(.{
        .root_source_file = b.path("src/db/pool.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
            .{ .name = "tenant_context", .module = tenant_context_mod },
            .{ .name = "pipeline_context", .module = pipeline_context_mod },
            .{ .name = "obs_metrics", .module = obs_metrics_mod },
            .{ .name = "json_schema", .module = json_schema_mod },
        },
    });
    // env_mod: src/env.zig, the portable environment-variable helper (ISS-0134).
    // Given as a named module — not a relative @import — anywhere it is needed
    // outside the main src/ module tree: Zig 0.16 forbids an @import that
    // escapes the importing file's module root, and both idp_config_mod and
    // identity_provider_mod below are rooted deeper than src/env.zig.
    const env_mod = b.createModule(.{
        .root_source_file = b.path("src/env.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const idp_config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/identity_provider.zig"),
        .target = target,
        .optimize = optimize,
        // ISS-0134: identity_provider.zig reads env vars via src/env.zig,
        // which needs libc's `environ` extern on non-Windows targets.
        .link_libc = true,
        .imports = &.{
            .{ .name = "portable_env", .module = env_mod },
        },
    });
    const identity_provider_mod = b.createModule(.{
        .root_source_file = b.path("src/identity/provider/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "idp_config", .module = idp_config_mod },
            .{ .name = "env", .module = env_mod },
        },
    });

    // expr_mod: src/expr evaluator — used by transition.zig (EXP-102) and DSL tests.
    const expr_mod = b.createModule(.{
        .root_source_file = b.path("src/expr/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transition_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/transition.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "expr", .module = expr_mod },
        },
    });

    // ---------------------------------------------------------------------------
    // ISS-0137 / GH #439 — OIDC + repository/wasm named modules (cluster C4a).
    //
    // These 15 modules existed only as file paths before this run: the OIDC
    // production files carry 44 in-file test blocks and the tests/unit/
    // test_oidc*.zig + tests/integration/oidc*.zig suites import them by the
    // names below, but no `b.createModule` declared any of them — so those
    // tests could not compile, and the production files' own tests were
    // reachable from no addTest root (root cause RC-3 of ISS-0137).
    //
    // Every file below is a valid standalone module root: verified that no
    // src/oidc/*.zig file reaches a sibling by relative path (all non-std
    // imports in that directory are named modules). Consequently the
    // Single-Owner Module Rule applies — src/oidc_test_root.zig must reach
    // these seven files by NAME, never by relative path, or Zig rejects the
    // compilation with "file exists in multiple modules".
    //
    // Declaration order matters: claim_mapping before jit_provisioning.
    // ---------------------------------------------------------------------------
    const claim_mapping_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/claim_mapping.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
        },
    });
    const jit_provisioning_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/jit_provisioning.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
            .{ .name = "claim_mapping", .module = claim_mapping_mod },
        },
    });
    const identity_stability_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/identity_stability.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
        },
    });
    const realm_tenant_binding_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/realm_tenant_binding.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
        },
    });
    const tenant_claim_source_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/tenant_claim_source.zig"),
        .target = target,
        .optimize = optimize,
    });
    const realm_provisioning_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/realm_provisioning.zig"),
        .target = target,
        .optimize = optimize,
    });
    const realm_deletion_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/realm_deletion.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
        },
    });
    // migration_helper.zig imports pool (line 2) and identity_provider (line 3) —
    // an empty .imports here would fail to compile.
    const oidc_migration_helper_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/migration_helper.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
            .{ .name = "identity_provider", .module = identity_provider_mod },
        },
    });
    // NOTE: src/identity/provider/oidc/jwks_cache.zig — NOT src/oidc/jwks.zig.
    // Two different files; conflating them was an error in the diagnosis.
    const jwks_cache_mod = b.createModule(.{
        .root_source_file = b.path("src/identity/provider/oidc/jwks_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    const oidc_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/verification_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    const realm_seed_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/realm_seed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const oidc_test_token_helper_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/test_token_helper.zig"),
        .target = target,
        .optimize = optimize,
    });
    const oidc_coexistence_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/coexistence_auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    // repository/mod.zig is the ONLY repository file that becomes a module root:
    // artifacts.zig and activation.zig reach canonicaliser.zig/artifacts.zig by
    // relative path, so they must stay plain members of this module.
    const repository_mod = b.createModule(.{
        .root_source_file = b.path("src/repository/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
        },
    });
    // src/wasm/ has zero @cImport and zero linkSystemLibrary; wasmtime_bindings.zig
    // declares only `extern struct` layout types, which need no link-time symbol.
    // So this module compiles and its tests run against pure-Zig stubs.
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vendor_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "expr", .module = expr_mod },
        .{ .name = "pool", .module = pool_root_mod },
        .{ .name = "transition", .module = transition_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "identity_provider", .module = identity_provider_mod },
        .{ .name = "tenant_context", .module = tenant_context_mod },
        .{ .name = "pipeline_context", .module = pipeline_context_mod },
        .{ .name = "obs_metrics", .module = obs_metrics_mod },
        .{ .name = "json_schema", .module = json_schema_mod },
        // ISS-0134: portable environment-variable access (src/env.zig).
        .{ .name = "env", .module = env_mod },
    };

    // ---------------------------------------------------------------------------
    // Main executable: `zig build`
    // ---------------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "bpm-platform",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = vendor_imports,
            // ISS-0134: src/main.zig transitively reaches src/env.zig (via
            // src/config.zig, src/admin/tenant_migration.zig, and others),
            // which needs libc's `environ` extern on non-Windows targets.
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // ---------------------------------------------------------------------------
    // `zig build run`
    // ---------------------------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Compile and run the BPM Platform server");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------------
    // `zig build test` — all unit tests under src/ and tests/unit/
    // ---------------------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = vendor_imports,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // ISS-0148: tests/unit/event_store_test.zig is a standalone test root, so it
    // cannot reach src/event_store/*.zig by relative @import ("import of file
    // outside module path"). Expose store.zig as a named module instead. Its own
    // named imports (pool / pipeline_context / obs_metrics) must be supplied at
    // this module's level; registry.zig is reached from store.zig by relative
    // path and so is a plain member of this module.
    const event_store_mod = b.createModule(.{
        .root_source_file = b.path("src/event_store/store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
            .{ .name = "pipeline_context", .module = pipeline_context_mod },
            .{ .name = "obs_metrics", .module = obs_metrics_mod },
            .{ .name = "json_schema", .module = json_schema_mod },
        },
    });
    const event_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/event_store_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "http", .module = http_mod },
                .{ .name = "expr", .module = expr_mod },
                .{ .name = "pool", .module = pool_root_mod },
                .{ .name = "transition", .module = transition_mod },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "identity_provider", .module = identity_provider_mod },
                .{ .name = "tenant_context", .module = tenant_context_mod },
                .{ .name = "pipeline_context", .module = pipeline_context_mod },
                .{ .name = "obs_metrics", .module = obs_metrics_mod },
                .{ .name = "json_schema", .module = json_schema_mod },
                .{ .name = "env", .module = env_mod },
                .{ .name = "event_store", .module = event_store_mod },
            },
        }),
    });
    const run_event_store_tests = b.addRunArtifact(event_store_tests);

    // ISS-0155 / GH #473: json_schema.zig is now a named module (so both
    // src/main.zig and src/event_store/registry.zig can reach the same file),
    // which removed it from `root`'s file set and therefore from every existing
    // addTest root. It is pure and import-free, so it is its own test root here
    // — otherwise its EE-09 and ES-05 test blocks would compile but never run,
    // exactly the ISS-0133 failure mode lint_test_wiring.py exists to catch.
    const json_schema_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/json_schema.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_json_schema_tests = b.addRunArtifact(json_schema_tests);

    // ISS-0160 / GH #481: src/entities/ is reached from src/main.zig only via
    // api/routes/entities.zig, which imports definition.zig and commands.zig
    // directly — validator.zig's own test blocks were therefore in NO addTest
    // root's file set and never ran. Verified with a deliberately-failing
    // canary test: `zig build test` stayed green at 63/63 with it present,
    // which is precisely the ISS-0133 failure mode.
    //
    // validator.zig is its own root rather than mod.zig: mod.zig transitively
    // reaches ../repository/canonicaliser.zig (via definition.zig), which
    // escapes the src/entities/ module path and makes it unusable as a test
    // root ("import of file outside module path"). validator.zig is pure and
    // needs only json_schema, so it stands alone.
    const entities_validator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entities/validator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json_schema", .module = json_schema_mod },
            },
        }),
    });
    const run_entities_tests = b.addRunArtifact(entities_validator_tests);
    // ISS-0147 / GitHub #374: Python interpreter resolver shared by the
    // integration linter tests (tnt_schema_isolation_test.zig) and its own unit
    // tests. Lives in tests/support/ rather than tests/integration/ because it
    // is a helper, not a test file, and because Zig forbids importing across
    // module roots — a named module is what lets both callers reach it.
    const python_interp_mod = b.createModule(.{
        .root_source_file = b.path("tests/support/python_interp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "env", .module = env_mod },
        },
    });

    // Unit tests for the resolver. Needs no database, so it belongs in the
    // `test` group rather than `test-integration`. Wired here deliberately: an
    // unreferenced test-bearing file reports green while running nothing (see
    // `zig build test-wiring-check`).
    const python_interp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/python_interp_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "python_interp", .module = python_interp_mod },
            },
        }),
    });
    const run_python_interp_tests = b.addRunArtifact(python_interp_tests);
    run_python_interp_tests.setCwd(b.path("."));

    const graph_mod = b.createModule(.{
        .root_source_file = b.path("src/definition/graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    // PD-02/PD-05/PD-06 graph validation unit tests, aggregated into one
    // compile unit via tests/unit/graph_test_root.zig. Reduces this group
    // from 3 separate zig-test compilations to 1 — see ISS-0136 for why
    // shrinking the total number of independent zig-test binaries matters
    // (concurrent -lc compiles trigger an upstream Zig cache-lock deadlock).
    // None of these three files link libc, so this group doesn't reduce
    // that count directly, but establishes the aggregator pattern used by
    // the libc-linked groups below.
    const graph_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/graph_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph", .module = graph_mod },
            },
        }),
    });
    const run_graph_tests = b.addRunArtifact(graph_tests);
    const test_graph_step = b.step("test-graph", "Run PD-02/PD-05/PD-06 graph validation unit tests only");
    test_graph_step.dependOn(&run_graph_tests.step);

    // PD-07 definition retrieval handler tests (pure input-validation paths).
    // src/main.zig is used as the named-module root so that definitions.zig
    // can resolve its relative @import("../../definition/store.zig") within
    // the src/ tree — Zig 0.16 forbids @imports that escape the module root.
    const bpm_main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = vendor_imports,
        // ISS-0134: transitively reaches src/env.zig; see the exe definition above.
        .link_libc = true,
    });

    // bpm_src_mod: src/bpm.zig re-export shim used by engine unit tests and
    // integration tests.  Exports .engine, .tasks, .pool, .definition, etc.
    const bpm_src_mod = b.createModule(.{
        .root_source_file = b.path("src/bpm.zig"),
        // ISS-0134: transitively reaches src/env.zig; see the exe definition above.
        .link_libc = true,
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
            .{ .name = "cel", .module = cel_mod },
            .{ .name = "expr", .module = expr_mod },
            .{ .name = "pool", .module = pool_root_mod },
            .{ .name = "tenant_context", .module = tenant_context_mod },
            .{ .name = "pipeline_context", .module = pipeline_context_mod },
            .{ .name = "obs_metrics", .module = obs_metrics_mod },
            .{ .name = "json_schema", .module = json_schema_mod },
            // identity_provider added so integration tests can call route handlers
            // that reference auth.getIdentityProviderManager() (e.g. handlePatchTenant).
            .{ .name = "identity_provider", .module = identity_provider_mod },
            // ISS-0137 / GH #439: src/api/routes/onboarding.zig line 3 imports
            // build_options. Reachable through bpm once oidc35_onboarding_test
            // is wired into main_test.zig.
            .{ .name = "build_options", .module = build_options_mod },
            // ISS-0134: portable environment-variable access (src/env.zig).
            .{ .name = "env", .module = env_mod },
            // ISS-0147 / GH #463: src/wasm (WASM-01..14, all RELEASED) was
            // re-exported by neither bpm.zig nor main.zig, so no production
            // build path compiled it. Passed BY NAME — src/wasm/*.zig reach
            // each other by relative path and are therefore owned solely by
            // wasm_mod; a relative @import from bpm.zig would trip the
            // Single-Owner Module Rule. See the comment in src/bpm.zig.
            .{ .name = "wasm", .module = wasm_mod },
        },
    });

    // bpm_src_mod unit test group, aggregated into one compile unit via
    // tests/unit/bpm_src_test_root.zig. Part of the ISS-0136 mitigation
    // (see graph_test_root.zig commit for full rationale): bpm_src_mod is
    // libc-linked, so collapsing 8 targets into 1 directly reduces the
    // concurrent -lc compile-job count. engine_test.zig also uses
    // bpm_src_mod but is kept standalone — see bpm_src_test_root.zig for why.
    const bpm_src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/bpm_src_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_bpm_src_tests = b.addRunArtifact(bpm_src_tests);
    const test_bpm_src_step = b.step("test-bpm-src", "Run db/EE-11/scheduler/EXT-01/EXT-03/effects unit tests only");
    test_bpm_src_step.dependOn(&run_bpm_src_tests.step);

    // bpm_main_mod unit test group, aggregated into one compile unit via
    // tests/unit/bpm_main_test_root.zig. Part of the ISS-0136 mitigation
    // (see graph_test_root.zig commit for full rationale): bpm_main_mod is
    // libc-linked, so collapsing 12 targets into 1 directly reduces the
    // concurrent -lc compile-job count — this is the largest group.
    const bpm_main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/bpm_main_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
                .{ .name = "build_options", .module = build_options_mod },
                // ISS-0134: definition_retrieval_test.zig's testDbUrl() helper
                // uses env.globalEnviron().
                .{ .name = "env", .module = env_mod },
            },
        }),
    });
    const run_bpm_main_tests = b.addRunArtifact(bpm_main_tests);
    const test_bpm_main_step = b.step("test-bpm-main", "Run PD-07/export-import/PD-10/EE-03/05/07/09/API-02/03/05/OBS-04 unit tests only");
    test_bpm_main_step.dependOn(&run_bpm_main_tests.step);

    const snapshot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_snapshot.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_snapshot_tests = b.addRunArtifact(snapshot_tests);

    // export-import, PD-10, and EE-03 apply tests are part of the
    // bpm_main_tests aggregator (tests/unit/bpm_main_test_root.zig)
    // declared above.

    // EE-03: TaskStore stubs (DB tests — all SkipZigTest until test-integration)
    const tasks_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_tasks_store.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tasks_store_tests = b.addRunArtifact(tasks_store_tests);

    // EE-03 tasks API, EE-05, EE-07, and EE-09 are part of the
    // bpm_main_tests aggregator declared above.

    // EE-11 (reconstruction_test.zig) is part of the bpm_src_tests
    // aggregator (tests/unit/bpm_src_test_root.zig) declared above.

    // API-01: REST conventions unit tests (pure functions — no DB, no network)
    // Single-module root avoids "file exists in two modules" conflicts
    // (errors.zig is imported by relative path in both content_type.zig and response.zig).
    //
    // pool.zig is provided as a named import so that auth.zig (inside the api
    // module) can reference the Pool type without escaping the module root.
    const pool_module = b.createModule(.{
        .root_source_file = b.path("src/db/pool.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
            .{ .name = "tenant_context", .module = tenant_context_mod },
            .{ .name = "pipeline_context", .module = pipeline_context_mod },
            .{ .name = "obs_metrics", .module = obs_metrics_mod },
            .{ .name = "json_schema", .module = json_schema_mod },
        },
    });
    const api_mod = b.createModule(.{
        .root_source_file = b.path("src/api/api_mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
            .{ .name = "identity_provider", .module = identity_provider_mod },
            .{ .name = "tenant_context", .module = tenant_context_mod },
            .{ .name = "pipeline_context", .module = pipeline_context_mod },
            .{ .name = "obs_metrics", .module = obs_metrics_mod },
            .{ .name = "json_schema", .module = json_schema_mod },
        },
    });
    // API-01/API-06/API-07/API-09/OIDC-01 unit tests, aggregated into one
    // compile unit via tests/unit/api_test_root.zig. Part of the ISS-0136
    // mitigation (see graph_test_root.zig for the full rationale): this
    // group's api_mod is libc-linked, so collapsing 6 targets into 1
    // directly reduces the concurrent -lc compile-job count.
    const api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/api_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
            },
        }),
    });
    const run_api_tests = b.addRunArtifact(api_tests);
    const test_api_step = b.step("test-api", "Run API-01/06/07/09 and OIDC-01 unit tests only");
    test_api_step.dependOn(&run_api_tests.step);

    // API-02, API-03, API-05, and OBS-04 are part of the bpm_main_tests
    // aggregator declared above.

    // API-06 and API-07 unit tests are part of the api_tests aggregator
    // (tests/unit/api_test_root.zig) declared above.

    // API-08: Bearer token auth middleware unit tests (pure early-return paths — no DB)
    // Uses the api_mod shim (src/api/api_mod.zig) to import auth.zig.
    // pool_module is provided so that auth.zig's @import("pool") resolves.
    // provisioning_mod_api08: src/db/provisioning.zig wired to pool_module so
    // that test_api08_auth.zig can call provisionTenantSchema without creating
    // a duplicate pool-module conflict (pool_module vs pool_root_mod).
    const migrations_mod_api08 = b.createModule(.{
        .root_source_file = b.path("src/db/migrations.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
        },
    });
    const provisioning_mod_api08 = b.createModule(.{
        .root_source_file = b.path("src/db/provisioning.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
            .{ .name = "tenant_context", .module = tenant_context_mod },
        },
    });

    const api08_auth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_api08_auth.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
                .{ .name = "pool", .module = pool_module },
                .{ .name = "provisioning", .module = provisioning_mod_api08 },
                .{ .name = "migrations", .module = migrations_mod_api08 },
                // GH-542 / ISS-0607: must share `build_options_mod` (not
                // `build_options.createModule()`) so that pg_mod's transitive
                // `build_options` import resolves to the same module. Two
                // distinct `build_options` modules pointing at the same
                // options.zig causes "file exists in modules 'build_options'
                // and 'build_options0'" compile errors.
                .{ .name = "build_options", .module = build_options_mod },
                // ISS-0134: testDbUrl() helper uses env.globalEnviron().
                .{ .name = "env", .module = env_mod },
            },
        }),
    });
    const run_api08_auth_tests = b.addRunArtifact(api08_auth_tests);

    // API-09 and OIDC-01 (both boundary and stub) unit tests are part of the
    // api_tests aggregator (tests/unit/api_test_root.zig) declared above.

    const oidc02_keycloak_adapter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/identity/provider/test_oidc02_keycloak_adapter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_oidc02_keycloak_adapter_tests = b.addRunArtifact(oidc02_keycloak_adapter_tests);

    // SCH-05/SCH-06/SCH-302 are part of the bpm_src_tests aggregator
    // (tests/unit/bpm_src_test_root.zig) declared above.

    // SCH-303: Timer DLQ unit tests (migration file presence + source inspection, no DB)
    // NOT part of the bpm_src_tests aggregator: this file has no imports at
    // all (unlike the rest of the group, which all import bpm_src_mod) and
    // needs setCwd — structurally different, kept standalone.
    const sch303_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/sch303_timer_dlq_unit_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    const run_sch303_unit_tests = b.addRunArtifact(sch303_unit_tests);
    run_sch303_unit_tests.setCwd(b.path("."));

    // EXT-01 (service_task_test.zig) and EXT-03 (ext03_plugin_test.zig) are
    // part of the bpm_src_tests aggregator declared above.

    // EXP-701: static sandbox threat model document gate checks (no DB, no network)
    const exp701_doc_embed_mod = b.createModule(.{
        .root_source_file = b.path("docs/exp701_doc_embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exp701_sandbox_threatmodel_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/exp701_sandbox_threatmodel_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "exp701_doc_embed", .module = exp701_doc_embed_mod },
            },
        }),
    });
    const run_exp701_sandbox_threatmodel_tests = b.addRunArtifact(exp701_sandbox_threatmodel_tests);

    // ---------------------------------------------------------------------------
    // DSL-01: Expression DSL parser unit tests (pure — no DB, no network)
    // Tests live in src/expr/parser.zig
    // expr_mod is declared at the top of build() (moved for EXP-102 module wiring).
    // ---------------------------------------------------------------------------
    const dsl01_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/expr/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_dsl01_parser_tests = b.addRunArtifact(dsl01_parser_tests);

    // DSL-03: Error recovery unit tests (pure — no DB, no network)
    const expr_error_recovery_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/expr_error_recovery_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "expr", .module = expr_mod },
            },
        }),
    });
    const run_expr_error_recovery_tests = b.addRunArtifact(expr_error_recovery_tests);

    // DSL-04: Expression value/evaluation unit tests (pure — no DB, no network)
    const dsl04_eval_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/expr/mod.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_dsl04_eval_tests = b.addRunArtifact(dsl04_eval_tests);

    // `zig build test-expr` — DSL expr tests only
    const test_expr_step = b.step("test-expr", "Run Expression DSL unit tests");
    test_expr_step.dependOn(&run_dsl01_parser_tests.step);
    test_expr_step.dependOn(&run_expr_error_recovery_tests.step);
    test_expr_step.dependOn(&run_dsl04_eval_tests.step);

    // ---------------------------------------------------------------------------
    // `zig build test-engine` — engine unit tests only
    // ---------------------------------------------------------------------------
    const engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/engine_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_engine_tests = b.addRunArtifact(engine_tests);
    const test_engine_step = b.step("test-engine", "Run engine unit tests");
    test_engine_step.dependOn(&run_engine_tests.step);

    // ISS-0132 / GH #428: src/engine/transition.zig contains 30 in-file tests
    // (plus the allocation-failure harness) that were inert for months — the
    // file was only ever referenced as an imported module (`transition_mod`),
    // never as the root of an addTest, so `zig build test` compiled it but ran
    // none of its tests. Same class as ISS-0102 (test files wired into no
    // build target), in the engine's purest and most safety-critical module.
    //
    // transition.zig cannot be its own addTest root: it reaches
    // ../definition/graph.zig by relative path, and Zig 0.16 rejects an
    // @import that escapes the module root. bpm.zig doesn't work either —
    // Zig only runs test blocks in files reachable through *analyzed*
    // declarations, and bpm.zig has neither a `test` block nor
    // std.testing.refAllDecls, so that target would compile and silently run
    // zero tests. src/transition_test_root.zig is a thin shim sitting at
    // src/ (not src/engine/) specifically to satisfy the module-root
    // constraint while still calling refAllDecls on the transition module —
    // see that file's own doc comment for the full explanation.
    //
    // All 30 tests now pass with zero leaks and zero crashes (fixed under
    // GH #428: two production ownership bugs — transition()'s token
    // deep-clone dropped waiting_child_instance_id, and three
    // processNodeEntry paths (END completion, ALL_BRANCHES_CANCELLED
    // cascade, PARALLEL_GATEWAY join fire) discarded tokens without freeing
    // them — plus one stale test assertion and a batch of test fixtures that
    // built InstanceState from string literals/stack arrays instead of
    // allocator-owned memory).
    const transition_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transition_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "expr", .module = expr_mod },
            },
        }),
    });
    const run_transition_tests = b.addRunArtifact(transition_tests);
    const test_transition_step = b.step(
        "test-transition",
        "Run src/engine/transition.zig in-file unit tests (incl. ISS-0132 alloc-failure harness)",
    );
    test_transition_step.dependOn(&run_transition_tests.step);
    test_engine_step.dependOn(&run_transition_tests.step);

    // ISS-0132 / GH #427: src/definition/store.zig had ZERO test blocks and was
    // reachable from no addTest root, so parseGraphJson's allocation-failure
    // paths had never executed — GH #406 patched one leak there and the
    // signature recurred. Same inert-file class as the transition wiring above.
    // src/definition_store_test_root.zig is a refAllDecls shim at src/ (not
    // src/definition/) to satisfy the module-root constraint; see its doc
    // comment. The ISS-0132 tests it exposes are pure (no DB connection), so
    // this target needs no BPM_TEST_DB_URL and is safe under `zig build test`.
    const definition_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/definition_store_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pool", .module = pool_root_mod },
            },
        }),
    });
    const run_definition_store_tests = b.addRunArtifact(definition_store_tests);
    const test_definition_store_step = b.step(
        "test-definition-store",
        "Run src/definition/store.zig in-file unit tests (ISS-0132 alloc-failure harness)",
    );
    test_definition_store_step.dependOn(&run_definition_store_tests.step);
    test_engine_step.dependOn(&run_definition_store_tests.step);

    // ISS-0074: secrets/crypto.zig envelope-encryption unit tests (pure — no DB, no network)
    const secrets_crypto_mod = b.createModule(.{
        .root_source_file = b.path("src/secrets/crypto.zig"),
        .target = target,
        .optimize = optimize,
    });
    const crypto_iss0074_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/crypto_iss0074_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "secrets_crypto", .module = secrets_crypto_mod },
            },
        }),
    });
    const run_crypto_iss0074_tests = b.addRunArtifact(crypto_iss0074_tests);
    const test_crypto_iss0074_step = b.step("test-crypto-iss0074", "Run ISS-0074 secrets/crypto.zig unit tests");
    test_crypto_iss0074_step.dependOn(&run_crypto_iss0074_tests.step);

    // ---------------------------------------------------------------------------
    // ISS-0137 / GH #439 — nine targets clearing the unwired-test backlog.
    //
    // These wire in 141 test blocks that had never executed. Each group gets its
    // own narrow `test-<name>` step, not just a `test` edge: when a batch of
    // never-executed tests runs for the first time, failures must be attributable
    // to one group rather than arriving as one unreadable red wall.
    //
    // Every target here is service-free — no Postgres, no Keycloak — so the
    // Green-Main Gate (`zig build test` passes with no services up) holds. The
    // DB/Keycloak half of ISS-0137's backlog is wired through
    // tests/integration/main_test.zig instead, behind test-integration.
    // ---------------------------------------------------------------------------
    const core_modules_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_modules_test_root.zig"),
            .target = target,
            .optimize = optimize,
            // ISS-0134: src/env.zig needs libc's `environ` extern on non-Windows.
            .link_libc = true,
            // Deliberately NO .imports here: see the shim's doc comment. Passing
            // tenant_context_mod/env_mod/etc. as named modules would put those
            // files in a SECOND module alongside this one and Zig would reject
            // the compilation with "file exists in multiple modules".
        }),
    });
    const run_core_modules_tests = b.addRunArtifact(core_modules_tests);
    const test_core_modules_step = b.step(
        "test-core-modules",
        "Run in-file tests of tenant_context, pipeline_context, obs/metrics and env",
    );
    test_core_modules_step.dependOn(&run_core_modules_tests.step);

    const config_idp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config_idp_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                // identity_provider.zig's own named import. NOT idp_config_mod:
                // that module is rooted at the very file whose tests this target
                // collects, and supplying it would put the file in two modules.
                //
                // A PRIVATE env module instance, not the shared env_mod: Zig
                // deduplicates modules by identity, so binding the shared
                // env_mod under the extra name `portable_env` here rewrites it
                // for every other consumer too — which turned every
                // `@import("env")` in the integration suite into
                // `env=portable_env` and broke tests/integration/helpers.zig.
                .{ .name = "portable_env", .module = b.createModule(.{
                    .root_source_file = b.path("src/env.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }) },
            },
        }),
    });
    const run_config_idp_tests = b.addRunArtifact(config_idp_tests);
    const test_config_idp_step = b.step(
        "test-config-idp",
        "Run src/config/identity_provider.zig in-file unit tests",
    );
    test_config_idp_step.dependOn(&run_config_idp_tests.step);

    const oidc_src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oidc_test_root.zig"),
            .target = target,
            .optimize = optimize,
            // Only `pool` — the six collected files' own named import. Passing
            // claim_mapping_mod et al. would make those files members of two
            // modules at once AND stop their tests being enrolled at all.
            .imports = &.{
                .{ .name = "pool", .module = pool_root_mod },
            },
        }),
    });
    const run_oidc_src_tests = b.addRunArtifact(oidc_src_tests);
    const test_oidc_src_step = b.step(
        "test-oidc-src",
        "Run six src/oidc/*.zig production files' in-file unit tests",
    );
    test_oidc_src_step.dependOn(&run_oidc_src_tests.step);

    // jit_provisioning.zig needs its own target: it imports `claim_mapping` by
    // name, and claim_mapping.zig is a relative member of oidc_src_tests above.
    // One compilation cannot hold both roles for the same file.
    const oidc_jit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oidc_jit_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pool", .module = pool_root_mod },
                .{ .name = "claim_mapping", .module = claim_mapping_mod },
            },
        }),
    });
    const run_oidc_jit_tests = b.addRunArtifact(oidc_jit_tests);
    const test_oidc_jit_step = b.step(
        "test-oidc-jit",
        "Run src/oidc/jit_provisioning.zig in-file unit tests",
    );
    test_oidc_jit_step.dependOn(&run_oidc_jit_tests.step);

    const repository_src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/repository_test_root.zig"),
            .target = target,
            .optimize = optimize,
            // Only `pool`. repository_mod is rooted at the very mod.zig this
            // shim reaches relatively; supplying it would put those files in two
            // modules and stop their tests being enrolled.
            .imports = &.{
                .{ .name = "pool", .module = pool_root_mod },
            },
        }),
    });
    const run_repository_src_tests = b.addRunArtifact(repository_src_tests);
    const test_repository_src_step = b.step(
        "test-repository-src",
        "Run src/repository/*.zig in-file unit tests",
    );
    test_repository_src_step.dependOn(&run_repository_src_tests.step);

    const simulation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simulation_test_root.zig"),
            .target = target,
            .optimize = optimize,
            // simulation/types.zig and tenant_store.zig both reach
            // ../event_store/store.zig by RELATIVE path, so store.zig is a plain
            // member of this shim's own module — and its four named imports must
            // therefore be supplied at this module's level, not inherited from
            // anywhere. Design §2.5 anticipated exactly this ("BACKEND-DEV adds
            // whatever named imports the compiler demands and records them");
            // these four are the complete set demanded.
            .imports = &.{
                .{ .name = "pool", .module = pool_root_mod },
                .{ .name = "tenant_context", .module = tenant_context_mod },
                .{ .name = "pipeline_context", .module = pipeline_context_mod },
                .{ .name = "obs_metrics", .module = obs_metrics_mod },
                .{ .name = "json_schema", .module = json_schema_mod },
            },
        }),
    });
    const run_simulation_tests = b.addRunArtifact(simulation_tests);
    const test_simulation_step = b.step(
        "test-simulation",
        "Run src/simulation/*.zig in-file unit tests",
    );
    test_simulation_step.dependOn(&run_simulation_tests.step);

    const idp_bootstrap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/identity/provider/idp_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "env", .module = env_mod },
                .{ .name = "idp_config", .module = idp_config_mod },
            },
        }),
    });
    const run_idp_bootstrap_tests = b.addRunArtifact(idp_bootstrap_tests);
    const test_idp_bootstrap_step = b.step(
        "test-idp-bootstrap",
        "Run src/identity/provider/bootstrap.zig in-file unit tests",
    );
    test_idp_bootstrap_step.dependOn(&run_idp_bootstrap_tests.step);

    const oidc_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/oidc_unit_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "jwks_cache", .module = jwks_cache_mod },
                .{ .name = "claim_mapping", .module = claim_mapping_mod },
                .{ .name = "oidc_bench", .module = oidc_bench_mod },
                .{ .name = "realm_seed", .module = realm_seed_mod },
                .{ .name = "oidc_test_token_helper", .module = oidc_test_token_helper_mod },
                .{ .name = "oidc_coexistence", .module = oidc_coexistence_mod },
                .{ .name = "pool", .module = pool_root_mod },
            },
        }),
    });
    const run_oidc_unit_tests = b.addRunArtifact(oidc_unit_tests);
    // REQUIRED: test_oidc28 and test_oidc32 read docker-compose.yml and
    // infrastructure/keycloak/realms/*.json from disk via Dir.cwd().
    run_oidc_unit_tests.setCwd(b.path("."));
    const test_oidc_unit_step = b.step(
        "test-oidc-unit",
        "Run the eight tests/unit/test_oidc*.zig unit test files",
    );
    test_oidc_unit_step.dependOn(&run_oidc_unit_tests.step);

    const repository_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/repository_unit_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "repository", .module = repository_mod },
                .{ .name = "pool", .module = pool_root_mod },
            },
        }),
    });
    const run_repository_unit_tests = b.addRunArtifact(repository_unit_tests);
    const test_repository_unit_step = b.step(
        "test-repository-unit",
        "Run tests/unit/repository_*.zig unit test files",
    );
    test_repository_unit_step.dependOn(&run_repository_unit_tests.step);

    // ISS-0153 / GH #471 — src/lua/ (LUA-01..16) was reachable from no addTest
    // root and had not compiled since Zig 0.10. This target is what makes the
    // subsystem type-checked on every `zig build test`.
    //
    // Rooted at `src/lua_test_root.zig`, NOT at src/lua/mod.zig, and that
    // placement is load-bearing (Single-Owner Module Rule, design
    // §1.2 / src/design/test-wiring-iss0137.md): host_api/call_service.zig and
    // host_api/now.zig import `../../simulation/*.zig`, escaping src/lua/, and
    // src/simulation/types.zig in turn imports `../event_store/store.zig`. A
    // module rooted inside src/lua/ would reject those as "import of file
    // outside module path" (verified empirically). Rooting at src/ contains the
    // whole chain — identical to the constraint that placed
    // src/simulation_test_root.zig and src/transition_test_root.zig at src/.
    //
    // The four named imports below are the set src/event_store/store.zig
    // demands, exactly as src/simulation_test_root.zig's module needs them for
    // the same reason.
    //
    // link_libc: src/lua/executor.zig's defaultAlloc uses std.c.malloc/realloc/
    // free — the C-ABI allocator LuaJIT requires.
    //
    // ISS-0161 / GH #485: LuaJIT is now vendored and statically linked (LUA-01),
    // so src/lua/luajit_bindings.zig @cImports the real lua.h and the stubs are
    // gone. See vendor/luajit/build.zig.
    const luajit_lib = luajit_build.addLuaJit(b, target, optimize);

    const lua_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "pool", .module = pool_root_mod },
                .{ .name = "tenant_context", .module = tenant_context_mod },
                .{ .name = "pipeline_context", .module = pipeline_context_mod },
                .{ .name = "obs_metrics", .module = obs_metrics_mod },
                .{ .name = "json_schema", .module = json_schema_mod },
            },
        }),
    });
    // ISS-0161: link the static LuaJIT archive and expose lua.h to @cImport.
    lua_tests.root_module.linkLibrary(luajit_lib);
    lua_tests.root_module.addIncludePath(luajit_build.luajitIncludePath(b));

    const run_lua_tests = b.addRunArtifact(lua_tests);
    const test_lua_step = b.step(
        "test-lua",
        "Run src/lua/*.zig in-file unit tests (ISS-0153, ISS-0161)",
    );
    test_lua_step.dependOn(&run_lua_tests.step);

    const misc_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/misc_unit_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wasm", .module = wasm_mod },
            },
        }),
    });
    const run_misc_unit_tests = b.addRunArtifact(misc_unit_tests);
    const test_misc_unit_step = b.step(
        "test-misc-unit",
        "Run tests/unit/lua_test.zig and wasm_executor_test.zig",
    );
    test_misc_unit_step.dependOn(&run_misc_unit_tests.step);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_bpm_src_tests.step);
    test_step.dependOn(&run_crypto_iss0074_tests.step);
    // EXP-301/302/303 (effects/test_effects.zig) is part of the
    // bpm_src_tests aggregator declared above.

    test_step.dependOn(&run_event_store_tests.step);
    test_step.dependOn(&run_json_schema_tests.step);
    test_step.dependOn(&run_entities_tests.step); // ISS-0160 / GH #481
    test_step.dependOn(&run_python_interp_tests.step);
    test_step.dependOn(&run_graph_tests.step);
    test_step.dependOn(&run_bpm_main_tests.step);
    test_step.dependOn(&run_snapshot_tests.step);
    test_step.dependOn(&run_tasks_store_tests.step);
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_transition_tests.step);
    // ISS-0132 / GH #427: attach the store.zig alloc-failure harness to the
    // aggregate step, not only to its narrow `test-definition-store` step — an
    // opt-in step nothing invokes means the tests never run, which is the exact
    // defect (ISS-0150 / GH #466) that tools/lint_test_wiring.py guards, and the
    // same inert-test class ISS-0132 itself exists to end.
    test_step.dependOn(&run_definition_store_tests.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_api08_auth_tests.step);
    test_step.dependOn(&run_oidc02_keycloak_adapter_tests.step);
    test_step.dependOn(&run_sch303_unit_tests.step);
    test_step.dependOn(&run_exp701_sandbox_threatmodel_tests.step);
    test_step.dependOn(&run_dsl01_parser_tests.step);
    test_step.dependOn(&run_expr_error_recovery_tests.step);
    test_step.dependOn(&run_dsl04_eval_tests.step);

    // ISS-0137 / GH #439 — the nine backlog-clearing targets declared above.
    test_step.dependOn(&run_core_modules_tests.step);
    test_step.dependOn(&run_config_idp_tests.step);
    test_step.dependOn(&run_oidc_src_tests.step);
    test_step.dependOn(&run_oidc_jit_tests.step);
    test_step.dependOn(&run_repository_src_tests.step);
    test_step.dependOn(&run_simulation_tests.step);
    test_step.dependOn(&run_idp_bootstrap_tests.step);
    test_step.dependOn(&run_oidc_unit_tests.step);
    test_step.dependOn(&run_repository_unit_tests.step);
    test_step.dependOn(&run_misc_unit_tests.step);
    // ISS-0153 / GH #471 — src/lua subsystem.
    test_step.dependOn(&run_lua_tests.step);

    // ---------------------------------------------------------------------------
    // `zig build test-differential` — ISS-602 CEL/expr differential harness
    // ---------------------------------------------------------------------------
    const expr_diff_mod = b.createModule(.{
        .root_source_file = b.path("src/expr/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    // ISS-0157 / GH #476: TC-ISS-602-03's static import gate needs
    // src/engine/transition.zig's source bytes. `@embedFile` cannot reach
    // outside the embedding module's root, so the bytes come through a shim
    // colocated with the file (same pattern as docs/exp701_doc_embed.zig).
    const transition_source_embed_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/transition_source_embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const differential_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/differential/differential_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cel", .module = cel_mod },
                .{ .name = "expr", .module = expr_diff_mod },
                .{ .name = "transition_source_embed", .module = transition_source_embed_mod },
            },
        }),
    });
    // Allow @embedFile to resolve files in src/ and vendor/ from the differential test
    differential_tests.root_module.addIncludePath(b.path("."));
    const run_differential_tests = b.addRunArtifact(differential_tests);
    run_differential_tests.setCwd(b.path("."));
    const test_differential_step = b.step("test-differential", "Run CEL/expr differential corpus tests (ISS-602)");
    test_differential_step.dependOn(&run_differential_tests.step);
    // ISS-0157 / GH #476: the ISS-602 CEL/expr differential corpus was attached
    // only to the narrow `test-differential` step, so its 3 blocks never ran
    // under `zig build test` — and in fact never compiled (the @embedFile path
    // fix is in src/engine/transition_source_embed.zig). It is service-free
    // (pure CEL/expr evaluation plus a static source-text gate), so it belongs
    // on `test` rather than `test-integration` and keeps the Green-Main Gate's
    // no-services-required property intact.
    test_step.dependOn(&run_differential_tests.step);
    // ---------------------------------------------------------------------------
    // `zig build test-integration` — integration tests (requires BPM_TEST_DB_URL)
    // ---------------------------------------------------------------------------

    // bpm_src_mod is declared earlier (after bpm_main_mod) and is reused here.

    // ISS-0088: verify clean_test_db.py / helpers.zig resetTestData() only
    // reference table names that currently exist, so a future migration
    // rename/drop can't silently desync them again.
    const lint_test_table_refs = b.addSystemCommand(&.{ "python", "tools/lint_test_table_refs.py" });
    lint_test_table_refs.setCwd(b.path("."));
    const lint_test_table_refs_step = b.step("lint-test-table-refs", "Verify test cleanup tooling references only current table names");
    lint_test_table_refs_step.dependOn(&lint_test_table_refs.step);

    // Pre-cleanup: delete all rows from test DB tables before running tests.
    //
    // ISS-0148 (GitHub #477): this pair is declared HERE, ahead of the integration
    // run artifacts below, rather than after them as it was originally. Every
    // integration run artifact is now built through addIntegrationRun(), which
    // takes `clean_test_db` as its ordering predecessor, so the binding must be
    // in scope before the first such call. Moving the declaration changes nothing
    // about the steps themselves — `clean-test-db` and `lint-test-table-refs`
    // keep their names, actions and edges verbatim.
    const clean_test_db = b.addSystemCommand(&.{ "python", "tools/clean_test_db.py" });
    clean_test_db.setCwd(b.path("."));
    clean_test_db.step.dependOn(&lint_test_table_refs.step);
    const clean_test_db_step = b.step("clean-test-db", "Delete all test data (requires docker-compose)");
    clean_test_db_step.dependOn(&clean_test_db.step);

    const integration_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "cel", .module = cel_mod },
        .{ .name = "expr", .module = expr_mod },
        .{ .name = "pool", .module = pool_root_mod },
        .{ .name = "bpm", .module = bpm_src_mod },
        .{ .name = "build_options", .module = build_options_mod },
        // ISS-0147 / GitHub #374: deterministic Python interpreter resolution
        // for tests that spawn Python tooling as a subprocess.
        .{ .name = "python_interp", .module = python_interp_mod },
        // ISS-0134: ~90 tests/integration/*.zig files (plus tests/unit/
        // test_api08_auth.zig and definition_retrieval_test.zig) each carry
        // their own copy-pasted testDbUrl() helper using
        // std.process.Environ{ .block = .global }. That literal only
        // type-checks on Windows/WASI/freestanding; it fails every one of
        // these files on Linux. All are rewritten to call env.globalEnviron().
        .{ .name = "env", .module = env_mod },
        // ISS-0137 / GH #439 (cluster C4a): the nine tests/integration/oidc*.zig
        // files reach these modules by name. Because integration_imports is
        // shared by integration_tests, svc_integration_tests,
        // env_integration_tests and the ~35 dedicated roots, appending here is
        // the ONLY build.zig change those integration files need — no new
        // dedicated addTest roots, which is what keeps the ISS-0106 DDL race
        // eliminated by construction.
        .{ .name = "claim_mapping", .module = claim_mapping_mod },
        .{ .name = "jit_provisioning", .module = jit_provisioning_mod },
        .{ .name = "identity_stability", .module = identity_stability_mod },
        .{ .name = "realm_tenant_binding", .module = realm_tenant_binding_mod },
        .{ .name = "tenant_claim_source", .module = tenant_claim_source_mod },
        .{ .name = "realm_provisioning", .module = realm_provisioning_mod },
        .{ .name = "realm_deletion", .module = realm_deletion_mod },
        .{ .name = "oidc_migration_helper", .module = oidc_migration_helper_mod },
    };

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_integration_tests = addIntegrationRun(b, integration_tests, migrations_dir, clean_test_db);

    const xc04_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/xc04_kernel_determinism_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_xc04_integration_tests = addIntegrationRun(b, xc04_integration_tests, migrations_dir, clean_test_db);

    const stage11_sim_xc04_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/stage11_sim_xc04_aggregate_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_stage11_sim_xc04_integration_tests = addIntegrationRun(b, stage11_sim_xc04_integration_tests, migrations_dir, clean_test_db);

    const sim05_08_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/sim05_08_scenario_runner_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_sim05_08_integration_tests = addIntegrationRun(b, sim05_08_integration_tests, migrations_dir, clean_test_db);

    const obs03_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/obs03_audit_log_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_obs03_integration_tests = addIntegrationRun(b, obs03_integration_tests, migrations_dir, clean_test_db);

    const adm_ui_09_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/adm_ui_09_health_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_adm_ui_09_integration_tests = addIntegrationRun(b, adm_ui_09_integration_tests, migrations_dir, clean_test_db);

    const obs04_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/obs04_timeline_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_obs04_integration_tests = addIntegrationRun(b, obs04_integration_tests, migrations_dir, clean_test_db);

    const adp12_regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/adp12_default_tenant_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_adp12_regression_tests = addIntegrationRun(b, adp12_regression_tests, migrations_dir, clean_test_db);

    const tm_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/tm01_tenant_list_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_tm_integration_tests = addIntegrationRun(b, tm_integration_tests, migrations_dir, clean_test_db);

    const exp_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/entity_subsystem_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_exp_integration_tests = addIntegrationRun(b, exp_integration_tests, migrations_dir, clean_test_db);

    // ISS-0150 / GH #466: ENV-01 tenant-type-field cases. Reachable via
    // main_test.zig, but given its own addTest root and narrow step so the nine
    // blocks can be exercised on their own — the file spent months as an
    // assertion-free scaffold precisely because nothing ever ran it in
    // isolation where a vacuous PASS would have been noticeable.
    const env01_tt_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/env01_tenant_type_field_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_env01_tt_integration_tests = b.addRunArtifact(env01_tt_integration_tests);
    run_env01_tt_integration_tests.setCwd(b.path("."));
    run_env01_tt_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const spt01_iss0068_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/spt01_iss0068_onboarding_schema_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_spt01_iss0068_integration_tests = addIntegrationRun(b, spt01_iss0068_integration_tests, migrations_dir, clean_test_db);

    // ISS-0071: Onboarding realm-existence guard integration tests.
    const iss0071_realm_guard_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/onboarding_realm_guard_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0071_realm_guard_integration_tests = addIntegrationRun(b, iss0071_realm_guard_integration_tests, migrations_dir, clean_test_db);

    const tnt_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/tnt_schema_isolation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_tnt_integration_tests = addIntegrationRun(b, tnt_integration_tests, migrations_dir, clean_test_db);

    const tnt_backfill_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/tnt_backfill_export_cleanup_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_tnt_backfill_integration_tests = addIntegrationRun(b, tnt_backfill_integration_tests, migrations_dir, clean_test_db);

    const iss101_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss101_timers_failed_status_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss101_integration_tests = addIntegrationRun(b, iss101_integration_tests, migrations_dir, clean_test_db);

    const iss102_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss102_claim_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss102_integration_tests = addIntegrationRun(b, iss102_integration_tests, migrations_dir, clean_test_db);

    const iss103_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/audit_iss103_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss103_integration_tests = addIntegrationRun(b, iss103_integration_tests, migrations_dir, clean_test_db);

    const iss0091_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0091_harness_tracker_unification_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0091_integration_tests = addIntegrationRun(b, iss0091_integration_tests, migrations_dir, clean_test_db);

    const iss106_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss106_webhook_outbox_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss106_integration_tests = addIntegrationRun(b, iss106_integration_tests, migrations_dir, clean_test_db);

    const iss107_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss107_tenant_storage_mode_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss107_integration_tests = addIntegrationRun(b, iss107_integration_tests, migrations_dir, clean_test_db);

    // ISS-0605 / GH-537: regression test for the C4 schema-baseline self-heal.
    // Verifies that `_run_clean_test_db_sweep()` (the GH-443 / ISS-0140 orphan-row
    // DELETE sweep) runs before verify_schema_baseline.py --check-tenants, so the
    // legacy C4 failure mode — reporting orphan public.tenant rows forever
    // without removing them — is closed permanently.
    const iss0605_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0605_orphan_self_heal_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0605_integration_tests = addIntegrationRun(b, iss0605_integration_tests, migrations_dir, clean_test_db);

    // ISS-0607 / GH-542: regression test for the vendor/pg/pg.zig stderr
    // suppression gate. The mere fact that this binary reaches the
    // `expectError(error.ServerError, …)` assertion proves the fix —
    // pre-fix, the unconditional `std.debug.print("\nPOSTGRES ERROR: …")`
    // on every ErrorResponse caused zig test to abort the binary on
    // stderr before the assertion ran, breaking every negative-path
    // integration test in the repo.
    const iss0607_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0607_pg_stderr_suppression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0607_integration_tests = addIntegrationRun(b, iss0607_integration_tests, migrations_dir, clean_test_db);

    const iss105_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss105_token_model_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss105_integration_tests = addIntegrationRun(b, iss105_integration_tests, migrations_dir, clean_test_db);

    // ISS-502: SPT cutover transaction integration tests.
    const iss502_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss502_spt_cutover_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss502_integration_tests = addIntegrationRun(b, iss502_integration_tests, migrations_dir, clean_test_db);

    // ISS-503: GBL-084 RLS removal migration integration tests.
    const iss503_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/test_iss503_rls_removal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss503_integration_tests = addIntegrationRun(b, iss503_integration_tests, migrations_dir, clean_test_db);

    const iss202_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss202_merge_atomicity_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss202_integration_tests = addIntegrationRun(b, iss202_integration_tests, migrations_dir, clean_test_db);

    const iss203_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss203_idempotency_keys_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss203_integration_tests = addIntegrationRun(b, iss203_integration_tests, migrations_dir, clean_test_db);

    // ISS-207: Convergent EXECUTION_ERROR retry integration tests.
    const iss207_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss207_error_retry_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss207_integration_tests = addIntegrationRun(b, iss207_integration_tests, migrations_dir, clean_test_db);

    // ISS-208: Guard task completion against terminal instances integration tests.
    const iss208_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss208_task_guard_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss208_integration_tests = addIntegrationRun(b, iss208_integration_tests, migrations_dir, clean_test_db);

    // ISS-205: Webhook transactional outbox integration tests.
    const iss205_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss205_webhook_outbox_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss205_integration_tests = addIntegrationRun(b, iss205_integration_tests, migrations_dir, clean_test_db);

    // ISS-601: State Snapshots for Large-Instance Reconstruction integration tests.
    const iss601_integration_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "cel", .module = cel_mod },
        .{ .name = "pool", .module = pool_root_mod },
        .{ .name = "bpm", .module = bpm_src_mod },
        .{ .name = "build_options", .module = build_options_mod },
        // ISS-0137 / GH #439: tests/integration/helpers.zig line 13 does
        // @import("env") (ISS-0134's portable environ helper). Every other
        // integration target inherits it from integration_imports; this
        // hand-rolled slice omitted it, so this root could not compile the
        // helpers it depends on.
        .{ .name = "env", .module = env_mod },
    };
    const iss601_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss601_state_snapshots_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = iss601_integration_imports,
        }),
    });
    const run_iss601_integration_tests = addIntegrationRun(b, iss601_integration_tests, migrations_dir, clean_test_db);

    // ISS-0125: process definition snapshot FK cascade and cleanup-error propagation.
    const iss0125_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0125_cascade_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0125_integration_tests = addIntegrationRun(b, iss0125_integration_tests, migrations_dir, clean_test_db);

    // ISS-0122: Audit chain TEXT resource_id + non-UTF-8 resilience regression tests.
    // Migration 1107 wrapped the chain-hash pipeline in EXCEPTION blocks and
    // pre-normalises non-UTF-8 bytes in NEW.resource_id; this test exercises
    // the audit_entries BEFORE INSERT trigger directly with both ASCII and
    // intentionally-malformed-UTF-8 byte sequences (0xAA via the canonical
    // convert_from(decode('e2aaaa','hex'),'UTF8') pattern).
    const iss0122_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/audit_chain_utf8_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0122_integration_tests = addIntegrationRun(b, iss0122_integration_tests, migrations_dir, clean_test_db);

    // ISS-0121: TestHarness per-test UUID isolation helper regression tests
    // (GitHub #387). Pins the contract for `h.newUuid()` and
    // `h.newUuidString(allocator)` so a future refactor of the helpers or
    // `bpm.uuid` cannot silently break the 258+ T010 migration sites
    // documented in src/design/iss0121_per_test_uuids.md.
    const iss0121_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0121_uuid_helpers_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0121_integration_tests = addIntegrationRun(b, iss0121_integration_tests, migrations_dir, clean_test_db);

    // ISS-0129 / GitHub #419: migration-runner pg_advisory_xact_lock
    // regression. Verifies that concurrent runForSchema() / provisionTenantSchema
    // calls serialize via the canonical migrate-step advisory lock
    // (`bpm.migrations.runForSchema`), that the lock keyspace is disjoint from
    // the audit-trigger's per-tenant advisory lock, and that the lock-key
    // prefix remains stable in src/db/migrations.zig. See
    // src/design/iss0129_migration_runner_advisory_lock.md.
    const iss0129_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0129_migration_run_advisory_lock_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0129_integration_tests = addIntegrationRun(b, iss0129_integration_tests, migrations_dir, clean_test_db);

    // ISS-0602 / GitHub #414: per-process owner tag for killIdleConnections().
    // Single-process regression verifying the tag is set on every TestHarness
    // connection, that the cache is per-process, and that the
    // pid != pg_backend_pid() self-exclusion guard works.
    const iss0602_same_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0602_same_process_isolation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0602_same_integration_tests = addIntegrationRun(b, iss0602_same_integration_tests, migrations_dir, clean_test_db);

    // ISS-0602: cross-process SQL contract — killIdleConnections() predicate
    // application_name = $1 cannot match a sibling-tagged parked connection.
    const iss0602_cross_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0602_cross_process_isolation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0602_cross_integration_tests = addIntegrationRun(b, iss0602_cross_integration_tests, migrations_dir, clean_test_db);

    // ISS-0123: DLQ rename (Cluster B) + obs05 audit-trigger isolation (Cluster A) regression tests.
    const iss0123_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0123_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0123_integration_tests = addIntegrationRun(b, iss0123_integration_tests, migrations_dir, clean_test_db);

    // EPIC-3 (ISS-301, ISS-302, ISS-303): Scheduler concurrency and DLQ routing integration tests.
    const sch303_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/sch303_timer_dlq_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_sch303_integration_tests = addIntegrationRun(b, sch303_integration_tests, migrations_dir, clean_test_db);

    // ISS-0076: secrets table creation regression coverage (GitHub #335).
    const iss0076_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0076_secrets_table_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0076_integration_tests = addIntegrationRun(b, iss0076_integration_tests, migrations_dir, clean_test_db);

    const test_integration_step = b.step("test-integration", "Run integration tests (requires BPM_TEST_DB_URL)");
    test_integration_step.dependOn(&clean_test_db.step);

    // ISS-0106 (GitHub #364): barrier step aggregating every test-integration
    // sibling binary EXCEPT ISS-503 (tests/integration/test_iss503_rls_removal.zig).
    // ISS-503 opens its own raw pg.Conn and runs GBL-084's full DDL body
    // (AccessExclusiveLock-holding ALTER TABLE / DROP POLICY / DROP FUNCTION
    // statements) outside helpers.zig's advisory-lock machinery, so it must
    // never execute concurrently with any other DDL/migration-touching binary
    // in this group. This barrier has no action of its own — it is satisfied
    // once every other test-integration member below has finished — and
    // run_iss503_integration_tests.step is chained behind it (see below), so
    // the build runner can never start ISS-503 before the rest of the group
    // completes. See src/design/fix-ISS-0106.md for the full design.
    const test_integration_others_step = b.step("test-integration-others-internal", "Internal barrier — not intended for direct invocation");
    test_integration_others_step.dependOn(&run_integration_tests.step);
    test_integration_others_step.dependOn(&run_adm_ui_09_integration_tests.step);
    test_integration_others_step.dependOn(&run_spt01_iss0068_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0071_realm_guard_integration_tests.step);
    test_integration_others_step.dependOn(&run_tnt_integration_tests.step);
    test_integration_others_step.dependOn(&run_tnt_backfill_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss101_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss102_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0091_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss103_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss106_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss107_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0605_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0607_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss502_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss202_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss203_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss207_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss208_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss205_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss601_integration_tests.step);
    test_integration_others_step.dependOn(&run_sch303_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0076_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0602_same_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0602_cross_integration_tests.step);
    // ISS-0150 / GH #466: entity_subsystem_test.zig's Run artifact was created
    // and fully configured but attached to no step reachable from
    // `test-integration` — only to the narrow `test-integration-exp` step, which
    // nothing in CI invokes. It was therefore built and never run, and had in
    // fact not compiled since the TestHarness API it was written against
    // changed. lint_test_wiring.py could not see this because it proves a file
    // is reachable from an addTest ROOT, not that the root is ever executed;
    // that gap is now covered by the linter's unattached-run-artifact check.
    test_integration_others_step.dependOn(&run_exp_integration_tests.step);
    // ISS-0150 / GH #466: the ENV-01 tenant-type-field cases also run inside the
    // main_test.zig aggregate, but the dedicated artifact is attached here too so
    // `test-integration-env01-tt` is not the only thing that ever executes it —
    // a narrow opt-in step nothing invokes is what hid entity_subsystem_test.zig.
    test_integration_others_step.dependOn(&run_env01_tt_integration_tests.step);
    // ISS-0150 / GH #466: surfaced by the new unattached-run-artifact check in
    // tools/lint_test_wiring.py. Both of these had a narrow step and nothing
    // else, so their blocks never ran under `zig build test-integration`. Both
    // pass on first execution, so they are attached here directly. Two further
    // finds from the same check (iss105_token_model_test, differential_test) do
    // NOT pass on first run and are tracked as ISS-0157 rather than being
    // attached-and-left-red or quietly excluded.
    test_integration_others_step.dependOn(&run_xc04_integration_tests.step);
    test_integration_others_step.dependOn(&run_stage11_sim_xc04_integration_tests.step);
    // ISS-0157 / GH #476: the two remaining finds, now fixed and attached, which
    // empties the KNOWN_UNATTACHED ledger in tools/lint_test_wiring.py.
    // iss105_token_model_test passes 4/4 as written — its GIN-index assertion
    // creates the index it then asserts on, so it was never the real defect.
    test_integration_others_step.dependOn(&run_iss105_integration_tests.step);

    // ISS-0106: force ISS-503 to run only after the barrier above (i.e. after
    // every other test-integration sibling has finished), then re-attach it
    // to the umbrella step so `zig build test-integration` still runs it and
    // still surfaces its own pass/fail.
    //
    // IMPORTANT: a second, dedicated Step.Run artifact
    // (run_iss503_integration_tests_after_others) — NOT the shared
    // run_iss503_integration_tests used by test_integration_iss503_step (the
    // pre-existing narrow "zig build test-integration-iss503" step) — carries
    // the barrier ordering edge. run_iss503_integration_tests.step is shared
    // with that narrow step, and dependOn edges are a global property of a
    // Step in Zig's build graph: adding the barrier dependency straight onto
    // run_iss503_integration_tests.step would have made the narrow step
    // transitively pull in all ~19 other test-integration binaries too,
    // which violates this design's explicit non-goal of leaving
    // test-integration-iss503 unaffected. Running the same test binary a
    // second time via its own Run step keeps that edge scoped to
    // test_integration_step's own path only.
    const run_iss503_integration_tests_after_others = addIntegrationRun(b, iss503_integration_tests, migrations_dir, clean_test_db);
    run_iss503_integration_tests_after_others.step.dependOn(test_integration_others_step);
    test_integration_step.dependOn(&run_iss503_integration_tests_after_others.step);

    const test_integration_xc04_step = b.step("test-integration-xc04", "Run XC-04 integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_xc04_step.dependOn(&clean_test_db.step);
    test_integration_xc04_step.dependOn(&run_xc04_integration_tests.step);

    const test_integration_stage11_sim_xc04_step = b.step("test-integration-stage11-sim-xc04", "Run Stage 11 SIM-01..SIM-04 + XC-04 aggregate integration tests (requires BPM_TEST_DB_URL)");
    test_integration_stage11_sim_xc04_step.dependOn(&clean_test_db.step);
    test_integration_stage11_sim_xc04_step.dependOn(&run_stage11_sim_xc04_integration_tests.step);

    const test_integration_sim05_08_step = b.step("test-integration-sim05-08", "Run Stage 11 SIM-05..SIM-08 integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_sim05_08_step.dependOn(&clean_test_db.step);
    test_integration_sim05_08_step.dependOn(&run_sim05_08_integration_tests.step);

    const test_integration_obs03_step = b.step("test-integration-obs03", "Run OBS-03 integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_obs03_step.dependOn(&clean_test_db.step);
    test_integration_obs03_step.dependOn(&run_obs03_integration_tests.step);

    const test_integration_obs04_step = b.step("test-integration-obs04", "Run OBS-04 integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_obs04_step.dependOn(&clean_test_db.step);
    test_integration_obs04_step.dependOn(&run_obs04_integration_tests.step);

    const test_integration_iss0076_step = b.step("test-integration-iss0076", "Run ISS-0076 secrets table regression tests only (requires BPM_TEST_DB_URL)");
    test_integration_iss0076_step.dependOn(&run_iss0076_integration_tests.step);

    const test_adp12_regression_step = b.step("test-adp12-regression", "Run ADP-12 default-tenant pre/post regression suite");
    test_adp12_regression_step.dependOn(&clean_test_db.step);
    test_adp12_regression_step.dependOn(&run_adp12_regression_tests.step);

    const test_integration_tm_step = b.step("test-integration-tm", "Run TM integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_tm_step.dependOn(&clean_test_db.step);
    test_integration_tm_step.dependOn(&run_tm_integration_tests.step);

    const test_integration_iss502_step = b.step("test-integration-iss502", "Run ISS-502 SPT cutover integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_iss502_step.dependOn(&clean_test_db.step);
    test_integration_iss502_step.dependOn(&run_iss502_integration_tests.step);

    const test_integration_iss503_step = b.step("test-integration-iss503", "Run ISS-503 GBL-084 RLS removal integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_iss503_step.dependOn(&clean_test_db.step);
    test_integration_iss503_step.dependOn(&run_iss503_integration_tests.step);

    const test_integration_exp_step = b.step("test-integration-exp", "Run Entity Subsystem integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_exp_step.dependOn(&clean_test_db.step);
    test_integration_exp_step.dependOn(&run_exp_integration_tests.step);

    const test_integration_env01_tt_step = b.step("test-integration-env01-tt", "Run ENV-01 tenant type field integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_env01_tt_step.dependOn(&clean_test_db.step);
    test_integration_env01_tt_step.dependOn(&run_env01_tt_integration_tests.step);

    const test_integration_spt01_iss68_step = b.step("test-integration-spt01-iss68", "Run SPT-01 ISS-0068 integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_spt01_iss68_step.dependOn(&clean_test_db.step);
    test_integration_spt01_iss68_step.dependOn(&run_spt01_iss0068_integration_tests.step);

    const test_integration_iss0071_step = b.step("test-integration-iss0071", "Run ISS-0071 onboarding realm guard integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0071_step.dependOn(&clean_test_db.step);
    test_integration_iss0071_step.dependOn(&run_iss0071_realm_guard_integration_tests.step);

    const test_integration_tnt_step = b.step("test-integration-tnt", "Run TNT-01..04 schema isolation tests only (requires BPM_TEST_DB_URL)");
    test_integration_tnt_step.dependOn(&clean_test_db.step);
    test_integration_tnt_step.dependOn(&run_tnt_integration_tests.step);
    test_integration_tnt_step.dependOn(&run_tnt_backfill_integration_tests.step);

    const test_integration_iss101_step = b.step("test-integration-iss101", "Run ISS-101 timers.status FAILED constraint integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss101_step.dependOn(&clean_test_db.step);
    test_integration_iss101_step.dependOn(&run_iss101_integration_tests.step);

    const test_integration_iss102_step = b.step("test-integration-iss102", "Run ISS-102 tasks.claimed_by and real claim path integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss102_step.dependOn(&clean_test_db.step);
    test_integration_iss102_step.dependOn(&run_iss102_integration_tests.step);

    const test_integration_iss103_step = b.step("test-integration-iss103", "Run ISS-103 audit_entries.resource_id TEXT migration integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss103_step.dependOn(&clean_test_db.step);
    test_integration_iss103_step.dependOn(&run_iss103_integration_tests.step);

    const test_integration_iss0091_step = b.step("test-integration-iss0091", "Run ISS-0091 harness/canonical migration-tracker unification regression tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0091_step.dependOn(&clean_test_db.step);
    test_integration_iss0091_step.dependOn(&run_iss0091_integration_tests.step);

    const test_integration_iss106_step = b.step("test-integration-iss106", "Run ISS-106 webhook_deliveries outbox table-shape integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss106_step.dependOn(&clean_test_db.step);
    test_integration_iss106_step.dependOn(&run_iss106_integration_tests.step);

    const test_integration_iss107_step = b.step("test-integration-iss107", "Run ISS-107 tenant storage_mode integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss107_step.dependOn(&clean_test_db.step);
    test_integration_iss107_step.dependOn(&run_iss107_integration_tests.step);

    const test_integration_iss0605_step = b.step("test-integration-iss0605", "Run ISS-0605 C4 orphan-row self-heal integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0605_step.dependOn(&clean_test_db.step);
    test_integration_iss0605_step.dependOn(&run_iss0605_integration_tests.step);

    const test_integration_iss0607_step = b.step("test-integration-iss0607", "Run ISS-0607 vendor/pg stderr suppression regression tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0607_step.dependOn(&clean_test_db.step);
    test_integration_iss0607_step.dependOn(&run_iss0607_integration_tests.step);

    const test_integration_iss105_step = b.step("test-integration-iss105", "Run ISS-105 token model schema integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss105_step.dependOn(&clean_test_db.step);
    test_integration_iss105_step.dependOn(&run_iss105_integration_tests.step);

    const test_integration_iss202_step = b.step("test-integration-iss202", "Run ISS-202 two-phase merge atomicity integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss202_step.dependOn(&clean_test_db.step);
    test_integration_iss202_step.dependOn(&run_iss202_integration_tests.step);

    const test_integration_iss203_step = b.step("test-integration-iss203", "Run ISS-203 deterministic idempotency keys integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss203_step.dependOn(&clean_test_db.step);
    test_integration_iss203_step.dependOn(&run_iss203_integration_tests.step);

    const test_integration_iss207_step = b.step("test-integration-iss207", "Run ISS-207 convergent error retry integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss207_step.dependOn(&clean_test_db.step);
    test_integration_iss207_step.dependOn(&run_iss207_integration_tests.step);

    const test_integration_iss208_step = b.step("test-integration-iss208", "Run ISS-208 task guard terminal instance integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss208_step.dependOn(&clean_test_db.step);
    test_integration_iss208_step.dependOn(&run_iss208_integration_tests.step);

    const test_integration_iss601_step = b.step("test-integration-iss601", "Run ISS-601 state snapshots integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss601_step.dependOn(&clean_test_db.step);
    test_integration_iss601_step.dependOn(&run_iss601_integration_tests.step);

    const test_integration_iss0125_step = b.step("test-integration-iss0125", "Run ISS-0125 FK cascade integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0125_step.dependOn(&clean_test_db.step);
    test_integration_iss0125_step.dependOn(&run_iss0125_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0125_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0122_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0123_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0121_integration_tests.step);

    const test_integration_iss0123_step = b.step("test-integration-iss0123", "Run ISS-0123 DLQ rename + audit-trigger isolation regression tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0123_step.dependOn(&clean_test_db.step);
    test_integration_iss0123_step.dependOn(&run_iss0123_integration_tests.step);

    const test_integration_iss0122_step = b.step("test-integration-iss0122", "Run ISS-0122 audit chain non-UTF-8 resilience integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0122_step.dependOn(&clean_test_db.step);
    test_integration_iss0122_step.dependOn(&run_iss0122_integration_tests.step);

    const test_integration_iss0121_step = b.step("test-integration-iss0121", "Run ISS-0121 TestHarness UUID-helper regression tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0121_step.dependOn(&clean_test_db.step);
    test_integration_iss0121_step.dependOn(&run_iss0121_integration_tests.step);

    const test_integration_iss0129_step = b.step("test-integration-iss0129", "Run ISS-0129 migration-runner advisory-lock regression tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0129_step.dependOn(&clean_test_db.step);
    test_integration_iss0129_step.dependOn(&run_iss0129_integration_tests.step);
    // ISS-0106: this binary provisions fresh tenant schemas and exercises
    // concurrent migrate-step calls — it must run via the barrier, not
    // directly on test_integration_step.
    test_integration_others_step.dependOn(&run_iss0129_integration_tests.step);

    const test_integration_iss0602_same_step = b.step("test-integration-iss0602-same", "Run ISS-0602 single-process owner-tag isolation tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0602_same_step.dependOn(&clean_test_db.step);
    test_integration_iss0602_same_step.dependOn(&run_iss0602_same_integration_tests.step);

    const test_integration_iss0602_cross_step = b.step("test-integration-iss0602-cross", "Run ISS-0602 cross-process owner-tag isolation contract tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0602_cross_step.dependOn(&clean_test_db.step);
    test_integration_iss0602_cross_step.dependOn(&run_iss0602_cross_integration_tests.step);

    const test_integration_iss205_step = b.step("test-integration-iss205", "Run ISS-205 webhook transactional outbox integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss205_step.dependOn(&clean_test_db.step);
    test_integration_iss205_step.dependOn(&run_iss205_integration_tests.step);

    const test_integration_sch303_step = b.step("test-integration-sch303", "Run EPIC-3 (ISS-301/302/303) scheduler concurrency and DLQ routing integration tests (requires BPM_TEST_DB_URL)");
    test_integration_sch303_step.dependOn(&clean_test_db.step);
    test_integration_sch303_step.dependOn(&run_sch303_integration_tests.step);

    // EXP-103: instance_waits persistence layer integration tests.
    const exp103_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/exp103_instance_waits_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_exp103_integration_tests = addIntegrationRun(b, exp103_integration_tests, migrations_dir, clean_test_db);

    const test_integration_exp103_step = b.step("test-integration-exp103", "Run EXP-103 instance_waits persistence layer integration tests (requires BPM_TEST_DB_URL)");
    test_integration_exp103_step.dependOn(&clean_test_db.step);
    test_integration_exp103_step.dependOn(&run_exp103_integration_tests.step);
    test_integration_others_step.dependOn(&run_exp103_integration_tests.step); // ISS-0106: routed via barrier, not directly onto test_integration_step

    const svc_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_svc_integration_tests = addIntegrationRun(b, svc_integration_tests, migrations_dir, clean_test_db);

    const test_integration_svc_step = b.step("test-integration-svc", "Run Stage 13 SVC-01..SVC-04 integration tests (requires BPM_TEST_DB_URL)");
    test_integration_svc_step.dependOn(&clean_test_db.step);
    test_integration_svc_step.dependOn(&run_svc_integration_tests.step);

    const env_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_env_integration_tests = addIntegrationRun(b, env_integration_tests, migrations_dir, clean_test_db);

    const test_integration_env_step = b.step("test-integration-env", "Run Stage 14 ENV-01..ENV-05 integration tests (requires BPM_TEST_DB_URL)");
    test_integration_env_step.dependOn(&clean_test_db.step);
    test_integration_env_step.dependOn(&run_env_integration_tests.step);

    // ISS-0072: tenant-config ?realm= hint integration tests.
    const iss0072_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/tenant_config_realm_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0072_integration_tests = addIntegrationRun(b, iss0072_integration_tests, migrations_dir, clean_test_db);

    const test_integration_iss0072_step = b.step("test-integration-iss0072", "Run ISS-0072 tenant-config realm override integration tests (requires BPM_TEST_DB_URL)");
    test_integration_iss0072_step.dependOn(&clean_test_db.step);
    test_integration_iss0072_step.dependOn(&run_iss0072_integration_tests.step);
    test_integration_others_step.dependOn(&run_iss0072_integration_tests.step); // ISS-0106: routed via barrier, not directly onto test_integration_step

    // ---------------------------------------------------------------------------
    // `zig build migrate` — migration runner
    // ---------------------------------------------------------------------------
    // provisioning_mod_migrate: src/db/provisioning.zig wired to pool_root_mod so
    // that migrate.zig (ISS-502 fresh-bootstrap fix) can call provisionTenantSchema
    // for the default tenant after the public-schema pass, mirroring runApiServer()
    // in main.zig. Named-module import (not a relative "../db/provisioning.zig")
    // because migrate.zig's module root does not include src/db/ in its reachable
    // file tree — same reasoning as provisioning_mod_api08 above.
    const provisioning_mod_migrate = b.createModule(.{
        .root_source_file = b.path("src/db/provisioning.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_root_mod },
            .{ .name = "tenant_context", .module = tenant_context_mod },
        },
    });
    const migrate_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "expr", .module = expr_mod },
        .{ .name = "pool", .module = pool_root_mod },
        .{ .name = "transition", .module = transition_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "identity_provider", .module = identity_provider_mod },
        .{ .name = "tenant_context", .module = tenant_context_mod },
        .{ .name = "pipeline_context", .module = pipeline_context_mod },
        .{ .name = "obs_metrics", .module = obs_metrics_mod },
        .{ .name = "json_schema", .module = json_schema_mod },
        .{ .name = "db_provisioning", .module = provisioning_mod_migrate },
    };
    const migrate_exe = b.addExecutable(.{
        .name = "migrate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/migrate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = migrate_imports,
        }),
    });
    const run_migrate = b.addRunArtifact(migrate_exe);
    run_migrate.setCwd(b.path("."));
    run_migrate.step.dependOn(b.getInstallStep());
    const migrate_step = b.step("migrate", "Apply all pending database migrations (reads BPM_DB_URL)");
    migrate_step.dependOn(&run_migrate.step);

    // ---------------------------------------------------------------------------
    // `zig build bench` — benchmark suite
    // ---------------------------------------------------------------------------
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "http", .module = http_mod },
                .{ .name = "cel", .module = cel_mod },
                .{ .name = "transition", .module = transition_mod },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("."));
    run_bench.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);
    // The benchmark needs an applied schema, exactly like the integration
    // steps do. Before ISS-BENCH-ENV this dependency lived only in whichever
    // shell an agent happened to run, so every new session started from zero
    // and nine ADHOC runs re-fixed the same missing setup.
    run_bench.step.dependOn(&run_migrate.step);
    const bench_step = b.step("bench", "Run NFR benchmark suite");
    bench_step.dependOn(&run_bench.step);

    // ---------------------------------------------------------------------------
    // `zig build test-env-verify` — Infrastructure Health Checklist as an exit code
    //
    // This is the gate ORCH consults before dispatching TEST-RUNNER. It replaces
    // a grep of `zig build bench` stdout for the literals BPM_DB_URL /
    // BENCHMARK_SETUP_ERROR / missing — a condition an implementing agent could
    // satisfy by renaming those tokens, and on 2026-05-30 did. An exit code
    // cannot be satisfied by renaming a label.
    // ---------------------------------------------------------------------------
    const run_env_verify = b.addSystemCommand(&.{
        "python",
        "tools/verify_test_env.py",
    });
    run_env_verify.setCwd(b.path("."));
    if (b.args) |args| run_env_verify.addArgs(args);
    const env_verify_step = b.step(
        "test-env-verify",
        "Verify test infrastructure health (test_infrastructure_guide.md §3); exit 0 = healthy",
    );
    env_verify_step.dependOn(&run_env_verify.step);

    // ---------------------------------------------------------------------------
    // `zig build test-wiring-check` — no test-bearing file is wired into no
    // build target (prevents ISS-0102 / GH #428 recurrence)
    //
    // ISS-0137 / GH #439 cleared the 55-file backlog that GH #428 discovered and
    // filed rather than fixed, so this check is now ENFORCED: it is a dependency
    // of `zig build test` (see test_step.dependOn below) and any file whose test
    // blocks become unreachable from every addTest root turns the build red.
    //
    // That backlog was worth clearing rather than tolerating: those 55 files
    // held ~350 test blocks that had never executed, and wiring them in
    // surfaced real defects — two Zig-0.16 ArrayList API regressions and an
    // incomplete error set in src/repository/artifacts.zig, plus a TestHarness
    // API (provisionTenant/setTenant) that tests called but nothing
    // implemented. Silent unreachability is what let all of it accumulate.
    // ---------------------------------------------------------------------------
    const run_wiring_check = b.addSystemCommand(&.{
        "python",
        "tools/lint_test_wiring.py",
    });
    run_wiring_check.setCwd(b.path("."));
    if (b.args) |args| run_wiring_check.addArgs(args);
    const wiring_check_step = b.step(
        "test-wiring-check",
        "Verify every test-bearing file is reachable from an addTest root; exit 0 = none unwired",
    );
    wiring_check_step.dependOn(&run_wiring_check.step);
    // ISS-0137 / GH #439 closing condition: `zig build test` fails whenever any
    // test-bearing file becomes unreachable from every addTest root. Attached
    // here rather than beside the other test_step edges because
    // run_wiring_check is declared in this section, far below test_step.
    test_step.dependOn(&run_wiring_check.step);

    // ---------------------------------------------------------------------------
    // `zig build openapi` — OpenAPI generator
    // ---------------------------------------------------------------------------
    const openapi_exe = b.addExecutable(.{
        .name = "openapi-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/openapi_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openapi", .module = b.createModule(.{
                    .root_source_file = b.path("src/api/openapi/mod.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "build_options", .module = build_options_mod },
                    },
                }) },
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "http", .module = http_mod },
                .{ .name = "cel", .module = cel_mod },
                .{ .name = "transition", .module = transition_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    const run_openapi = b.addRunArtifact(openapi_exe);
    const openapi_step = b.step("openapi", "Generate docs/openapi.json");
    openapi_step.dependOn(&run_openapi.step);
}
