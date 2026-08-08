# Module: ISS-0181 / GH-512 — T010 Hardcoded-UUID Retirement

## Module purpose

This design retires the 184 BLOCKER T010 findings currently suppressed in `tools/lint_test_isolation.baseline.json`. Each finding is a quoted UUID literal inside a `tests/integration/*.zig` file that the linter flags because per-test UUIDs are mandatory (INV-TI-2: shared `bpm_test` database rows collide when two test binaries insert identical instance / actor / definition ids). Two remedies already exist as `TestHarness` runtime helpers — `newUuid()` (allocation-free, returns `bpm.uuid.Uuid`) and `newUuidString(allocator)` (allocates the canonical 36-byte form). This design enumerates the substitution and retention rules for every site, the file-level batching order, and the validation criteria that close the linter ledger without regressing any pre-existing test failure.

It is purely a **test-fixture migration**: no production source under `src/**` is touched, no migration under `migrations/**` is touched, no shared schema bootstrapper script is touched. The 13 occurrences of `00000000-0000-0000-0000-000000000001` (conventional platform-admin actor `user_id`) are retained as fixed system constants with auditable comments.

## Scope and non-goals

- **In scope:** all 184 T010 findings in 45 files under `tests/integration/` — both substitution (CONVERT) and retention (RETAIN) treatments, the helpers.zig API surface needed for them, the baseline shrinkage arithmetic, and the validation gates that distinguish a clean run from a regression.
- **In scope:** adding `// GH-512 retention: <reason>` and `// GH-512: keep as system constant: <reason>` comments at retention sites so the audit chain is human-readable and the next engineer knows why a literal survived.
- **In scope:** removing now-empty `// Fixed test UUIDs (deterministic — no RNG dependency)` section banners that, after conversion, contain zero literals — the section itself can stay as documentation of "no fixed UUIDs left" if that helps the file's reader.
- **Out of scope:** other linter classes (T020 module-level `var`, T030 missing-defer, T040 `error.SkipZigTest`, T050 missing `BPM_TEST_DB_URL`, T060 unprefixed tenant creation) — those are distinct checks, addressed in their own runs.
- **Out of scope:** changing the **meaning** of any test, the assertions it makes, or the requirement IDs it covers. Each test's behaviour before and after this migration must be identical against a stable fixture.
- **Out of scope:** `src/design/` files that are not the present one. Only this artefact is added in this turn.

## Public interface

The migration introduces **no new public API**. It consumes the existing `TestHarness` API verbatim:

```zig
// tests/integration/helpers.zig — unchanged by this design
pub const TestHarness = struct {
    // ...existing fields...

    /// ISS-0121 / GH-387. Allocation-free; returns a fresh 16-byte UUID v4
    /// from the CSPRNG wrapped by `bpm.uuid`. Suitable for hot MUST-test
    /// fixtures and for any site that needs the binary UUID form.
    pub fn newUuid(self: *TestHarness) bpm.uuid.Uuid;

    /// ISS-0121 / GH-387. Allocates the canonical 36-byte hyphenated
    /// representation. Caller owns the returned slice and MUST release it
    /// with `defer allocator.free(id)` at the call site.
    pub fn newUuidString(self: *TestHarness, allocator: std.mem.Allocator) ![]u8;
};
```

No new helper signatures are added (see §6). The existing `uniqueName(allocator, h, prefix)` helper in `event_store_integration_test.zig` already shows the canonical allocation pattern (allocate → `defer free` → reuse). The 13 platform-admin `user_id` retentions use the existing literal `"00000000-0000-0000-0000-000000000001"`; no new constant is introduced.

## Substitution rules (CONVERT sites — 171 of 184)

A CONVERT site is any T010 finding whose literal is a fixture identifier that does not encode a documented system identity. Each follows exactly one of the four shapes below.

### S1 — Test body needs `bpm.uuid.Uuid` (binary 16 bytes)

Used when the call site passes the value to a Zig function whose parameter is `bpm.uuid.Uuid` (e.g. `Store.append`, `Store.read`, `pool.exec` with `$1::uuid` casts after the value has been hex-decoded).

```zig
// Before
const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000001");

// After
const actor_uuid = h.newUuid();
```

`newUuid` is allocation-free and infallible — no `try`, no `defer`. The harness reference `h` is already in scope because every test in the 45 affected files opens with `var h = try TestHarness.init(alloc);`.

### S2 — Test body needs a heap-allocated UUID string (text SQL / `$1` placeholder)

