# Design — Test Wiring Fix (ISS-0137 / GH #439)

**Type:** E (novel / cross-cutting — build-graph change, no new business logic)
**Run:** WF03-gh439-testwiring-20260806
**Branch:** `feature/WF03-gh439-testwiring-20260806`
**Input:** `docs/issue-reports/ISS-0137-diagnosis.yaml` (per-file disposition for all 55 files)
**Scope:** wire 54 test-bearing files into a build target, delete 1 obsolete duplicate,
then promote `test-wiring-check` into `zig build test` so the defect class cannot recur.

This is a build-graph design. "Design" here means the exact structural decisions —
file paths, module names, build step names, refAllDecls targets, attachment points.
No implementation code appears below; BACKEND-DEV writes the Zig and the `build.zig`
edits from these specifications without re-deriving any decision.

---

## §0. Verification performed for this design

Every claim the diagnosis flagged as `needs_designer_judgement` or deferred was
re-verified against the working tree before deciding. Results are recorded in §8
(Diagnosis corrections). Baseline confirmed:

```
python tools/lint_test_wiring.py --quiet
  -> FAIL, 55 test-bearing file(s) unwired
```

That 55 is the number every checkpoint in §7 counts down from.

---

## §1. The module-ownership rule (resolves the C3/C4 conflict)

### 1.1 The conflict

C4 creates `b.createModule(.{ .name = "claim_mapping", .root_source_file = "src/oidc/claim_mapping.zig" })`.
C3 creates `src/oidc_test_root.zig`, which the diagnosis describes as
"refAllDecls over all 7 `src/oidc/*` files". If that shim reaches those files by
**relative path** (`@import("oidc/claim_mapping.zig")`), then `claim_mapping.zig` is
simultaneously:

- the root of the named module `claim_mapping` (a compilation unit in its own right), and
- a plain file belonging to the shim's own module (rooted at `src/`).

Zig rejects this with *"file exists in multiple modules"* whenever both modules end up
in the same compilation. This is not hypothetical: `src/bpm.zig`'s own doc comment
records the repo hitting exactly this for `pool.zig`, and its first line states the
remedy — "Having one module root prevents 'file exists in two modules' conflicts that
arise when pool.zig is both a named-module root AND imported via a relative path
inside store.zig." The fix used there was `pub const pool = @import("pool");` — the
**named** form.

### 1.2 THE RULE (general, binding on every cluster)

> **Single-Owner Module Rule.** A given `.zig` file has exactly one owning module in
> any one compilation. If a file is (or becomes) the `root_source_file` of a named
> `b.createModule`, then **every** other file that needs it — shims included — must
> reach it by its **named** import (`@import("claim_mapping")`), never by a relative
> path. Relative-path reach is permitted only for files that are *not* any module's
> root.
>
> Corollary for shim authors: before writing `@import("some/path.zig")` in a shim,
> grep `build.zig` for that path as a `root_source_file`. If it appears, use the
> module name instead and declare that module in the shim's `addTest` `.imports` list.

Applying the rule mechanically to this run:

| File | Becomes a named-module root? | How C3's shim must reach it |
|---|---|---|
| `src/oidc/claim_mapping.zig` | yes (`claim_mapping`, C4) | **named** |
| `src/oidc/jit_provisioning.zig` | yes (`jit_provisioning`, C4) | **named** |
| `src/oidc/identity_stability.zig` | yes (`identity_stability`, C4) | **named** |
| `src/oidc/realm_tenant_binding.zig` | yes (`realm_tenant_binding`, C4) | **named** |
| `src/oidc/tenant_claim_source.zig` | yes (`tenant_claim_source`, C4) | **named** |
| `src/oidc/realm_provisioning.zig` | yes (`realm_provisioning`, C4) | **named** |
| `src/oidc/realm_deletion.zig` | yes (`realm_deletion`, C4) | **named** |
| `src/repository/mod.zig` | yes (`repository`, C5) | **named** |
| `src/wasm/mod.zig` | yes (`wasm`, C5) | **named** |
| `src/api/tenant_context.zig` | already `tenant_context_mod` | **named** |
| `src/api/pipeline_context.zig` | already `pipeline_context_mod` | **named** |
| `src/obs/metrics.zig` | already `obs_metrics_mod` | **named** |
| `src/env.zig` | already `env_mod` | **named** |
| `src/config/identity_provider.zig` | already `idp_config_mod` | **named** |
| `src/identity/provider/mod.zig` | already `identity_provider_mod` | **named** |
| `src/simulation/mod.zig` | **no** | relative path (safe) |

The last row is the only C3 target that stays relative — and that is precisely why
its shim placement matters (§2.5).

### 1.3 Why this rule is safe here (verified, not assumed)

The rule would be unusable if any `src/oidc/*.zig` file reached a sibling by relative
path, because a named-module root cannot `@import` a path that escapes its own root
directory. Verified by inspection of all 12 `src/oidc/*.zig` files: **every non-`std`
import in the entire directory is a named module** (`pool`, `claim_mapping`,
`identity_provider`). Zero relative `.zig` imports. Each file is therefore a valid
standalone module root, and the named-module approach costs nothing.

Same check for the other candidate overlaps:

- `src/repository/*.zig` — `artifacts.zig`, `activation.zig` reach `canonicaliser.zig`
  and `artifacts.zig` by **relative** path. They must therefore **not** individually
  become module roots. Only `src/repository/mod.zig` becomes the root (of `repository`),
  and it reaches its five siblings relatively from inside its own module. Consistent.
- `src/simulation/*.zig` — all reach `types.zig` relatively, and `tenant_store.zig`
  reaches `../event_store/store.zig`, escaping `src/simulation/`. So `simulation/mod.zig`
  must **not** become a named module root; it is reached relatively from a shim at `src/`.
