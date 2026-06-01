const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const adp12_phase = b.option([]const u8, "phase", "ADP-12 phase filter (pre|post)");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "platform_version", "0.1.0");
    build_options.addOption(?[]const u8, "adp12_phase", adp12_phase);
    build_options.addOption([]const u8, "migrations_dir", b.path("migrations").getPath(b));
    const build_options_mod = build_options.createModule();
    const migrations_dir = b.path("migrations").getPath(b);

    // ---------------------------------------------------------------------------
    // Vendor dependencies
    // ---------------------------------------------------------------------------
    const pg_dep = b.dependency("pg", .{});
    const http_dep = b.dependency("http", .{});
    const cel_dep = b.dependency("cel", .{});

    const pg_mod = pg_dep.module("pg");
    const http_mod = http_dep.module("http");
    const cel_mod = cel_dep.module("cel");
    const pool_root_mod = b.createModule(.{
        .root_source_file = b.path("src/db/pool.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
        },
    });
    const idp_config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/identity_provider.zig"),
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
    const vendor_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "cel", .module = cel_mod },
        .{ .name = "pool", .module = pool_root_mod },
        .{ .name = "transition", .module = transition_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "identity_provider", .module = identity_provider_mod },
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

    // bpm_src_mod: src/bpm.zig re-export shim used by engine unit tests and
    // integration tests.  Exports .engine, .tasks, .pool, .definition, etc.
    const bpm_src_mod = b.createModule(.{
        .root_source_file = b.path("src/bpm.zig"),
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
            .{ .name = "cel", .module = cel_mod },
            .{ .name = "pool", .module = pool_root_mod },
        },
    });

    const event_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/event_store_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
                .{ .name = "pool", .module = pool_root_mod },
            },
        }),
    });
    const run_event_store_tests = b.addRunArtifact(event_store_tests);

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
    test_step.dependOn(&run_sch05_unit_tests.step);
    test_step.dependOn(&run_sch06_unit_tests.step);
    test_step.dependOn(&run_service_task_unit_tests.step);
    test_step.dependOn(&run_ext03_plugin_unit_tests.step);
    test_step.dependOn(&run_dsl01_parser_tests.step);
    test_step.dependOn(&run_expr_error_recovery_tests.step);
    test_step.dependOn(&run_dsl04_eval_tests.step);

    // ---------------------------------------------------------------------------
    // `zig build test-integration` — integration tests (requires BPM_TEST_DB_URL)
    // ---------------------------------------------------------------------------

    // bpm_src_mod is declared earlier (after bpm_main_mod) and is reused here.

    const integration_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "cel", .module = cel_mod },
        .{ .name = "pool", .module = pool_root_mod },
        .{ .name = "bpm", .module = bpm_src_mod },
        .{ .name = "build_options", .module = build_options_mod },
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
    run_integration_tests.setCwd(b.path("."));
    run_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const xc04_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/xc04_kernel_determinism_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_xc04_integration_tests = b.addRunArtifact(xc04_integration_tests);
    run_xc04_integration_tests.setCwd(b.path("."));
    run_xc04_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const stage11_sim_xc04_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/stage11_sim_xc04_aggregate_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_stage11_sim_xc04_integration_tests = b.addRunArtifact(stage11_sim_xc04_integration_tests);
    run_stage11_sim_xc04_integration_tests.setCwd(b.path("."));
    run_stage11_sim_xc04_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const sim05_08_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/sim05_08_scenario_runner_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_sim05_08_integration_tests = b.addRunArtifact(sim05_08_integration_tests);
    run_sim05_08_integration_tests.setCwd(b.path("."));
    run_sim05_08_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const obs03_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/obs03_audit_log_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_obs03_integration_tests = b.addRunArtifact(obs03_integration_tests);
    run_obs03_integration_tests.setCwd(b.path("."));
    run_obs03_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const adm_ui_09_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/adm_ui_09_health_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_adm_ui_09_integration_tests = b.addRunArtifact(adm_ui_09_integration_tests);
    run_adm_ui_09_integration_tests.setCwd(b.path("."));
    run_adm_ui_09_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const obs04_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/obs04_timeline_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_obs04_integration_tests = b.addRunArtifact(obs04_integration_tests);
    run_obs04_integration_tests.setCwd(b.path("."));
    run_obs04_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const adp12_regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/adp12_default_tenant_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_adp12_regression_tests = b.addRunArtifact(adp12_regression_tests);
    run_adp12_regression_tests.setCwd(b.path("."));
    run_adp12_regression_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // Pre-cleanup: delete all rows from test DB tables before running tests.
    const clean_test_db = b.addSystemCommand(&.{ "python", "tools/clean_test_db.py" });
    clean_test_db.setCwd(b.path("."));
    const clean_test_db_step = b.step("clean-test-db", "Delete all test data (requires docker-compose)");
    clean_test_db_step.dependOn(&clean_test_db.step);

    const test_integration_step = b.step("test-integration", "Run integration tests (requires BPM_TEST_DB_URL)");
    test_integration_step.dependOn(&clean_test_db.step);
    test_integration_step.dependOn(&run_integration_tests.step);
    test_integration_step.dependOn(&run_adm_ui_09_integration_tests.step);

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

    const test_adp12_regression_step = b.step("test-adp12-regression", "Run ADP-12 default-tenant pre/post regression suite");
    test_adp12_regression_step.dependOn(&clean_test_db.step);
    test_adp12_regression_step.dependOn(&run_adp12_regression_tests.step);

    // ---------------------------------------------------------------------------
    // `zig build test-all` — run ALL tests (unit + integration + E2E pipeline)
    // ---------------------------------------------------------------------------
    // This is the comprehensive test command that ensures complete test coverage.
    // It includes:
    //   1. Unit tests (zig build test)
    //   2. Integration tests with real DB (zig build test-integration)
    //   3. End-to-end pipeline tests via Playwright (npm run test from web/)
    //
    // This step orchestrates the full test suite and is used by TEST-RUNNER agent.
    const test_all_step = b.step("test-all", "Run ALL tests: unit + integration + E2E pipeline (comprehensive test suite)");
    test_all_step.dependOn(test_step);                        // Unit tests
    test_all_step.dependOn(test_integration_step);            // Integration tests
    // Note: E2E tests (Playwright) must be run via: cd web && npm run test

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
    const bench_step = b.step("bench", "Run NFR benchmark suite");
    bench_step.dependOn(&run_bench.step);

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