Used when the literal is bound as a parameter to `pool.exec(query, &.{...})` or `conn.exec(query, &.{...})` whose SQL does not contain an explicit `$N::uuid` cast — the cast is the call site's responsibility, not the helper's.

```zig
// Before
const inst_str = "e5010000-0001-0000-0000-000000000001";
try insertInstance(&pool, inst_str, def_str);
defer cleanupInstance(&pool, inst_str, &.{"es01-idem-01"});

// After
const inst_str = try h.newUuidString(alloc);
defer alloc.free(inst_str);
const def_str = try h.newUuidString(alloc);
defer alloc.free(def_str);
try insertInstance(&pool, inst_str, def_str);
defer cleanupInstance(&pool, inst_str, &.{"es01-idem-01"});
```

**Critical allocation rule** (from `helpers.zig` line 882 comment): the caller owns the returned slice. The pattern `try h.newUuidString(alloc); defer alloc.free(slice);` is required at every call site. The existing `uniqueName` helper (lines 104–110 of `event_store_integration_test.zig`) is the reference implementation:

```zig
fn uniqueName(allocator: std.mem.Allocator, h: *TestHarness, prefix: []const u8) ![]u8 {
    const id = try h.newUuidString(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, id });
}
```

### S3 — File-scope `const inst_str = "..."` shared by multiple `test` blocks

`event_store_integration_test.zig` declares ~20 such constants (`const inst_str = "e5010000-…"`) at the top of each test block; they are local to the block, not truly file-scope. There is **no** file-scope shared UUID literal in the affected files — every literal is owned by exactly one `test` block. S3 therefore degenerates to S2 in this codebase: each `const inst_str = "…"` becomes `const inst_str = try h.newUuidString(alloc); defer alloc.free(inst_str);` inside its block.

The migration does **not** introduce a per-file helper named e.g. `makeInstId(alloc, h)` unless a single file has 10+ identical-shape sites that would otherwise duplicate the `try ... defer free` pair — and the diagnosis shows no file qualifies (the maximum is `event_store_integration_test.zig` with 59 sites spread across 17 `test` blocks, none of which share the literal across blocks). BACKEND-DEV MAY introduce such a helper as a quality-of-life refactor, but it is not required for correctness and MUST not change test semantics.

### S4 — Literal embedded inside an expected-string assertion

When a UUID literal appears inside an `std.testing.expectEqualStrings` / `expect(mem.eql(...))` expected value — for example a JSON blob whose embedded UUID is the **documented** identity being asserted — substitution is impossible without changing the test's intent. The fix here is **retention** with a comment, covered by R1 below, not substitution.

## Retention rules (RETAIN sites — 13 of 184)

All 13 RETAIN findings in the diagnosis are the literal `00000000-0000-0000-0000-000000000001`, used as the conventional platform-admin `user_id`. They appear in:

| File | Line | Role |
|---|---|---|
| `api03_instance_read_test.zig` | 66 | `cancel_actor_uuid` for `cancelInstance` API call |
| `adp07_agent_role_reserved_usernames_test.zig` | 37 | `actorForTenant(...).user_id` for PLATFORM_ADMIN role assertion |
| `adp04_user_tenant_binding_test.zig` | 38 | `actorForTenant(...).user_id` for PLATFORM_ADMIN role assertion |
| `ee08_cancel_instance_test.zig` | 46 | `actor_uuid` for cancel call |
| `sch01_timer_creation_test.zig` | 29 | `actor_uuid` for timer creation call |
| `env01_test.zig` | 132 | `actor_user_id` for env-setup request |
| `ext05_sub_process_support_test.zig` | 22 | sub-process actor |
| `idn02_group_management_test.zig` | 50 | platform-admin group operation actor |
| `idn04_api_token_management_test.zig` | 34 | platform-admin token-issuance actor |
| `tm01_tenant_list_test.zig` | 48 | platform-admin tenant-list request actor |
| `idn01_user_registry_test.zig` | 37 | platform-admin user-registry request actor |
| `idn03_role_access_test.zig` | 47 | platform-admin role-access request actor |
| `instance_error_test.zig` | 761 | platform-admin error-path actor |

### R1 — Conventional platform-admin `user_id` constant

```zig
// Before (no comment)
.user_id = "00000000-0000-0000-0000-000000000001",

// After (audit comment added, literal unchanged)
// GH-512 retention: conventional platform-admin user_id (system actor);
// preserve identity semantics for RBAC/role-guard assertions and for
// production-default-tenant seed rows that resolve this UUID.
.user_id = "00000000-0000-0000-0000-000000000001",
```