- `src/api/tenant_context.zig`, `pipeline_context.zig`, `obs/metrics.zig`, `env.zig` —
  zero non-`std` imports. Pure leaves, already module roots. Named reach only.

### 1.4 Consequence for the C3 shim set

Because the seven `src/oidc/*` files are reached by name, the "shim at `src/`" placement
constraint does not apply to them — a named module has no relative-path escape to worry
about. `src/oidc_test_root.zig` still lives at `src/` (naming consistency with
`src/transition_test_root.zig`), but its content is named `@import`s, and its `addTest`
module must declare all seven module names in `.imports`.

**Ordering consequence:** the diagnosis says "sequence C3 before C4". That is now
**inverted**. C3's oidc shim depends on the seven module declarations C4 creates.
See §7 for the corrected order.

### 1.5 Linter interaction (important — do not skip)

`tools/lint_test_wiring.py`'s `IMPORT_LITERAL` regex requires a literal `.zig` suffix,
so its BFS **cannot follow named-module edges**. A shim that reaches `claim_mapping.zig`
by name is invisible to the linter, and the file stays reported as `[UNWIRED]` even
though its tests now genuinely run.

This is a real tension between the Single-Owner Module Rule (required by Zig) and the
linter's reachability model (a regex). Resolving it by weakening the shim is forbidden —
that would be satisfying the gate by changing what it measures. Resolve it by
**teaching the linter to follow named edges**, which is improvement L-2 in the diagnosis
and is hereby promoted from MINOR/optional to **in-scope and required for C7**:

> **L-2 (required, part of C7).** `tools/lint_test_wiring.py` must parse `build.zig`'s
> `b.createModule` declarations into a `name -> root_source_file` map, and extend
> `resolve_imports()` so that `@import("<name>")` resolves through that map when
> `<name>` matches a declared module. Only then can the BFS see through the shims this
> design mandates. Without L-2, C7 cannot reach exit 0 and the gate cannot be promoted.

L-2 must be implemented **before** the C7 checkpoint, and its correctness verified the
same way the rest of this design is: the count must fall to 0 and `zig build test` must
still pass.

---

## §2. New shim files (C3) — exact specification

All follow `src/transition_test_root.zig`: a doc comment stating why the shim exists and
why it sits where it does, `pub const` bindings, and one `test { }` block calling
`std.testing.refAllDecls` on each binding. Every shim's doc comment must reference
ISS-0137 / GH #439 and restate the Single-Owner Module Rule clause that governs it.

### 2.1 `src/core_modules_test_root.zig`

- **Covers (4 files, 15 blocks):** `src/api/tenant_context.zig` (4),
  `src/api/pipeline_context.zig` (3), `src/obs/metrics.zig` (6), `src/env.zig` (2).
- **Reaches them by:** named imports `tenant_context`, `pipeline_context`,
  `obs_metrics`, `env` — all four already exist in `build.zig`. Rule §1.2 applies.
- **refAllDecls targets:** all four bindings.
- **addTest module imports:** `tenant_context`, `pipeline_context`, `obs_metrics`, `env`.
- **`.link_libc = true` — required.** `env_mod` is declared with `link_libc` because
  `src/env.zig` uses libc's `environ` extern on non-Windows (ISS-0134).
- **Build step:** `test` + narrow `test-core-modules`.

### 2.2 `src/config_idp_test_root.zig`

- **Covers (1 file, 3 blocks):** `src/config/identity_provider.zig`.
- **Reaches it by:** named import `idp_config`.
- **addTest module imports:** `idp_config` (and `portable_env`, which `idp_config_mod`
  already carries internally — the shim does not need to re-declare it).
- **`.link_libc = true` — required** (same ISS-0134 reason).
- **Do NOT merge into `core_modules_test_root`.** The diagnosis floats merging as
  "harmless". Keep separate: `idp_config_mod` carries its own `portable_env` import
  binding `env_mod` under a second name; merging puts `env_mod` in one compilation under
  two names (`env` and, transitively, `portable_env`). That is legal but confusing, and
  separating costs one small target. **Decision: separate.**
- **Build step:** `test` + narrow `test-config-idp`.

### 2.3 `src/oidc_test_root.zig`

- **Covers (7 files, 44 blocks):** `claim_mapping` (11), `jit_provisioning` (15),
  `identity_stability` (3), `realm_deletion` (4), `realm_tenant_binding` (2),
  `realm_provisioning` (2), `tenant_claim_source` (7).
- **Reaches them by:** the seven **named** modules created in C4. This is the direct
  application of §1.2 and the resolution of the C3/C4 conflict.
- **refAllDecls targets:** all seven bindings.
- **addTest module imports:** the seven module names, plus `pool` (needed because five
  of the seven modules declare `pool` in their own `.imports`; supplying it at the shim
  level is not strictly required since each module carries its own, but `pool` must be
  reachable in the compilation — BACKEND-DEV supplies it if the build complains).
- **`.link_libc`:** not required (none of these files touch `env.zig`); add only if the
  build demands it via `pool_root_mod`'s transitive graph.
- **Build step:** `test` + narrow `test-oidc-src`.
- **Depends on C4.** Cannot be built before the seven modules exist.

### 2.4 `src/repository_test_root.zig`

- **Covers (3 files, 5 blocks):** `src/repository/artifacts.zig` (3),
  `schemas.zig` (1), `activation.zig` (1).
- **Reaches them by:** the **named** module `repository` (root `src/repository/mod.zig`,
  created in C5), whose re-exports pull in all five repository files. Rule §1.2 applies —
  `mod.zig` becomes a module root, so no relative reach.
- **refAllDecls target:** the single `repository` binding. `refAllDecls` on `mod.zig`
  forces analysis of its five `pub const` re-exports, which is what discovers the tests.
