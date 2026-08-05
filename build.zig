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
    const pool_root_mod = b.createModule(.{
        .root_source_file = b.path("src/db/pool.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
            .{ .name = "tenant_context", .module = tenant_context_mod },
            .{ .name = "pipeline_context", .module = pipeline_context_mod },
            .{ .name = "obs_metrics", .module = obs_metrics_mod },
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

    // bpm_src_mod: src/bpm.zig re-export shim used by engine unit tests and
    // integration tests.  Exports .engine, .tasks, .pool, .definition, etc.
    const bpm_src_mod = b.createModule(.{
        .root_source_file = b.path("src/bpm.zig"),
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
            .{ .name = "cel", .module = cel_mod },
            .{ .name = "expr", .module = expr_mod },
            .{ .name = "pool", .module = pool_root_mod },
            .{ .name = "tenant_context", .module = tenant_context_mod },
            .{ .name = "pipeline_context", .module = pipeline_context_mod },
            .{ .name = "obs_metrics", .module = obs_metrics_mod },
            // identity_provider added so integration tests can call route handlers
            // that reference auth.getIdentityProviderManager() (e.g. handlePatchTenant).
            .{ .name = "identity_provider", .module = identity_provider_mod },
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
                .{ .name = "build_options", .module = build_options_mod },
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
            .{ .name = "tenant_context", .module = tenant_context_mod },
            .{ .name = "pipeline_context", .module = pipeline_context_mod },
            .{ .name = "obs_metrics", .module = obs_metrics_mod },
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
                .{ .name = "build_options", .module = build_options.createModule() },
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

    // SCH-302: Startup sweep advisory lock — pure function unit tests (no DB)
    const sch302_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/sch302_startup_sweep_lock_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_sch302_unit_tests = b.addRunArtifact(sch302_unit_tests);

    // SCH-303: Timer DLQ unit tests (migration file presence + source inspection, no DB)
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

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_crypto_iss0074_tests.step);
    // EXP-301/302/303: Effects subsystem unit tests (pure — no DB, no network)
    const effects_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/effects/test_effects.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bpm", .module = bpm_src_mod },
            },
        }),
    });
    const run_effects_unit_tests = b.addRunArtifact(effects_unit_tests);
    test_step.dependOn(&run_effects_unit_tests.step);

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
    test_step.dependOn(&run_sch302_unit_tests.step);
    test_step.dependOn(&run_sch303_unit_tests.step);
    test_step.dependOn(&run_service_task_unit_tests.step);
    test_step.dependOn(&run_ext03_plugin_unit_tests.step);
    test_step.dependOn(&run_exp701_sandbox_threatmodel_tests.step);
    test_step.dependOn(&run_dsl01_parser_tests.step);
    test_step.dependOn(&run_expr_error_recovery_tests.step);
    test_step.dependOn(&run_dsl04_eval_tests.step);

    // ---------------------------------------------------------------------------
    // `zig build test-differential` — ISS-602 CEL/expr differential harness
    // ---------------------------------------------------------------------------
    const expr_diff_mod = b.createModule(.{
        .root_source_file = b.path("src/expr/mod.zig"),
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
            },
        }),
    });
    // Allow @embedFile to resolve files in src/ and vendor/ from the differential test
    differential_tests.root_module.addIncludePath(b.path("."));
    const run_differential_tests = b.addRunArtifact(differential_tests);
    run_differential_tests.setCwd(b.path("."));
    const test_differential_step = b.step("test-differential", "Run CEL/expr differential corpus tests (ISS-602)");
    test_differential_step.dependOn(&run_differential_tests.step);

    // ---------------------------------------------------------------------------
    // `zig build test-integration` — integration tests (requires BPM_TEST_DB_URL)
    // ---------------------------------------------------------------------------

    // bpm_src_mod is declared earlier (after bpm_main_mod) and is reused here.

    const integration_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "cel", .module = cel_mod },
        .{ .name = "expr", .module = expr_mod },
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

    const tm_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/tm01_tenant_list_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_tm_integration_tests = b.addRunArtifact(tm_integration_tests);
    run_tm_integration_tests.setCwd(b.path("."));
    run_tm_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const exp_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/entity_subsystem_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_exp_integration_tests = b.addRunArtifact(exp_integration_tests);
    run_exp_integration_tests.setCwd(b.path("."));
    run_exp_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const spt01_iss0068_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/spt01_iss0068_onboarding_schema_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_spt01_iss0068_integration_tests = b.addRunArtifact(spt01_iss0068_integration_tests);
    run_spt01_iss0068_integration_tests.setCwd(b.path("."));
    run_spt01_iss0068_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-0071: Onboarding realm-existence guard integration tests.
    const iss0071_realm_guard_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/onboarding_realm_guard_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0071_realm_guard_integration_tests = b.addRunArtifact(iss0071_realm_guard_integration_tests);
    run_iss0071_realm_guard_integration_tests.setCwd(b.path("."));
    run_iss0071_realm_guard_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const tnt_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/tnt_schema_isolation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_tnt_integration_tests = b.addRunArtifact(tnt_integration_tests);
    run_tnt_integration_tests.setCwd(b.path("."));
    run_tnt_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const tnt_backfill_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/tnt_backfill_export_cleanup_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_tnt_backfill_integration_tests = b.addRunArtifact(tnt_backfill_integration_tests);
    run_tnt_backfill_integration_tests.setCwd(b.path("."));
    run_tnt_backfill_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss101_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss101_timers_failed_status_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss101_integration_tests = b.addRunArtifact(iss101_integration_tests);
    run_iss101_integration_tests.setCwd(b.path("."));
    run_iss101_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss102_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss102_claim_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss102_integration_tests = b.addRunArtifact(iss102_integration_tests);
    run_iss102_integration_tests.setCwd(b.path("."));
    run_iss102_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss103_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/audit_iss103_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss103_integration_tests = b.addRunArtifact(iss103_integration_tests);
    run_iss103_integration_tests.setCwd(b.path("."));
    run_iss103_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss0091_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0091_harness_tracker_unification_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0091_integration_tests = b.addRunArtifact(iss0091_integration_tests);
    run_iss0091_integration_tests.setCwd(b.path("."));
    run_iss0091_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss106_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss106_webhook_outbox_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss106_integration_tests = b.addRunArtifact(iss106_integration_tests);
    run_iss106_integration_tests.setCwd(b.path("."));
    run_iss106_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss107_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss107_tenant_storage_mode_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss107_integration_tests = b.addRunArtifact(iss107_integration_tests);
    run_iss107_integration_tests.setCwd(b.path("."));
    run_iss107_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss105_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss105_token_model_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss105_integration_tests = b.addRunArtifact(iss105_integration_tests);
    run_iss105_integration_tests.setCwd(b.path("."));
    run_iss105_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-502: SPT cutover transaction integration tests.
    const iss502_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss502_spt_cutover_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss502_integration_tests = b.addRunArtifact(iss502_integration_tests);
    run_iss502_integration_tests.setCwd(b.path("."));
    run_iss502_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-503: GBL-084 RLS removal migration integration tests.
    const iss503_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/test_iss503_rls_removal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss503_integration_tests = b.addRunArtifact(iss503_integration_tests);
    run_iss503_integration_tests.setCwd(b.path("."));
    run_iss503_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss202_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss202_merge_atomicity_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss202_integration_tests = b.addRunArtifact(iss202_integration_tests);
    run_iss202_integration_tests.setCwd(b.path("."));
    run_iss202_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    const iss203_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss203_idempotency_keys_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss203_integration_tests = b.addRunArtifact(iss203_integration_tests);
    run_iss203_integration_tests.setCwd(b.path("."));
    run_iss203_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-207: Convergent EXECUTION_ERROR retry integration tests.
    const iss207_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss207_error_retry_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss207_integration_tests = b.addRunArtifact(iss207_integration_tests);
    run_iss207_integration_tests.setCwd(b.path("."));
    run_iss207_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-208: Guard task completion against terminal instances integration tests.
    const iss208_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss208_task_guard_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss208_integration_tests = b.addRunArtifact(iss208_integration_tests);
    run_iss208_integration_tests.setCwd(b.path("."));
    run_iss208_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-205: Webhook transactional outbox integration tests.
    const iss205_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss205_webhook_outbox_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss205_integration_tests = b.addRunArtifact(iss205_integration_tests);
    run_iss205_integration_tests.setCwd(b.path("."));
    run_iss205_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-601: State Snapshots for Large-Instance Reconstruction integration tests.
    const iss601_integration_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pg", .module = pg_mod },
        .{ .name = "http", .module = http_mod },
        .{ .name = "cel", .module = cel_mod },
        .{ .name = "pool", .module = pool_root_mod },
        .{ .name = "bpm", .module = bpm_src_mod },
        .{ .name = "build_options", .module = build_options_mod },
    };
    const iss601_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss601_state_snapshots_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = iss601_integration_imports,
        }),
    });
    const run_iss601_integration_tests = b.addRunArtifact(iss601_integration_tests);
    run_iss601_integration_tests.setCwd(b.path("."));
    run_iss601_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-0125: process definition snapshot FK cascade and cleanup-error propagation.
    const iss0125_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0125_cascade_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0125_integration_tests = b.addRunArtifact(iss0125_integration_tests);
    run_iss0125_integration_tests.setCwd(b.path("."));
    run_iss0125_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

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
    const run_iss0122_integration_tests = b.addRunArtifact(iss0122_integration_tests);
    run_iss0122_integration_tests.setCwd(b.path("."));
    run_iss0122_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

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
    const run_iss0121_integration_tests = b.addRunArtifact(iss0121_integration_tests);
    run_iss0121_integration_tests.setCwd(b.path("."));
    run_iss0121_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

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
    const run_iss0602_same_integration_tests = b.addRunArtifact(iss0602_same_integration_tests);
    run_iss0602_same_integration_tests.setCwd(b.path("."));
    run_iss0602_same_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

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
    const run_iss0602_cross_integration_tests = b.addRunArtifact(iss0602_cross_integration_tests);
    run_iss0602_cross_integration_tests.setCwd(b.path("."));
    run_iss0602_cross_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-0123: DLQ rename (Cluster B) + obs05 audit-trigger isolation (Cluster A) regression tests.
    const iss0123_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0123_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0123_integration_tests = b.addRunArtifact(iss0123_integration_tests);
    run_iss0123_integration_tests.setCwd(b.path("."));
    run_iss0123_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // EPIC-3 (ISS-301, ISS-302, ISS-303): Scheduler concurrency and DLQ routing integration tests.
    const sch303_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/sch303_timer_dlq_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_sch303_integration_tests = b.addRunArtifact(sch303_integration_tests);
    run_sch303_integration_tests.setCwd(b.path("."));
    run_sch303_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-0076: secrets table creation regression coverage (GitHub #335).
    const iss0076_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/iss0076_secrets_table_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
    const run_iss0076_integration_tests = b.addRunArtifact(iss0076_integration_tests);
    run_iss0076_integration_tests.setCwd(b.path("."));
    run_iss0076_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

    // ISS-0088: verify clean_test_db.py / helpers.zig resetTestData() only
    // reference table names that currently exist, so a future migration
    // rename/drop can't silently desync them again.
    const lint_test_table_refs = b.addSystemCommand(&.{ "python", "tools/lint_test_table_refs.py" });
    lint_test_table_refs.setCwd(b.path("."));
    const lint_test_table_refs_step = b.step("lint-test-table-refs", "Verify test cleanup tooling references only current table names");
    lint_test_table_refs_step.dependOn(&lint_test_table_refs.step);

    // Pre-cleanup: delete all rows from test DB tables before running tests.
    const clean_test_db = b.addSystemCommand(&.{ "python", "tools/clean_test_db.py" });
    clean_test_db.setCwd(b.path("."));
    clean_test_db.step.dependOn(&lint_test_table_refs.step);
    const clean_test_db_step = b.step("clean-test-db", "Delete all test data (requires docker-compose)");
    clean_test_db_step.dependOn(&clean_test_db.step);

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
    const run_iss503_integration_tests_after_others = b.addRunArtifact(iss503_integration_tests);
    run_iss503_integration_tests_after_others.setCwd(b.path("."));
    run_iss503_integration_tests_after_others.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);
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
    const run_exp103_integration_tests = b.addRunArtifact(exp103_integration_tests);
    run_exp103_integration_tests.setCwd(b.path("."));
    run_exp103_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

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
    const run_svc_integration_tests = b.addRunArtifact(svc_integration_tests);
    run_svc_integration_tests.setCwd(b.path("."));
    run_svc_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

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
    const run_env_integration_tests = b.addRunArtifact(env_integration_tests);
    run_env_integration_tests.setCwd(b.path("."));
    run_env_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

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
    const run_iss0072_integration_tests = b.addRunArtifact(iss0072_integration_tests);
    run_iss0072_integration_tests.setCwd(b.path("."));
    run_iss0072_integration_tests.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);

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
        "python3",
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