The retention comment is added **immediately above** the field assignment (or the local `const cancel_actor_uuid = "..."` declaration that feeds it). One comment per logical concept; if the same literal appears twice in the same test file, the second occurrence does **not** get a duplicate comment if the first is within ~30 lines and visible — see the edge-case rule in §7.

### R2 — Identical literal in multiple test blocks of one file

If `tests/integration/idn02_group_management_test.zig` carries the platform-admin literal in both an early block and a later block, treat both as **one** retention entry for the file: the comment goes on the first occurrence; the second occurrence is left without comment (the audit is satisfied by the first). This matches the diagnosis's "one RETAIN entry per logical concept" rule, not the linter's per-line rule.

### R3 — Literal inside an SQL `DEFAULT` or expected-identity JSON

Not applicable to the current 184-finding set, but documented for future use: if a literal appears inside an `INSERT … DEFAULT '…'` clause or inside an expected-JSON body in `std.testing.expectEqualStrings`, retain it with the comment `// GH-512: keep as system constant: <reason>` (different wording than R1 to make the two intents greppable). The current set has no R3 sites.

## Migration order (batch plan)

The diagnosis YAML (`docs/issue-reports/ISS-0181-gh512-diagnosis.yaml`) gives the per-file counts; BACKEND-DEV converts in this order. The batches are sized so that each one delivers a clean diff that the linter can re-baseline in isolation, and so that the highest-impact file is converted first to surface any latent compilation errors early.

### Batch 1 — `event_store_integration_test.zig` (59 CONVERT, 0 RETAIN)

- Single file, 17 `test` blocks. Each block owns a `const inst_str` / `const def_str` / `const actor_str` triple (or `parseUuid` calls into those strings).
- Apply S1 / S2 uniformly. The existing `uniqueName` helper shows the allocation pattern verbatim.
- After this batch the linter's T010 count drops from 184 to 125.

### Batch 2 — High-volume single files

| File | CONVERT | RETAIN |
|---|---|---|
| `test_snapshot_integration.zig` | 10 | 0 |
| `obs06_alerts_test.zig` | 9 | 0 |
| `oidc16_26_agent_lifecycle_foundations_test.zig` | 8 | 0 |
| `ext02_webhook_dispatch_test.zig` | 7 | 0 |
| `oidc15_realm_deletion_test.zig` | 6 | 0 |

These six files contribute 40 CONVERT sites. After Batch 2 the running T010 count is 85.

### Batch 3 — Medium-volume files (3–5 findings each)

| File | CONVERT | RETAIN |
|---|---|---|
| `api02_crud_test.zig` | 5 | 0 |
| `api03_instance_read_test.zig` | 4 | 1 |
| `oidc09_jit_provisioning_test.zig` | 5 | 0 |
| `adp07_agent_role_reserved_usernames_test.zig` | 3 | 1 |
| `ee03_ee04_tasks_api_test.zig` | 4 | 0 |
| `oidc11_identity_stability_test.zig` | 4 | 0 |
| `adp04_user_tenant_binding_test.zig` | 2 | 1 |
| `adp10_agent_io_capture_audit_test.zig` | 3 | 0 |
| `ee08_cancel_instance_test.zig` | 2 | 1 |
| `oidc14_realm_provisioning_test.zig` | 3 | 0 |
| `sch01_timer_creation_test.zig` | 2 | 1 |

Eleven files contribute 37 CONVERT sites. After Batch 3 the running T010 count is 48.

### Batch 4 — Small files (1–2 findings each)

28 files, 32 CONVERT sites, 8 RETAIN sites. Apply S1 / S2 uniformly and add the R1 retention comment where applicable. After Batch 4 the running T010 count is 16 (13 RETAINs + 3 likely stragglers from edge cases — see §7).

### Batch 5 — Edge cases

The diagnosis predicts three categories that may surface during conversion. None change the conversion/retention totals but each needs a one-off comment + verification:

1. **Multiple identical literals across blocks of one file** → R2 applies: one retention comment, not two.
2. **Literal embedded in an `expectEqualStrings` expected JSON** → R3 applies with `// GH-512: keep as system constant:` wording.
3. **Literal embedded in a `defer` cleanup string** (e.g. `defer cleanupInstance(&pool, inst_str, &.{"es01-idem-01"})` where the same `inst_str` was used at the call site) → the `defer` slice is bound at defer-registration time, so as long as `inst_str` lives until end-of-block, the substitution works; BACKEND-DEV must verify each `defer` references the post-conversion `inst_str`, not a stale pre-conversion literal. This is a syntactic-only check; no semantic risk.

