const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const adp12_phase = b.option([]const u8, "phase", "ADP-12 phase filter (pre|post)");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "platform_version", "0.1.0");
    build_options.addOption(?[]const u8, "adp12_phase", adp12_phase);
    const build_options_mod = build_options.createModule();

    // ---------------------------------------------------------------------------
    // Vendor dependencies
    // ---------------------------------------------------------------------------
    const pg_dep = b.dependency("pg", .{});
    const http_dep = b.dependency("http", .{});
    const cel_dep = b.dependency("cel", .{});

    const pg_mod = pg_dep.module("pg");
    const http_mod = http_dep.module("http");
    const cel_mod = cel_dep.module("cel");
    const idp_config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/identity_provider.zig"),
        .target = target,
        .optimize = optimize,
    });
    const jwks_cache_mod = b.createModule(.{
        .root_source_file = b.path("src/identity/provider/oidc/jwks_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    const identity_provider_mod = b.createModule(.{
        .root_source_file = b.path("src/identity/provider/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "idp_config", .module = idp_config_mod },
        },
    });

    const transition_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/transition.zig"),
        .target = target,
        .optimize = optimize,
        // no named imports needed
    });
    const provider_errors_mod = b.createModule(.{
        .root_source_file = b.path("src/identity/provider/errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    // pool_module: wraps src/db/pool.zig so that @import("pool") resolves
    // inside claim_mapping.zig, auth.zig, etc.
    const pool_module = b.createModule(.{
        .root_source_file = b.path("src/db/pool.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
        },
    });

    const vendor_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "cel", .module = cel_mod },
        .{ .name = "transition", .module = transition_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "identity_provider", .module = identity_provider_mod },
        .{ .name = "provider_errors", .module = provider_errors_mod },
        .{ .name = "pool", .module = pool_module },
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

    const event_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/event_store_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = vendor_imports,
        }),
    });
    const run_event_store_tests = b.addRunArtifact(event_store_tests);

    const graph_mod = b.createModule(.{
        .root_source_file = b.path("src/definition/graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    const definition_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/definition_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph", .module = graph_mod },
            },
        }),
    });
    const run_definition_tests = b.addRunArtifact(definition_tests);

    const graph_node_attributes_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/graph_node_attributes_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph", .module = graph_mod },
            },
        }),
    });
    const run_graph_node_attributes_tests = b.addRunArtifact(graph_node_attributes_tests);

    const graph_edge_conditions_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/graph_edge_conditions_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph", .module = graph_mod },
            },
        }),
    });
    const run_graph_edge_conditions_tests = b.addRunArtifact(graph_edge_conditions_tests);

    // PD-07 definition retrieval handler tests (pure input-validation paths).
    // src/main.zig is used as the named-module root so that definitions.zig
    // can resolve its relative @import("../../definition/store.zig") within
    // the src/ tree — Zig 0.16 forbids @imports that escape the module root.
    const bpm_main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = vendor_imports,
    });

    // claim_mapping_mod: wraps src/oidc/claim_mapping.zig so that
    // jit_provisioning_mod can import it as a named module.
    const claim_mapping_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/claim_mapping.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
        },
    });

    // jit_provisioning_mod: wraps src/oidc/jit_provisioning.zig for
    // api_mod unit tests. Uses named module imports to avoid "file exists
    // in two modules" errors in test compilation.
    const jit_provisioning_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/jit_provisioning.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
            .{ .name = "claim_mapping", .module = claim_mapping_mod },
        },
    });

    // identity_stability_mod: wraps src/oidc/identity_stability.zig for
    // integration tests (OIDC-11). Uses named module imports.
    const identity_stability_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/identity_stability.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
        },
    });

    // realm_tenant_binding_mod: wraps src/oidc/realm_tenant_binding.zig for
    // integration tests (OIDC-12). Uses named module imports.
    const realm_tenant_binding_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/realm_tenant_binding.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
        },
    });

    // tenant_claim_source_mod: wraps src/oidc/tenant_claim_source.zig for
    // integration tests (OIDC-13). Pure functions — no pool dependency.
    const tenant_claim_source_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/tenant_claim_source.zig"),
        .target = target,
        .optimize = optimize,
    });

    // realm_provisioning_mod: wraps src/oidc/realm_provisioning.zig for
    // integration tests (OIDC-14). Pure builder functions — no pool dependency.
    const realm_provisioning_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/realm_provisioning.zig"),
        .target = target,
        .optimize = optimize,
    });

    // realm_deletion_mod: wraps src/oidc/realm_deletion.zig for
    // integration tests (OIDC-15). Uses named module imports.
    const realm_deletion_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/realm_deletion.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
        },
    });

    // migration_helper_mod: wraps src/oidc/migration_helper.zig for
    // integration tests (OIDC-34). Uses named module imports.
    const migration_helper_mod = b.createModule(.{
        .root_source_file = b.path("src/oidc/migration_helper.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
            .{ .name = "identity_provider", .module = identity_provider_mod },
        },
    });

    // bpm_src_mod: src/bpm.zig re-export shim used by engine unit tests and
    // integration tests.  Exports .engine, .tasks, .pool, .definition, etc.
    // Uses named module import for pool so that jit_provisioning_mod can
    // coexist as a sibling module dependency (both resolve pool via
    // the same pool_module, avoiding "file exists in two modules").
    const bpm_src_mod = b.createModule(.{
        .root_source_file = b.path("src/bpm.zig"),
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
            .{ .name = "cel", .module = cel_mod },
            .{ .name = "identity_provider", .module = identity_provider_mod },
            .{ .name = "pool", .module = pool_module },
        },
    });

    const db_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/db_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_db_tests = b.addRunArtifact(db_tests);

    const definition_retrieval_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/definition_retrieval_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_definition_retrieval_tests = b.addRunArtifact(definition_retrieval_tests);

    const snapshot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_snapshot.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_snapshot_tests = b.addRunArtifact(snapshot_tests);

    const export_import_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_export_import.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_export_import_unit_tests = b.addRunArtifact(export_import_unit_tests);

    // PD-10 definition search handler tests (input validation — no DB required).
    const pd10_search_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/pd10_search_unit_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_pd10_search_unit_tests = b.addRunArtifact(pd10_search_unit_tests);

    // EE-03: pure transition tests (no DB) — TC-EE-03-01 through TC-EE-03-05
    const engine_apply_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_engine_apply.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_engine_apply_tests = b.addRunArtifact(engine_apply_tests);

    // EE-03: TaskStore stubs (DB tests — all SkipZigTest until test-integration)
    const tasks_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_tasks_store.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tasks_store_tests = b.addRunArtifact(tasks_store_tests);

    // EE-03: GET /tasks handler — pure input-validation paths + DB stubs
    const tasks_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_tasks_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_tasks_api_tests = b.addRunArtifact(tasks_api_tests);

    // EE-05: Exclusive Gateway CEL integration tests (pure transition — no DB)
    const engine_ee05_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_engine_ee05.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_engine_ee05_tests = b.addRunArtifact(engine_ee05_tests);

    // EE-07: Parallel Gateway join tests (TC-EE-07-05 — 3-branch join via public API)
    const engine_ee07_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_ee07_parallel_join.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_engine_ee07_tests = b.addRunArtifact(engine_ee07_tests);

    // EE-09: Variable merge — pure json_schema validator and mergeVariables fast-path
    const engine_ee09_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_ee09_merge_variables.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_engine_ee09_tests = b.addRunArtifact(engine_ee09_tests);

    // EE-11: Reconstruction — compile-time structural checks (no DB required)
    const engine_ee11_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/reconstruction_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_engine_ee11_tests = b.addRunArtifact(engine_ee11_tests);

    // api_mod: single module root for API unit test imports.
    // claim_mapping_mod and jit_provisioning_mod are defined earlier
    // (before bpm_src_mod) and reused here.
    const api_mod = b.createModule(.{
        .root_source_file = b.path("src/api/api_mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "pool", .module = pool_module },
            .{ .name = "identity_provider", .module = identity_provider_mod },
            .{ .name = "claim_mapping", .module = claim_mapping_mod },
            .{ .name = "jit_provisioning", .module = jit_provisioning_mod },
        },
    });
    const api_conventions_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/api_conventions_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
            },
        }),
    });
    const run_api_conventions_tests = b.addRunArtifact(api_conventions_tests);

    // API-02: Process definition CRUD handler unit tests (pure input-validation — no DB)
    const api02_handler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/api02_handler_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_api02_handler_tests = b.addRunArtifact(api02_handler_tests);

    // API-03: Instance management handler unit tests (pure input-validation — no DB)
    const api03_handler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/api03_handler_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_api03_handler_tests = b.addRunArtifact(api03_handler_tests);

    // API-05: History endpoint handler unit tests (pure input-validation — no DB)
    const api05_history_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_api05_history.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_api05_history_tests = b.addRunArtifact(api05_history_tests);

    // OBS-04: timeline endpoint handler unit tests (input validation — no DB)
    const obs04_timeline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_obs04_timeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_main_mod },
            },
        }),
    });
    const run_obs04_timeline_tests = b.addRunArtifact(obs04_timeline_tests);

    // API-06: Pagination module unit tests (pure functions — no DB)
    // Uses the api_mod shim (src/api/api_mod.zig) to import pagination.zig
    const api06_pagination_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_api06_pagination.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
            },
        }),
    });
    const run_api06_pagination_tests = b.addRunArtifact(api06_pagination_tests);

    // API-07: Input validation module unit tests (pure functions — no DB)
    // Uses the api_mod shim (src/api/api_mod.zig) to import validation.zig
    const api07_validation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_api07_validation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
            },
        }),
    });
    const run_api07_validation_tests = b.addRunArtifact(api07_validation_tests);

    // API-08: Bearer token auth middleware unit tests (pure early-return paths — no DB)
    // Uses the api_mod shim (src/api/api_mod.zig) to import auth.zig.
    // pool_module is provided so that auth.zig's @import("pool") resolves.
    const api08_auth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_api08_auth.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
                .{ .name = "pool", .module = pool_module },
            },
        }),
    });
    const run_api08_auth_tests = b.addRunArtifact(api08_auth_tests);

    // API-09: Request tracing middleware unit tests (pure functions — no DB, no network)
    // Uses the api_mod shim (src/api/api_mod.zig) to import trace.zig and trace_context.zig.
    const api09_tracing_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_api09_tracing.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
            },
        }),
    });
    const run_api09_tracing_tests = b.addRunArtifact(api09_tracing_tests);

    // OIDC-01: provider boundary checks (build-level static assertions)
    const oidc01_provider_boundary_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc01_provider_boundary.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
            },
        }),
    });
    const run_oidc01_provider_boundary_tests = b.addRunArtifact(oidc01_provider_boundary_tests);

    // OIDC-01: provider interface contract checks (runtime-level unit assertions)
    const oidc01_provider_stub_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc01_provider_stub.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
            },
        }),
    });
    const run_oidc01_provider_stub_tests = b.addRunArtifact(oidc01_provider_stub_tests);

    const oidc02_keycloak_adapter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/identity/provider/test_oidc02_keycloak_adapter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_oidc02_keycloak_adapter_tests = b.addRunArtifact(oidc02_keycloak_adapter_tests);

    const oidc06_jwks_cache_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc06_jwks_cache.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "jwks_cache", .module = jwks_cache_mod },
            },
        }),
    });
    const run_oidc06_jwks_cache_tests = b.addRunArtifact(oidc06_jwks_cache_tests);

    // OIDC-08: Standard claim mapping unit tests (pure functions — no DB)
    const oidc08_claim_mapping_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oidc/claim_mapping.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pool", .module = pool_module },
            },
        }),
    });
    const run_oidc08_claim_mapping_tests = b.addRunArtifact(oidc08_claim_mapping_tests);

    // OIDC-08: Additional claim mapping unit tests (dedicated test file)
    // Tests pure functions — does NOT import bpm to avoid pool-module conflicts.
    const oidc08_claim_mapping_ex_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc08_claim_mapping.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "claim_mapping", .module = b.createModule(.{
                    .root_source_file = b.path("src/oidc/claim_mapping.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "pool", .module = pool_module },
                    },
                }) },
            },
        }),
    });
    const run_oidc08_claim_mapping_ex_tests = b.addRunArtifact(oidc08_claim_mapping_ex_tests);

    const oidc27_verification_benchmark_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc27_verification_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oidc_bench", .module = b.createModule(.{
                    .root_source_file = b.path("src/oidc/verification_benchmark.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
    const run_oidc27_verification_benchmark_tests = b.addRunArtifact(oidc27_verification_benchmark_tests);

    const oidc29_realm_seed_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc29_realm_seed.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "realm_seed", .module = b.createModule(.{
                    .root_source_file = b.path("src/oidc/realm_seed.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
    const run_oidc29_realm_seed_tests = b.addRunArtifact(oidc29_realm_seed_tests);

    const oidc30_test_token_helper_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc30_test_token_helper.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oidc_test_token_helper", .module = b.createModule(.{
                    .root_source_file = b.path("src/oidc/test_token_helper.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
    const run_oidc30_test_token_helper_tests = b.addRunArtifact(oidc30_test_token_helper_tests);

    const oidc33_coexistence_auth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc33_coexistence_auth.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oidc_coexistence", .module = b.createModule(.{
                    .root_source_file = b.path("src/oidc/coexistence_auth.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
    const run_oidc33_coexistence_auth_tests = b.addRunArtifact(oidc33_coexistence_auth_tests);

    const oidc28_local_dev_realm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc28_local_dev_realm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_oidc28_local_dev_realm_tests = b.addRunArtifact(oidc28_local_dev_realm_tests);

    const oidc32_agent_test_identities_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_oidc32_agent_test_identities.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_oidc32_agent_test_identities_tests = b.addRunArtifact(oidc32_agent_test_identities_tests);

    // SCH-05: Missed timer recovery — pure function unit tests (no DB)
    const sch05_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/sch05_missed_timer_recovery_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_sch05_unit_tests = b.addRunArtifact(sch05_unit_tests);

    // SCH-06: Timer jitter — pure function unit tests (no DB)
    const sch06_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/sch06_timer_jitter_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_sch06_unit_tests = b.addRunArtifact(sch06_unit_tests);

    // EXT-01: service task config/retry helper unit tests (pure, no DB)
    const service_task_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/service_task_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_service_task_unit_tests = b.addRunArtifact(service_task_unit_tests);

    // EXT-03: plugin interface and registry unit tests (pure, no DB)
    const ext03_plugin_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/ext03_plugin_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_ext03_plugin_unit_tests = b.addRunArtifact(ext03_plugin_unit_tests);

    // ---------------------------------------------------------------------------
    // DSL-01: Expression DSL parser unit tests (pure — no DB, no network)
    // Tests live in src/expr/parser.zig
    // ---------------------------------------------------------------------------
    const expr_mod = b.createModule(.{
        .root_source_file = b.path("src/expr/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
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

    // Lua integration module tests
    const lua_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/lua_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Link LuaJIT (if available on system)
    // lua_tests.linkSystemLibrary("luajit");
    const run_lua_tests = b.addRunArtifact(lua_tests);
    const test_lua_step = b.step("test-lua", "Run Lua integration unit tests");
    test_lua_step.dependOn(&run_lua_tests.step);

    // Wasm integration module tests
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wasm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/wasm_executor_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wasm", .module = wasm_mod },
            },
        }),
    });
    const run_wasm_tests = b.addRunArtifact(wasm_tests);
    const test_wasm_step = b.step("test-wasm", "Run Wasm execution unit tests");
    test_wasm_step.dependOn(&run_wasm_tests.step);

    const repository_canonicaliser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/repository_canonicaliser_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_repository_canonicaliser_tests = b.addRunArtifact(repository_canonicaliser_tests);

    const repository_artifacts_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/repository_artifacts_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_repository_artifacts_tests = b.addRunArtifact(repository_artifacts_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_event_store_tests.step);
    test_step.dependOn(&run_definition_tests.step);
    test_step.dependOn(&run_graph_node_attributes_tests.step);
    test_step.dependOn(&run_graph_edge_conditions_tests.step);
    test_step.dependOn(&run_definition_retrieval_tests.step);
    test_step.dependOn(&run_snapshot_tests.step);
    test_step.dependOn(&run_export_import_unit_tests.step);
    test_step.dependOn(&run_pd10_search_unit_tests.step);
    test_step.dependOn(&run_engine_apply_tests.step);
    test_step.dependOn(&run_tasks_store_tests.step);
    test_step.dependOn(&run_tasks_api_tests.step);
    test_step.dependOn(&run_engine_ee05_tests.step);
    test_step.dependOn(&run_engine_ee07_tests.step);
    test_step.dependOn(&run_engine_ee09_tests.step);
    test_step.dependOn(&run_engine_ee11_tests.step);
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_api_conventions_tests.step);
    test_step.dependOn(&run_api02_handler_tests.step);
    test_step.dependOn(&run_api03_handler_tests.step);
    test_step.dependOn(&run_api05_history_tests.step);
    test_step.dependOn(&run_obs04_timeline_tests.step);
    test_step.dependOn(&run_api06_pagination_tests.step);
    test_step.dependOn(&run_api07_validation_tests.step);
    test_step.dependOn(&run_api08_auth_tests.step);
    test_step.dependOn(&run_api09_tracing_tests.step);
    test_step.dependOn(&run_oidc01_provider_boundary_tests.step);
    test_step.dependOn(&run_oidc01_provider_stub_tests.step);
    test_step.dependOn(&run_oidc02_keycloak_adapter_tests.step);
    test_step.dependOn(&run_oidc06_jwks_cache_tests.step);
    test_step.dependOn(&run_oidc08_claim_mapping_tests.step);
    test_step.dependOn(&run_oidc08_claim_mapping_ex_tests.step);
    test_step.dependOn(&run_oidc27_verification_benchmark_tests.step);
    test_step.dependOn(&run_oidc28_local_dev_realm_tests.step);
    test_step.dependOn(&run_oidc29_realm_seed_tests.step);
    test_step.dependOn(&run_oidc30_test_token_helper_tests.step);
    test_step.dependOn(&run_oidc32_agent_test_identities_tests.step);
    test_step.dependOn(&run_oidc33_coexistence_auth_tests.step);
    test_step.dependOn(&run_sch05_unit_tests.step);
    test_step.dependOn(&run_sch06_unit_tests.step);
    test_step.dependOn(&run_service_task_unit_tests.step);
    test_step.dependOn(&run_ext03_plugin_unit_tests.step);
    test_step.dependOn(&run_dsl01_parser_tests.step);
    test_step.dependOn(&run_expr_error_recovery_tests.step);
    test_step.dependOn(&run_dsl04_eval_tests.step);
    test_step.dependOn(&run_lua_tests.step);
    test_step.dependOn(&run_wasm_tests.step);
    test_step.dependOn(&run_repository_canonicaliser_tests.step);
    test_step.dependOn(&run_repository_artifacts_tests.step);

    // ---------------------------------------------------------------------------
    // `zig build test-integration` — integration tests (requires BPM_TEST_DB_URL)
    // ---------------------------------------------------------------------------

    // bpm_src_mod is declared earlier (after bpm_main_mod) and is reused here.

    const integration_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "cel", .module = cel_mod },
        .{ .name = "bpm", .module = bpm_src_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "identity_provider", .module = identity_provider_mod },
    };

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const obs03_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/obs03_audit_log_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_obs03_integration_tests = b.addRunArtifact(obs03_integration_tests);

    const obs04_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/obs04_timeline_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_obs04_integration_tests = b.addRunArtifact(obs04_integration_tests);

    const adp12_regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/adp12_default_tenant_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_adp12_regression_tests = b.addRunArtifact(adp12_regression_tests);

    // OIDC-08: Claim mapping config loading integration tests (requires DB)
    // Reuses claim_mapping_mod defined earlier (before bpm_src_mod).
    const oidc08_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc08_claim_mapping_config_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "claim_mapping", .module = claim_mapping_mod },
                .{ .name = "pool", .module = pool_module },
            },
        }),
    });
    const run_oidc08_integration_tests = b.addRunArtifact(oidc08_integration_tests);

    // OIDC-09: JIT user provisioning integration tests (requires DB)
    // Provides jit_provisioning as a separate named module alongside bpm.
    // bpm_src_mod provides pool, identity_registry, identity_service via
    // relative imports; jit_provisioning_mod uses named imports for pool.
    // These coexist because bpm and jit_provisioning are sibling deps,
    // each resolving pool.zig in its own module context.
    const oidc09_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc09_jit_provisioning_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "jit_provisioning", .module = jit_provisioning_mod },
            },
        }),
    });
    const run_oidc09_integration_tests = b.addRunArtifact(oidc09_integration_tests);

    // OIDC-10: Attribute sync and role reconciliation integration tests (requires DB)
    // Provides jit_provisioning, claim_mapping, and bpm as named modules.
    // bpm provides pool, identity_registry, identity_service via relative imports.
    const oidc10_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc10_attribute_sync_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "jit_provisioning", .module = jit_provisioning_mod },
                .{ .name = "claim_mapping", .module = claim_mapping_mod },
            },
        }),
    });
    const run_oidc10_integration_tests = b.addRunArtifact(oidc10_integration_tests);

    // OIDC-11: Identity stability integration tests (requires DB)
    const oidc11_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc11_identity_stability_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "identity_stability", .module = identity_stability_mod },
            },
        }),
    });
    const run_oidc11_integration_tests = b.addRunArtifact(oidc11_integration_tests);

    // OIDC-12: Realm-tenant binding integration tests (requires DB)
    const oidc12_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc12_realm_tenant_binding_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "realm_tenant_binding", .module = realm_tenant_binding_mod },
            },
        }),
    });
    const run_oidc12_integration_tests = b.addRunArtifact(oidc12_integration_tests);

    // OIDC-13: Tenant claim source integration tests (pure functions, no DB needed)
    const oidc13_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc13_tenant_claim_source_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "tenant_claim_source", .module = tenant_claim_source_mod },
            },
        }),
    });
    const run_oidc13_integration_tests = b.addRunArtifact(oidc13_integration_tests);

    // OIDC-14: Realm provisioning integration tests (pure functions, no DB needed)
    const oidc14_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc14_realm_provisioning_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "realm_provisioning", .module = realm_provisioning_mod },
            },
        }),
    });
    const run_oidc14_integration_tests = b.addRunArtifact(oidc14_integration_tests);

    // OIDC-15: Realm deletion safety integration tests (requires DB)
    const oidc15_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc15_realm_deletion_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "realm_deletion", .module = realm_deletion_mod },
            },
        }),
    });
    const run_oidc15_integration_tests = b.addRunArtifact(oidc15_integration_tests);

    const oidc31_e2e_preflight_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc31_end_to_end_auth_suite_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pool", .module = pool_module },
            },
        }),
    });
    const run_oidc31_e2e_preflight_tests = b.addRunArtifact(oidc31_e2e_preflight_tests);

    const oidc34_migration_helper_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/oidc34_migration_helper_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_mod },
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "oidc_migration_helper", .module = migration_helper_mod },
            },
        }),
    });
    const run_oidc34_migration_helper_tests = b.addRunArtifact(oidc34_migration_helper_tests);

    // Pre-cleanup: delete all rows from test DB tables before running tests.
    const clean_test_db = b.addSystemCommand(&.{ "python", "tools/clean_test_db.py" });
    const clean_test_db_step = b.step("clean-test-db", "Delete all test data (requires docker-compose)");
    clean_test_db_step.dependOn(&clean_test_db.step);

    const test_integration_step = b.step("test-integration", "Run integration tests (requires BPM_TEST_DB_URL)");
    test_integration_step.dependOn(&clean_test_db.step);
    test_integration_step.dependOn(&run_integration_tests.step);
    test_integration_step.dependOn(&run_oidc08_integration_tests.step);
    test_integration_step.dependOn(&run_oidc09_integration_tests.step);
    test_integration_step.dependOn(&run_oidc10_integration_tests.step);
    test_integration_step.dependOn(&run_oidc11_integration_tests.step);
    test_integration_step.dependOn(&run_oidc12_integration_tests.step);
    test_integration_step.dependOn(&run_oidc13_integration_tests.step);
    test_integration_step.dependOn(&run_oidc14_integration_tests.step);
    test_integration_step.dependOn(&run_oidc15_integration_tests.step);
    test_integration_step.dependOn(&run_oidc34_migration_helper_tests.step);

    const test_integration_obs03_step = b.step("test-integration-obs03", "Run OBS-03 integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_obs03_step.dependOn(&clean_test_db.step);
    test_integration_obs03_step.dependOn(&run_obs03_integration_tests.step);

    const test_integration_obs04_step = b.step("test-integration-obs04", "Run OBS-04 integration tests only (requires BPM_TEST_DB_URL)");
    test_integration_obs04_step.dependOn(&clean_test_db.step);
    test_integration_obs04_step.dependOn(&run_obs04_integration_tests.step);

    const test_adp12_regression_step = b.step("test-adp12-regression", "Run ADP-12 default-tenant pre/post regression suite");
    test_adp12_regression_step.dependOn(&clean_test_db.step);
    test_adp12_regression_step.dependOn(&run_adp12_regression_tests.step);

    const test_oidc09_step = b.step("test-integration-oidc09", "Run OIDC-09 JIT provisioning integration tests only (requires BPM_TEST_DB_URL)");
    test_oidc09_step.dependOn(&clean_test_db.step);
    test_oidc09_step.dependOn(&run_oidc09_integration_tests.step);

    const test_oidc10_step = b.step("test-integration-oidc10", "Run OIDC-10 attribute sync integration tests only (requires BPM_TEST_DB_URL)");
    test_oidc10_step.dependOn(&clean_test_db.step);
    test_oidc10_step.dependOn(&run_oidc10_integration_tests.step);

    const test_oidc31_step = b.step("test-integration-oidc31", "Run OIDC-31 E2E auth-suite preflight tests (requires BPM_TEST_DB_URL, BPM_TEST_URL, BPM_IDP_BASE_URL)");
    test_oidc31_step.dependOn(&clean_test_db.step);
    test_oidc31_step.dependOn(&run_oidc31_e2e_preflight_tests.step);

    // ---------------------------------------------------------------------------
    // `zig build migrate` — migration runner
    // ---------------------------------------------------------------------------
    const migrate_exe = b.addExecutable(.{
        .name = "migrate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/migrate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = vendor_imports,
        }),
    });
    const run_migrate = b.addRunArtifact(migrate_exe);
    run_migrate.step.dependOn(b.getInstallStep());
    const migrate_step = b.step("migrate", "Apply all pending database migrations (reads BPM_DB_URL)");
    migrate_step.dependOn(&run_migrate.step);

    // ---------------------------------------------------------------------------
    // `zig build bench` — DSL-13 expression evaluation benchmark suite
    // ---------------------------------------------------------------------------
    const expr_bench_exe = b.addExecutable(.{
        .name = "expr-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/expr/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_expr_bench = b.addRunArtifact(expr_bench_exe);
    const bench_step = b.step("bench", "Run expression evaluation benchmark (DSL-13)");
    bench_step.dependOn(&run_expr_bench.step);

    const verify_dev_realm_exe = b.addExecutable(.{
        .name = "verify-dev-realm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/verify_dev_realm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_verify_dev_realm = b.addRunArtifact(verify_dev_realm_exe);
    const verify_dev_realm_step = b.step("verify-dev-realm", "Verify local Keycloak realm bootstrap assets");
    verify_dev_realm_step.dependOn(&run_verify_dev_realm.step);

    const validate_realm_seed_exe = b.addExecutable(.{
        .name = "validate-realm-seed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/validate_realm_seed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_validate_realm_seed = b.addRunArtifact(validate_realm_seed_exe);
    const validate_realm_seed_step = b.step("validate-realm-seed", "Validate deterministic Keycloak realm seed artifact");
    validate_realm_seed_step.dependOn(&run_validate_realm_seed.step);

    const check_realm_seed_drift_exe = b.addExecutable(.{
        .name = "check-realm-seed-drift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/check_realm_seed_drift.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_check_realm_seed_drift = b.addRunArtifact(check_realm_seed_drift_exe);
    const check_realm_seed_drift_step = b.step("check-realm-seed-drift", "Detect drift between committed and runtime realm exports");
    check_realm_seed_drift_step.dependOn(&run_check_realm_seed_drift.step);

    const verify_agent_test_identities_exe = b.addExecutable(.{
        .name = "verify-agent-test-identities",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/verify_agent_test_identities.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_verify_agent_test_identities = b.addRunArtifact(verify_agent_test_identities_exe);
    const verify_agent_test_identities_step = b.step("verify-agent-test-identities", "Verify seeded agent service-account identities");
    verify_agent_test_identities_step.dependOn(&run_verify_agent_test_identities.step);

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