- **addTest module imports:** `repository`, `pool`.
- **Build step:** `test` + narrow `test-repository-src`.
- **Depends on C5's `repository` module.**
- **Note:** this shim and `tests/unit/repository_test_root.zig` (§3.3) are two different
  files with similar names — one covers `src/` in-file tests, the other covers
  `tests/unit/` test files. Both are needed; do not conflate. See §3.3 for the
  disambiguating rename decision.

### 2.5 `src/simulation_test_root.zig`

- **Covers (5 files, 7 blocks):** `context.zig` (1), `time_source.zig` (2),
  `uuid_source.zig` (2), `mock_catalog.zig` (1), `tenant_store.zig` (1).
- **Reaches them by:** **relative** path `@import("simulation/mod.zig")`. This is the one
  C3 shim that stays relative, and it is correct under §1.2 because `simulation/mod.zig`
  is *not* becoming a named-module root anywhere in this design.
- **Placement is load-bearing — shim MUST sit at `src/`, not `src/simulation/`.**
  Verified: `src/simulation/tenant_store.zig` line 2 imports `../event_store/store.zig`,
  escaping `src/simulation/`. A shim at `src/simulation/` would make that import escape
  the module root and Zig 0.16 rejects it. Identical to the constraint that forced
  `src/transition_test_root.zig` to `src/`.
- **refAllDecls target:** the `simulation` binding (mod.zig re-exports all nine siblings).
- **addTest module imports:** none required beyond `std` — but `mod.zig` also re-exports
  `runtime.zig` and `scenario_runner.zig`, which may pull `pool`/`bpm`-level deps.
  BACKEND-DEV adds whatever named imports the compiler demands and records them.
- **Build step:** `test` + narrow `test-simulation`.

### 2.6 `src/identity/provider/idp_test_root.zig`

- **Covers (1 file, 3 blocks):** `src/identity/provider/bootstrap.zig`.
- **Reaches it by:** **relative** path `@import("bootstrap.zig")`. Correct under §1.2 —
  `bootstrap.zig` is not a module root; `identity/provider/mod.zig` is.
- **Placement:** `src/identity/provider/`. Verified `bootstrap.zig` reaches
  `manager.zig`, `adapters/keycloak/provider.zig`, `adapters/stub/provider.zig` — all
  *at or below* its own directory, so no escape. This directory is the correct root.
- **`@import("root")` hazard — this is the one real unknown in C3.** `bootstrap.zig`
  line 3 does `const root = @import("root");`, which resolves to whatever file is the
  `addTest` root — i.e. this shim. If `bootstrap.zig` reads any declaration off `root`,
  the shim must provide it or compilation fails.
  **Instruction to BACKEND-DEV:** before finalising, read `bootstrap.zig` for every use
  of the `root` binding and add the matching `pub const`/`pub fn` declarations to the
  shim so it satisfies that contract. If `root` is referenced only inside an
  `@hasDecl`/`if (@hasDecl(root, ...))` guard, no declarations are needed and the guard
  simply takes its false branch — that is an acceptable outcome, but must be confirmed
  by reading, not assumed.
  **Fallback if the `root` contract cannot be satisfied:** do not force it. Move
  `bootstrap.zig` to a `DOCUMENTED_EXCLUSION` entry (§5) with `issue_ref` pointing at a
  newly filed GitHub issue for the `@import("root")` coupling, and proceed. This one file
  (3 blocks) must not block the other 51.
- **addTest module imports:** `env`, `idp_config`. **`.link_libc = true`** (both
  transitively reach `src/env.zig`).
- **Build step:** `test` + narrow `test-idp-bootstrap`.

### 2.7 C3 shim summary

| Shim | Files | Blocks | Reach | libc | Narrow step |
|---|---|---|---|---|---|
| `src/core_modules_test_root.zig` | 4 | 15 | named | yes | `test-core-modules` |
| `src/config_idp_test_root.zig` | 1 | 3 | named | yes | `test-config-idp` |
| `src/oidc_test_root.zig` | 7 | 44 | named | no | `test-oidc-src` |
| `src/repository_test_root.zig` | 3 | 5 | named | no | `test-repository-src` |
| `src/simulation_test_root.zig` | 5 | 7 | relative | no | `test-simulation` |
| `src/identity/provider/idp_test_root.zig` | 1 | 3 | relative | yes | `test-idp-bootstrap` |
| **Total** | **21** | **77** | | | |

Matches the diagnosis's C3 totals (21 files / 77 blocks). Six new targets, not 21 —
honouring the ISS-0136 constraint on concurrent libc-linked `zig-test` jobs (risk G-4).

---

## §3. New aggregator shims (C4/C5) — exact specification

These follow the `tests/unit/bpm_src_test_root.zig` / `graph_test_root.zig` pattern:
one `test { }` block containing `_ = @import("sibling_test.zig");` lines. All targets are
sibling **test files** reached relatively — none is a module root, so §1.2 permits it.

### 3.1 `tests/unit/oidc_unit_test_root.zig`

- **Aggregates (8 files, 38 blocks):** `test_oidc06_jwks_cache.zig` (7),
  `test_oidc08_claim_mapping.zig` (20), `test_oidc27_verification_benchmark.zig` (1),
  `test_oidc28_local_dev_realm.zig` (2), `test_oidc29_realm_seed.zig` (2),
  `test_oidc30_test_token_helper.zig` (2), `test_oidc32_agent_test_identities.zig` (2),
  `test_oidc33_coexistence_auth.zig` (2).
- **addTest module imports:** `jwks_cache`, `claim_mapping`, `oidc_bench`, `realm_seed`,
  `oidc_test_token_helper`, `oidc_coexistence`, `pool`.