After Batch 5 the running T010 count is **0** for CONVERT sites; **13** for RETAIN sites remain in the baseline with auditable comments.

## API additions to TestHarness

**None.** The existing `newUuid()` and `newUuidString(allocator)` signatures cover all 171 CONVERT sites. BACKEND-DEV does not introduce `newTenantUuid`, `newActorUuid`, or any other specialised helper — the linter rule is purely lexical (any quoted 36-hex-dash UUID except the all-zeros sentinel), and there is no semantic distinction in the linter's eyes between "instance" and "actor" UUIDs. Specialised helpers would add API surface without retiring a single BLOCKER.

If, during implementation, BACKEND-DEV identifies a recurring need for a typed helper (e.g. `pub fn newUuidStringFor(self, allocator, comptime kind: enum { instance, actor, def })`), they MUST file a follow-up ISS via `fn:enqueue-issue` rather than expanding the helpers.zig API inside this WF-03 run. Scope boundary applies.

## Error taxonomy

The migration itself does not introduce new error paths; it consumes the existing API whose error types are:

| Error site | Source | Recovery |
|---|---|---|
| `h.newUuid()` | none (infallible, allocation-free) | n/a |
| `h.newUuidString(allocator)` | `error.OutOfMemory` from `bpm.uuid.newUuidV4(allocator)` | propagate via `try`; test fails fast with allocator diagnostics from `std.testing.allocator` |
| `TestHarness.init(allocator)` | existing | unchanged |
| `parseUuid(allocator, s)` | kept where still used (e.g. for `00000000-0000-0000-0000-000000000001` decoded for some binary-UUID parameter type — see §7) | unchanged |

**Pre-existing error semantics are preserved.** The only behavioural change at any site is "the UUID value is now random per test run instead of a literal". Tests that asserted the literal form (e.g. equality against a JSON blob containing `e5010000-0001-0000-0000-000000000001`) either retain the literal (R3) or are out of scope (no current site asserts the literal form).

## Validation criteria

The design is "done" when **all** of the following hold simultaneously:

1. **Linter clean.** `python3 tools/lint_test_isolation.py --no-baseline tests/integration` reports `BLOCKER=0` from T010 specifically. Other classes (T020 / T030 / T050 / T060) are out of scope and their counts are unchanged within tolerance. The T010 count drops from 184 → 13.
2. **Baseline shrinkage.** `tools/lint_test_isolation.baseline.json` shrinks from 225 entries → 54 entries: 13 RETAIN T010 + 22 T050 + 11 T020 + 2 T060 + 6 T030 = 54. No entry's `severity`, `code`, `file`, or `message` field is altered; only `line` numbers may shift if BACKEND-DEV moves code. The "diff on (severity, code, file, message) ignoring line" check from the baseline's `regeneration_note` returns 0 new findings.
3. **Compile green.** `zig build test` exits 0. This validates the unit-test surface, including any helper signatures touched by the migration (none expected; see §6).
4. **Integration green or within tolerance.** `zig build test-integration-others-internal` exits 0. The pre-existing red set tracked in `docs/issues/` (GH #482, #479, #427, #424, #423, #418, #417) must NOT regress — i.e. the post-migration failure set must be a subset of the pre-migration failure set, not a superset. If any of those tests newly fails after the migration, the change is rolled back at the file level and routed to ISSUE-FIXER.
5. **No `error.SkipZigTest` added.** Every MUST-requirement test that ran before the migration must still run; no test is skipped to make the linter green.
6. **No shared-schema-script touched.** `src/**` and `migrations/**` are unchanged. The only files modified are the 45 integration tests listed in the diagnosis. `git diff --name-only origin/main...HEAD` must contain exactly the union of: (a) 45 `tests/integration/*.zig` files, (b) this design file (if committed), and (c) the regenerated baseline.
7. **Comment audit.** Every RETAIN literal is preceded by a `// GH-512 retention:` comment. A simple `grep -rn "GH-512 retention" tests/integration | wc -l` must equal 13 (or fewer if R2 collapses duplicates — see §7).

## Risks & edge cases

### Compile-time constants cannot reference runtime helpers

If any of the 45 files declares a literal inside a `comptime { ... }` block, an `const X: [N]u8 = .{ ... }` initialiser, or as a default value for a `const` declared at file scope (outside any `test` block), substitution is impossible. The diagnosis did not flag any such site, but BACKEND-DEV MUST run a sanity grep before completing:

```bash
grep -nE '^\s*const\s+[A-Za-z_][A-Za-z0-9_]*\s*[:=].*"[0-9a-f]{8}-' tests/integration/*.zig
```

Every match should fall inside a `test "..." { ... }` block. If any matches at file scope, flag it to ORCH before proceeding; the resolution is either (a) move the declaration into a `test` block, (b) replace with `h.newUuidString(alloc)` invoked from inside a `test` block, or (c) escalate to CODE-DESIGNER for a non-trivial refactor.

### Shared schema bootstrapper scripts must be untouched

Files under `tests/integration/_fixtures/` (if any are introduced by ISS-0605 / GH-537 in the future) are excluded from the lint scan via the `_fixtures` directory allowlist (`lint_test_isolation.py` line 41) and MUST NOT be modified by this migration. None of the current 184 findings are in `_fixtures/`, but BACKEND-DEV must verify by listing files before editing:

```bash
find tests/integration/_fixtures -type f -name '*.zig'  # must return empty or pre-existing
```

### The 13 platform-admin `user_id` occurrences must NOT be converted

Converting any of them would break production code that resolves the constant (R1's whole point). The diagnosis explicitly classified all 13 as RETAIN; BACKEND-DEV MUST respect that classification even if a generic "convert everything" script is tempting. The linter will still report these 13 entries as BLOCKER T010 — that is expected, and they remain in the baseline with retention comments.

### One test file may legitimately contain the same literal for the same logical concept

`tests/integration/idn02_group_management_test.zig` and `idn04_api_token_management_test.zig` both carry `11111111-1111-1111-1111-111111111111` (the conventional "user A" fixture for identity-binding tests). These are NOT platform-admin and are NOT in the RETAIN set — both convert. R2 only applies to the 13 RETAIN platform-admin literals, which appear once per file.

### `parseUuid` may still be needed after migration

A small number of test bodies take a `bpm.uuid.Uuid` parameter type and need the binary form. They previously called `parseUuid(alloc, "literal")` which already allocates a 16-byte buffer. After conversion they call `h.newUuid()` directly — no `parseUuid` and no allocation. If any site needs both the **string** form (for SQL) and the **binary** form (for a struct field), BACKEND-DEV MUST allocate the string once, use it for SQL, and convert it to bytes for the struct (e.g. via `bpm.uuid.parseUuidStr(slice) !bpm.uuid.Uuid` if that helper exists in `src/uuid.zig` — BACKEND-DEV should check; the alternative is to keep `parseUuid` and feed it the freshly-allocated string). Both are zero-cost relative to the SQL round-trip; either is acceptable.

### The `defer cleanupInstance(&pool, inst_str, ...)` pattern

Every test in `event_store_integration_test.zig` that uses `inst_str` registers a `defer cleanupInstance(&pool, inst_str, &.{...})` that runs after the test's transaction has been rolled back. The cleanup runs against the **autocommit** pool — it must still see the row that the test inserted, and the `inst_str` slice must remain valid until the cleanup runs. The migration replaces `const inst_str = "e5010000-…"` with `const inst_str = try h.newUuidString(alloc); defer alloc.free(inst_str);` and the cleanup defer is registered **after** the new `defer alloc.free` so the order of execution on scope exit is: `cleanupInstance` first (still holds a valid slice), then `alloc.free`. BACKEND-DEV MUST verify this ordering at every site — getting it wrong produces a use-after-free in test teardown.

## Effort estimate

| Batch | Files | Sites | Estimated minutes |
|---|---|---|---|
| 1 — `event_store_integration_test.zig` | 1 | 59 | 35 |
| 2 — High-volume single files | 5 | 40 | 25 |
| 3 — Medium-volume files | 11 | 37 | 25 |
| 4 — Small files | 28 | 32 | 20 |
| 5 — Edge-case verification | (rolled into batches) | — | 10 |
| Regenerate baseline + lint + zig build test + integration smoke | — | — | 15 |
| **Total** | **45** | **171 + 13 RETAIN** | **130 minutes** |

### Surface area: **medium**

- Touches 45 files, all under `tests/integration/`, with no production code change.
- Recurring edit pattern (`try h.newUuidString(alloc); defer alloc.free(slice);`) means each site takes ~30s on average; the high-volume batches benefit from copy-paste with line-number adjustment.
- Risk concentrated in `event_store_integration_test.zig` (Batch 1) where the `defer` ordering rule applies — see Risks §7 above.
- The retention-comment addition is mechanical and review-friendly.

### Difficulty rating: **Standard (3)**

Per `docs/metrics/estimation_rules.json` Step 1 budgets, a Standard-difficulty implementation step is ~30–45 minutes; this run is the largest mechanical migration of fixtures in the repo to date. Surcharge: medium (touches 45 files but no call-site signature changes; the "module" boundary is `tests/integration/`, not `src/**`). Estimated 130 minutes for the implementation step plus the standard test/validate/merge overhead, which `docs/agents/workflows/WF-03_issue_resolving.md` adds on top.

## Dependencies and forbidden dependencies

### Reads from (dependencies — may be modified in this run)

| Path | Why |
|---|---|
| `tests/integration/*.zig` (45 files) | The sites being converted or annotated |
| `tools/lint_test_isolation.baseline.json` | Regenerated after Batch 5 to reflect the 171-line shrinkage |
| `tools/lint_test_isolation.py` | NOT modified. Only invoked to regenerate the baseline. |
| `tests/integration/helpers.zig` | NOT modified. API surface already complete. |
| `src/design/iss0181-gh512-t010-migration.md` | This artefact. Added by CODE-DESIGNER. |

### Reads from (forbidden to modify)

| Path | Why forbidden |
|---|---|
| `src/**` | Production code. Out of scope for a fixture migration. |
| `migrations/**` | No schema change is required; the literals are client-side fixture values, not DB-level identities. |
| `tests/specs/**`, `tests/unit/**`, `web/**` | Out of scope for T010 (which only scans `tests/integration/`). |
| `infrastructure/**`, `web/src/**`, `tools/codegen_*` | Out of scope. |
| `handoffs/orchestrator.log` | Read for ROUTE/COMPLETE patterns; only `append`ed, never rewritten. |
| `handoffs/registry.json` | Only updated to add the step-02 handoff entry. |

### External dependencies (unchanged by this design)

- `bpm.uuid.generateUuidV4BytesInto(*[16]u8)` — CSPRNG backing for `newUuid`. Same source as the platform's process-tag generator (`helpers.zig` line 482), so concurrent test binaries already get distinct values without coordination.
- `bpm.uuid.newUuidV4(allocator)` — canonical 36-byte string allocator. Already used by `uniqueName` in `event_store_integration_test.zig` (Batch 1 reference implementation).
- `BPM_TEST_DB_URL` — the integration test database URL; required for the `zig build test-integration-others-internal` validation gate.

## Open questions

1. **`tests/integration/_fixtures/` allowlist** — `lint_test_isolation.py` line 41 references `_fixtures` directory exclusion. As of this design's authoring, no `_fixtures/` directory exists in the repo. If ISS-0605 / GH-537 lands between this design's authoring and its execution, BACKEND-DEV MUST re-verify the file list to ensure no `_fixtures/` file is being converted in error. Resolution: re-run the `find tests/integration/_fixtures -type f -name '*.zig'` check at the start of Batch 1.
2. **Comment-collapsing policy** — R2 says "one comment per logical concept per file". If a future reader finds that surprising (e.g. they grep for `GH-512 retention` and find 12 instead of 13 lines), the rule is documented but the comment count is the count of logical concepts, not literal occurrences. No code change needed; this is documentation only.
3. **Helper-API expansion** — if any batch reveals a recurring typed-UUID need (e.g. all actor_id sites want a typed wrapper), the API expansion is filed as a follow-up ISS rather than expanded inside this WF-03 run. Scope boundary applies.

## Acceptance mapping

| Acceptance criterion (from handoff) | Mapped to |
|---|---|
| 184 T010 findings are either CONVERT or RETAIN with reasons | §3 (171 CONVERT) + §4 (13 RETAIN) + §5 batching order |
| Baseline shrinks by CONVERT count, gains zero new entries | §5 Validation criteria #2 — shrinkage arithmetic 225 → 54 |
| Pre-existing failures (#482, #479, #427, #424, #423, #418, #417) not regressed | §5 Validation criteria #4 — subset, not superset |
| `zig build test-env-verify` still exits 0 | §5 Validation criteria #3 (compile green) — proxy for the env-verify gate's compile precondition |