- **`setCwd(b.path("."))` on the Run artifact — REQUIRED.** `test_oidc28` and
  `test_oidc32` read `docker-compose.yml` and `infrastructure/keycloak/realms/*.json`
  from disk via `Dir.cwd()`. Same treatment `sch303_timer_dlq_unit_test.zig` already gets.
  Omitting this makes those two fail with `FileNotFound` depending on invocation directory.
- **Neither file needs a running Keycloak** — their "keycloak" matches are assertions on
  file *content*. They belong on `test`, not `test-integration`.
- **Build step:** `test` + narrow `test-oidc-unit`.
- **Duplicate top-level test-name check:** BACKEND-DEV must confirm no two of the eight
  files declare an identically-named top-level `test "..."`, per the precondition stated
  in `bpm_src_test_root.zig`'s doc comment. If a collision exists, rename in the test
  file (a test name is not a gate), not by dropping the file.

### 3.2 `tests/unit/misc_unit_test_root.zig`

- **Aggregates (2 files, 13 blocks):** `lua_test.zig` (7), `wasm_executor_test.zig` (6).
- **addTest module imports:** `wasm`. (`lua_test.zig` imports only `std`.)
- **Build step:** `test` + narrow `test-misc-unit`.
- **Wasm decision — see §3.5. Not blocked on ISS-0147.**

### 3.3 `tests/unit/repository_unit_test_root.zig`

**Renamed** from the diagnosis's `tests/unit/repository_test_root.zig` to avoid a
confusing near-collision with `src/repository_test_root.zig` (§2.4). Two files whose
basenames differ only by directory invite exactly the kind of mistake this whole issue
is about. **Decision: `tests/unit/repository_unit_test_root.zig`.**

- **Aggregates (2 files, 13 blocks):** `repository_canonicaliser_test.zig` (12),
  `repository_artifacts_test.zig` (1).
- **addTest module imports:** `repository`, `pool`.
- **Build step:** `test` + narrow `test-repository-unit`.
- **`repository_artifacts_test.zig` routing — RESOLVED to `test`, not `test-integration`.**
  The diagnosis flagged this as `needs_designer_judgement` because the file "references
  BPM_TEST_DB_URL in 14 lines". Verified by reading the whole 14-line file: its only test
  block is `test "Artifacts module compiles"` whose body is `_ = repository.artifacts;`.
  The `BPM_TEST_DB_URL` string appears **only in a comment** ("Full DB tests are in
  test-integration mode"). Zero DB usage. It is safe on `test`. See §8.

### 3.4 The two `src/wasm` questions, kept separate

`src/wasm` **liveness** (is this subsystem dead code?) is ISS-0147 / GH #463 and is
explicitly out of scope here. This design does not decide it and does not depend on it.

What this design does decide is narrower and self-contained: **can
`tests/unit/wasm_executor_test.zig`'s 6 blocks be run today without linking a real
Wasmtime library?** That question is answerable now and does not touch liveness.

### 3.5 Wasm decision — WIRE IT (no exclusion needed)

**Answer: yes, wire it. No Wasmtime link is required.** Verified by grepping all of
`src/wasm/*.zig` for `@cImport`, `linkSystemLibrary`, and `extern` declarations:

- **zero** `@cImport` anywhere in `src/wasm/`.
- **zero** `linkSystemLibrary` calls.
- `wasmtime_bindings.zig` contains only `extern struct` / `extern union` **type**
  declarations (`Engine`, `Store`, `Instance`, `Module`, `Func`, `Trap`, `Memory`,
  `Val`, `Extern`). `extern struct` is a *layout* qualifier — it declares C-compatible
  memory layout and requires no symbol at link time. The file's own comment confirms it:
  "Stub types for C interop (will be replaced with real @cImport in Stage 10)".

So `tests/unit/wasm_executor_test.zig` compiles and runs against pure-Zig stubs, exactly
as its own comment claims ("engine_new is a stub that returns null in unit tests").

- **`wasm` module:** `b.createModule(.{ .name = "wasm", .root_source_file = "src/wasm/mod.zig" })`,
  no extra imports. `mod.zig` reaches its 11 siblings relatively from `src/wasm/` — no escape.
- **Disposition:** `NEEDS_SHIM` (aggregated into `misc_unit_test_root.zig`), **not**
  `DOCUMENTED_EXCLUSION`.
- **Fallback if BACKEND-DEV nonetheless hits a link error:** move
  `wasm_executor_test.zig` to a `DOCUMENTED_EXCLUSION` entry (§5) with
  `issue_ref: GH #463` (ISS-0147 already covers the wasm subsystem question), leave
  `lua_test.zig` in `misc_unit_test_root.zig`, and continue. C5 does not stall on this.

### 3.6 Aggregator summary

| Aggregator | Files | Blocks | setCwd | Narrow step |
|---|---|---|---|---|
| `tests/unit/oidc_unit_test_root.zig` | 8 | 38 | **yes** | `test-oidc-unit` |
| `tests/unit/repository_unit_test_root.zig` | 2 | 13 | no | `test-repository-unit` |
| `tests/unit/misc_unit_test_root.zig` | 2 | 13 | no | `test-misc-unit` |

Three new targets. Combined with C3's six, this run adds **nine** new `addTest` targets
total — the ISS-0136 budget the diagnosis proposed, met exactly.

---

## §4. `build.zig` edits, per cluster

Placement convention: declare new modules next to the existing `b.createModule` block
(near `build.zig:25-95`); declare new `addTest`/Run/step triples in the
`zig build test` section (after the existing aggregators, ~line 300). Every new target
follows the established triple — `addTest` → `addRunArtifact` → `b.step("test-<name>", ...)`
→ `test_step.dependOn(&run_X.step)`.

### 4.1 New named modules (13 for C4, 2 for C5)

C4 — all rooted in `src/oidc/` except `jwks_cache`:

| Module name | `root_source_file` | `.imports` |
|---|---|---|
| `claim_mapping` | `src/oidc/claim_mapping.zig` | `pool` |
| `jit_provisioning` | `src/oidc/jit_provisioning.zig` | `pool`, `claim_mapping` |
| `identity_stability` | `src/oidc/identity_stability.zig` | `pool` |
| `realm_tenant_binding` | `src/oidc/realm_tenant_binding.zig` | `pool` |
| `tenant_claim_source` | `src/oidc/tenant_claim_source.zig` | — |
| `realm_provisioning` | `src/oidc/realm_provisioning.zig` | — |
| `realm_deletion` | `src/oidc/realm_deletion.zig` | `pool` |
| `oidc_migration_helper` | `src/oidc/migration_helper.zig` | `pool`, `identity_provider` |
| `jwks_cache` | `src/identity/provider/oidc/jwks_cache.zig` | — |
| `oidc_bench` | `src/oidc/verification_benchmark.zig` | — |
| `realm_seed` | `src/oidc/realm_seed.zig` | — |
| `oidc_test_token_helper` | `src/oidc/test_token_helper.zig` | — |
| `oidc_coexistence` | `src/oidc/coexistence_auth.zig` | — |

Every `.imports` column above was verified by reading each file's actual `@import` lines.
Two corrections to the diagnosis are baked in — see §8: `oidc_migration_helper` needs
**`pool` and `identity_provider`** (the diagnosis said no imports), and `jwks_cache`'s
root is `src/identity/provider/oidc/jwks_cache.zig`, **not** `src/oidc/jwks.zig`
(two different files — the diagnosis is right to warn against conflating them).

Declaration order matters: `claim_mapping` before `jit_provisioning`.

C5:

| Module name | `root_source_file` | `.imports` |
|---|---|---|
| `repository` | `src/repository/mod.zig` | `pool` |
| `wasm` | `src/wasm/mod.zig` | — |

### 4.2 `integration_imports` extension (C4)

The nine OIDC **integration** tests reach their modules by name, so the modules must be
appended to the existing `integration_imports` slice (`build.zig:624`). Append exactly
the nine names those tests use: `claim_mapping`, `jit_provisioning`,
`identity_stability`, `realm_tenant_binding`, `tenant_claim_source`,
`realm_provisioning`, `realm_deletion`, `oidc_migration_helper`.

This is the **only** `build.zig` change C2/C4-integration/C6 require. Because
`integration_imports` is shared by `integration_tests`, `svc_integration_tests`,
`env_integration_tests` and the ~35 dedicated roots, one edit serves all of them.

### 4.3 New `addTest` targets

Nine, all on `test`. For each: `addTest` with the module imports listed in §2/§3,
`addRunArtifact`, a `b.step("test-<name>", "<description>")`, that step
`dependOn(&run_X.step)`, and `test_step.dependOn(&run_X.step)`.

| Var | Root | Narrow step | libc | setCwd |
|---|---|---|---|---|
| `core_modules_tests` | `src/core_modules_test_root.zig` | `test-core-modules` | yes | no |
| `config_idp_tests` | `src/config_idp_test_root.zig` | `test-config-idp` | yes | no |
| `oidc_src_tests` | `src/oidc_test_root.zig` | `test-oidc-src` | no | no |
| `repository_src_tests` | `src/repository_test_root.zig` | `test-repository-src` | no | no |
| `simulation_tests` | `src/simulation_test_root.zig` | `test-simulation` | no | no |
| `idp_bootstrap_tests` | `src/identity/provider/idp_test_root.zig` | `test-idp-bootstrap` | yes | no |
| `oidc_unit_tests` | `tests/unit/oidc_unit_test_root.zig` | `test-oidc-unit` | no | **yes** |
| `repository_unit_tests` | `tests/unit/repository_unit_test_root.zig` | `test-repository-unit` | no | no |
| `misc_unit_tests` | `tests/unit/misc_unit_test_root.zig` | `test-misc-unit` | no | no |

The narrow `test-<name>` steps are mandatory, not optional. §7's per-cluster checkpoints
depend on being able to run one group in isolation, and the whole reason this backlog is
risky (G-2: never-executed tests are presumed rotten) is that failures need attribution.

### 4.4 No new `test-integration` edges

All 21 integration files are wired through `tests/integration/main_test.zig`'s import
list. `main_test.zig` already sits behind the `test_integration_others_step` barrier, so
**no new barrier edges are needed and the ISS-0106 DDL race (G-5) is eliminated by
construction.** BACKEND-DEV must not create dedicated `addTest` roots for any of these
files — doing so would reintroduce G-5.

---

## §5. Linter exclusion mechanism

### 5.1 Decision: design now, implement only if needed

This design assigns **zero** files to `DOCUMENTED_EXCLUSION` in the expected path —
both flagged candidates resolved to "wire it" (§3.3 repository_artifacts, §3.5 wasm).
So the mechanism is **not** required for the happy path.

It is required only if one of the two named fallbacks fires: the `@import("root")`
contract in `bootstrap.zig` (§2.6) proves unsatisfiable, or `wasm_executor_test.zig`
unexpectedly demands a real Wasmtime link (§3.5).

**Instruction to BACKEND-DEV:** implement §5.2 **only** if a fallback actually fires.
If neither does, skip it and record "exclusion mechanism not needed — zero exclusions"
in the handoff result. Do not build unused machinery. If one does fire, §5.2 is
mandatory in the same commit as the exclusion — an exclusion with no mechanism to
declare `reason`/`issue_ref` is not permitted.

### 5.2 Specification (if implemented)

**File:** `tools/test_wiring_exclusions.yaml` (YAML, per CLAUDE.md output-format rules).

**Entry schema** — a top-level `exclusions:` list; every entry requires all four keys:

| Key | Type | Constraint |
|---|---|---|
| `path` | string | repo-relative, forward slashes; must exist on disk |
| `reason` | string | non-empty; why the file cannot be wired today |
| `issue_ref` | string | non-empty; a GitHub issue URL or `GH #NNN` |
| `added_at` | string | UTC `YYYY-MM-DDTHH:MM:SSZ` from the real clock |

**Loader behaviour in `lint_test_wiring.py`:**

1. Load the file in `main()`. Absent file = empty list, not an error.
2. **Validate every entry.** Missing/empty `reason` or `issue_ref`, or a `path` that does
   not exist on disk, is a **hard error: exit 2** with a message naming the bad entry.
   An unverifiable exclusion must break the linter, not silently widen it.
3. Subtract validated `path`s from `unwired` before the verdict.
4. **Print every exclusion, with its `reason` and `issue_ref`, on every run — including
   runs that PASS**, and print the count in the verdict line
   (e.g. `PASS — ... (2 documented exclusion(s))`). An exclusion that stops being visible
   has become the very "silently unreachable" state this linter exists to detect.

**Explicitly forbidden: an inline source comment or pragma.** Per CLAUDE.md's "Never
Satisfy a Gate by Editing What It Measures", a `// lint-test-wiring: ignore` marker would
let any future agent silence the gate by editing the exact file the gate measures — a
one-line, reviewable-as-trivial escape hatch. A separate YAML file forces the exclusion
to appear as its own diff hunk in a file whose only purpose is to record exclusions,
with a mandatory issue reference making it someone's tracked obligation.

---

## §6. The two source fixes

### 6.1 `tests/integration/iss206_token_multiset_test.zig` — `bpm.engine_transition`

**Verified:** line 85 reads `const transition_mod = bpm.engine_transition;`. `src/bpm.zig`
line 27 exports `pub const transition = @import("engine/transition.zig");`. There is no
`engine_transition` binding anywhere in `src/bpm.zig`. The diagnosis is correct.

**Decision: fix the test's symbol. Do NOT add an alias export.**

Change the test to use `bpm.transition`. Rationale:

- One caller, one wrong symbol. The test is wrong; `bpm.zig` is right.
- An alias adds a permanent second name for one binding in a 70-line re-export shim whose
  entire value is being the single unambiguous surface. `bpm.zig`'s doc comment states its
  purpose is preventing multi-name/multi-module ambiguity — adding a redundant alias works
  against the file's stated reason for existing.
- An alias would make the *incorrect* spelling permanently valid, so the next test
  copy-pasting from this one perpetuates it.
- Reverting an alias later is a breaking change; fixing one call site now is not.

**Scope:** exactly one line in one test file. Nothing else in the repo references
`engine_transition` (BACKEND-DEV: confirm with a repo-wide grep before editing; if other
references exist, fix them all the same way and report the count).

### 6.2 `tests/integration/exp601_tier_quota_test.zig` — relative-import escape

**Verified:** lines 16-17 read
`@import("../../src/config/quota_policy.zig")` and
`@import("../../src/api/middleware/quota_enforcement.zig")`. Both escape the
`tests/integration` module root; Zig 0.16 rejects this. The diagnosis is correct.

**Verified further:** `src/bpm.zig` currently exports **neither** — a grep for `quota`
in `src/bpm.zig` returns zero matches. So "rewrite to reach them via `bpm`" is not
available as-is; `bpm.zig` must gain the two exports either way.

**Decision: add two re-exports to `src/bpm.zig`, then rewrite the test to use them.**

Add to `src/bpm.zig`:
- `quota_policy` → `config/quota_policy.zig`
- `quota_enforcement` → `api/middleware/quota_enforcement.zig`

Then change the test's two lines to `bpm.quota_policy` / `bpm.quota_enforcement`.
Rationale:

- This is exactly what `src/bpm.zig` is for. Its doc comment: "Single-root re-export shim
  used by integration tests." Sixty-odd sibling exports already follow this shape,
  including `tenant_status` (`api/middleware/tenant_status.zig`) — a direct precedent for
  re-exporting a middleware module.
- The alternative — a third module or a dedicated `addTest` root for this one file —
  reintroduces the ISS-0106 barrier problem (G-5) and adds a target against the ISS-0136
  budget, for one 5-block file.
- Consistency: every other integration test reaches `src/` through `bpm`. This file is the
  outlier, and the fix makes it conform rather than blessing a second access path.

**Naming:** use `quota_policy` and `quota_enforcement` (not `api_quota_enforcement`) —
matches the unprefixed style of `promotion_mod`/`secrets`/`entities` nearby.

**Ordering:** this `src/bpm.zig` edit must land before the `main_test.zig` import line for
`exp601`, or the integration suite fails to compile.

### 6.3 `tests/integration/repository_test.zig` — checked, no fix needed

The diagnosis asked CODE-DESIGNER to confirm this file reaches the repository API through
an already-exported path. **Verified:** `src/bpm.zig` exports
`service_catalog` (`repository/service_catalog.zig`) but **not** `repository/mod.zig`.

**Instruction to BACKEND-DEV:** at C2, read `repository_test.zig`'s actual symbol usage.
If it only touches `bpm.service_catalog`, wire it with a plain import line — no change.
If it reaches for `bpm.repository`, add `pub const repository = @import("repository/mod.zig");`
to `src/bpm.zig` in the same commit, following §6.2's precedent. Do not pre-emptively add
the export if it is unused. Report which branch was taken.

---

## §7. Implementation order and checkpoints

**Order changed from the diagnosis.** The diagnosis proposed C3 → C4 ("sequence C3 before
C4 and re-verify"). Under §1.2, C3's `src/oidc_test_root.zig` reaches its seven targets by
**named** module, so those modules must exist first. **C4's module declarations now
precede C3.** The order below reflects that.

C4 is also split: its module declarations (C4a) are a prerequisite for C3, while its test
wiring (C4b) follows C3.

One commit per cluster. After every cluster: run `python tools/lint_test_wiring.py` and
the relevant `zig build` step, and confirm the expected remaining count. A count that does
not match is a stop-and-diagnose condition, not something to push past.

**Baseline: 55 unwired.**

| # | Cluster | Work | Verify | Expected remaining |
|---|---|---|---|---|
| 1 | **C1** delete duplicate | `git rm tests/unit/event_store_test_orig.zig` | `zig build test` | **54** |
| 2 | **C4a** OIDC + C5 modules | 15 `b.createModule` decls (§4.1); append 8 to `integration_imports` (§4.2). No new targets yet. | `zig build` exits 0 | 54 (no change — expected) |
| 3 | **C3** src shims | 6 shims (§2) + 6 addTest triples (§4.3) | `zig build test`; each `test-<name>` | **33** |
| 4 | **C4b** unit aggregator | `tests/unit/oidc_unit_test_root.zig` (§3.1) + triple w/ setCwd | `zig build test-oidc-unit` | **25** |
| 5 | **C5** repo/wasm/misc | 2 aggregators (§3.2, §3.3) + triples; iss206 symbol fix (§6.1) | `zig build test-repository-unit`, `test-misc-unit` | **21** |
| 6 | **C6** exp601 | `src/bpm.zig` re-exports + test rewrite (§6.2) | `zig build test-integration` | 21 (source fix only) |
| 7 | **C2+C4b-int** integration import lines | 19 `@import` lines in `main_test.zig` (10 C2 + 9 C4 integration) | `zig build test-integration` | **2** |
| 8 | **L-2** linter named-module edges | §1.5 | `python tools/lint_test_wiring.py` | **0** |
| 9 | **C7** promote the gate | §7.2 | `zig build test` | **0**, gate enforced |

### 7.1 Note on the remaining counts

Steps 3-7 subtract *linter-visible* wiring. Because the linter cannot follow named-module
edges until L-2 lands (§1.5), the shims that reach targets **by name** — `core_modules`,
`config_idp`, `oidc_src`, `repository_src` (14 files) — will still report `[UNWIRED]`
after step 3 even though their tests genuinely run. Step 8 is what clears them.

**BACKEND-DEV must not treat that as a failure of C3.** The authoritative check that C3
worked is the `zig build test-<name>` runs actually executing and reporting test counts —
not the linter number. The expected-remaining figures above are the *ideal* counts once
L-2 lands; record the actual per-step number and the delta, and confirm it closes at step 8.

If the numbers cannot be reconciled at step 8, that is a genuine defect — file it and
enqueue it. Do **not** adjust the linter to make the number come out right.

### 7.2 C7 — the closing condition (explicit, non-negotiable)

C7 is last and has a hard precondition.

**Precondition:** `python tools/lint_test_wiring.py` exits **0**. Not "0 after excluding
some", not "0 with `--quiet`" — a genuine exit 0, with any `DOCUMENTED_EXCLUSION` entries
printed and each carrying a filed `issue_ref`.

**Then, in one commit, both of:**

1. Add `test_step.dependOn(&run_wiring_check.step);` in `build.zig`, so
   `zig build test` fails whenever any test-bearing file becomes unreachable. This is
   what makes the defect class non-recurring and is ISS-0137's stated closing condition.
2. **Delete** the explanatory paragraph at `build.zig` ~lines 1531-1544 — the comment
   beginning "Not made a dependency of `test` or `build`: as of the GH #428 fix this tool
   found 55 PRE-EXISTING test-bearing files...". Its entire justification is the backlog
   this run clears. Leaving it in place would leave `build.zig` documenting, as current
   policy, a decision that has just been reversed. Replace it with a short comment
   recording that ISS-0137 / GH #439 cleared the backlog and the check is now enforced.

**Both, or neither.** Adding the dependency without deleting the comment leaves the file
self-contradictory; deleting the comment without adding the dependency removes the record
of why the gate is off while leaving it off.

**If the precondition cannot be met**, C7 does not land. Report the exact remaining files
and why, file them, and enqueue per `docs/agents/protocols/ISSUE_QUEUE.md`. Do **not**
add the dependency "optimistically", and do **not** reach exit 0 by widening exclusions,
loosening `TEST_BLOCK`/`SCAN_DIRS`, or otherwise editing what the gate measures.

---

## §8. Green-Main Gate compliance (verified, not assumed)

**Rule:** `zig build test` must pass with no Postgres and no Keycloak.

**Split verified by spot-check** rather than trusted from the diagnosis. Method: for each
file routed to `test`, check its imports and test bodies for `pool`/`Conn`/`query`/
`BPM_TEST_DB_URL`/`http`/Keycloak usage.

Spot-checks performed:

- `src/oidc/*.zig` (7 files, 44 blocks → `test`): all imports are `std` + named modules.
  `claim_mapping.zig` declares `pool: *@import("pool").Pool` as a **struct field** at
  line 105 — production code, not a test body. Confirms the diagnosis's finding that the
  module must be *given* `pool` to compile while its tests need no live DB. Correct on `test`.
- `src/api/tenant_context.zig`, `pipeline_context.zig`, `obs/metrics.zig`, `env.zig`:
  zero non-`std` imports. Cannot touch a service. Correct on `test`.
- `tests/unit/repository_artifacts_test.zig`: full file read (14 lines) — `BPM_TEST_DB_URL`
  appears **only in a comment**; the single test body is `_ = repository.artifacts;`.
  Correct on `test`. **Resolves a `needs_designer_judgement` flag.**
- `tests/unit/wasm_executor_test.zig`: imports `std` + `wasm`; `src/wasm/` has zero
  `@cImport`/`linkSystemLibrary`. Correct on `test`. **Resolves a `needs_designer_judgement` flag.**
- `tests/integration/oidc31_*`, `oidc35_*` (Keycloak): remain on `test-integration`. Correct.
- `tests/integration/exp601_tier_quota_test.zig`: doc comment states "Requires:
  BPM_TEST_DB_URL"; uses `helpers.TestHarness`. Correct on `test-integration` — the §6.2
  fix does **not** move it to `test`.

**Split as designed:** 33 files / 141 blocks on `test`; 21 files / 184 blocks on
`test-integration`; 1 file / 25 stub blocks deleted. 141 + 184 + 25 = 350. Matches the
diagnosis. **Zero live-service files land on `zig build test`.**

`iss206_token_multiset_test.zig` stays on `test-integration` despite being DB-free — it is
wired through `main_test.zig`, and moving it would need a dedicated root (G-5 risk) for no
coverage gain. Same for `oidc13`/`oidc14`.

### 8.1 Where the diagnosis was wrong or incomplete

Recorded so the validator can check these independently:

1. **Cluster order inverted.** The diagnosis says "sequence C3 before C4 and re-verify".
   Under the Single-Owner Module Rule, C3's oidc shim consumes C4's modules, so C4a must
   come first. Corrected in §7.
2. **`oidc_migration_helper` imports were wrong.** The diagnosis lists
   `{name: oidc_migration_helper, root: src/oidc/migration_helper.zig, imports: []}`.
   The file actually imports `pool` (line 2) and `identity_provider` (line 3). A module
   declared with empty `.imports` would fail to compile. Corrected in §4.1.
3. **`repository_artifacts_test.zig` judgement resolved.** Not a DB test — the
   `BPM_TEST_DB_URL` reference is a comment. Stays on `test` (§3.3).
4. **`wasm_executor_test.zig` judgement resolved.** No Wasmtime link needed — `extern
   struct` is a layout qualifier, not a link-time symbol. Wire it; no exclusion (§3.5).
5. **Linter blind spot not accounted for.** The diagnosis treats L-2 (named-module edge
   resolution) as an optional MINOR improvement. It is not optional: the Single-Owner
   Module Rule makes named-module reach mandatory for 14 files, and the linter cannot see
   through those edges, so **C7 cannot reach exit 0 without L-2**. Promoted to required (§1.5).
6. **Shim name collision.** The diagnosis names both `src/repository_test_root.zig` and
   `tests/unit/repository_test_root.zig`. Renamed the latter to
   `tests/unit/repository_unit_test_root.zig` (§3.3).
7. **`exp601`'s "route through `bpm`" option was not actually available.** The diagnosis
   offers it as an alternative to adding re-exports; `src/bpm.zig` exports neither quota
   module, so the re-exports are required either way (§6.2).

---

## §9. Expected failures and how to handle them

These 350 blocks have not run for months. The GH #428 precedent: 7 of 30 wired-in
`transition.zig` tests failed immediately, and the exercise surfaced two real production
memory bugs. Expect a comparable rate here — roughly 70-90 failing blocks across the run.

**A failing newly-wired test is a success of this fix, not a regression of it.** It is the
gap becoming visible. Per CLAUDE.md's Unblock-Everything and No-Issue-Left-Local-Only
directives, each genuine failure must be:

1. filed as an ISS file **and** a GitHub issue (checking for ID collision first), and
2. enqueued onto `handoffs/WF03-gh439-testwiring-20260806/issue_queue.json` for draining
   via WF-03 Steps 1-7 **on this run's existing branch** — no new branch, no new PR.

**Forbidden responses to a newly-wired failing test:**

- `error.SkipZigTest` to make the gate green — that is silencing the detector.
- Removing the file from its shim/aggregator — that re-creates ISS-0137 for that file.
- Weakening an assertion so it passes without understanding why it failed.
- Adding the file to `test_wiring_exclusions.yaml` — exclusions are for files that
  *cannot be wired*, never for files that are wired and failing.

The per-cluster commits and narrow `test-<name>` steps exist precisely so each failure is
attributable to one cluster instead of arriving as one unreadable red wall (risk G-2).

---

## §10. Acceptance criteria for BACKEND-DEV

- [ ] `tests/unit/event_store_test_orig.zig` deleted.
- [ ] 15 new `b.createModule` declarations exist with the exact names/roots/imports of §4.1.
- [ ] 6 C3 shims exist at the exact paths in §2, each reaching its targets by the
      mechanism (named vs relative) §1.2 prescribes for that file.
- [ ] 3 aggregators exist per §3, `oidc_unit_test_root`'s Run artifact has `setCwd(b.path("."))`.
- [ ] 9 new `addTest` targets, each on `test` **and** on its own narrow `test-<name>` step (§4.3).
- [ ] 8 OIDC module names appended to `integration_imports` (§4.2).
- [ ] 19 new import lines in `tests/integration/main_test.zig`; **zero** new dedicated
      integration `addTest` roots (ISS-0106 / G-5).
- [ ] `iss206_token_multiset_test.zig` uses `bpm.transition` (§6.1).
- [ ] `src/bpm.zig` re-exports `quota_policy` + `quota_enforcement`; `exp601` uses them (§6.2).
- [ ] `zig build` exits 0; `zig build test` exits 0; `zig build test-integration` exits 0
      (with services up).
- [ ] `python tools/lint_test_wiring.py` exits 0 — including L-2 (§1.5).
- [ ] `test_step.dependOn(&run_wiring_check.step)` added **and** the ~1531-1544 paragraph
      deleted — both, and only after the linter exits 0 (§7.2).
- [ ] Every newly-surfaced test failure filed (ISS + GitHub) and enqueued (§9).
- [ ] `python tools/lint_handoffs.py` exits 0.
