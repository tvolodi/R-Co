# Security Invariants — BPM Platform

**Audience:** every agent in the pipeline, under every harness. This file is the canonical
location for the platform's hard security constraints. It replaces the four "Security rules
(hard constraints)" that used to live only inside `CLAUDE.md`'s BACKEND-DEV section — where
FRONTEND-DEV and ISSUE-FIXER never read them, despite both routinely touching tenant-data
paths (FRONTEND-DEV renders API responses; ISSUE-FIXER diagnoses production defects that are
frequently isolation bugs — see the `ISS-01xx` schema-scoping series below).

**Status:** AUTHORITATIVE for security constraints. Where this file and any other doc
disagree on a security rule, this file wins — flag the discrepancy as a MINOR issue in your
handoff so the drift gets fixed at the source, the same convention used by
`docs/agents/shared/HANDOFF_PROTOCOL.md`.

**Why now (GH-292 / ISS-0077 / PI-02).** This is a multi-tenant platform running two
untrusted embedded runtimes (Lua, Wasm) for tenant-authored scripts. The 92 platform
requirements include tenant-isolation-critical ones — `FIL-06` (cross-tenant attachment
probes), `QRY-04` (unauthorised entity types), `SBX-05` (sandbox probe sentinel),
`CAC-UI-01` (client cache leaks), `DDL-05` (namespace reservation) — and until this file and
the `SECURITY-REVIEWER` agent (`.claude/agents/security-reviewer.md`) existed, no gate in the
pipeline checked any of them. They shipped reviewed by nobody.

**How the numbering maps to the four rules that used to live in CLAUDE.md's BACKEND-DEV
section:** those four rules are not dropped — they are folded into the numbered scheme below
so there is exactly one place "the security rules" live, not two diverging copies.
BACKEND-DEV's canonical instructions (`.claude/agents/backend-dev.md`, moved out of
`CLAUDE.md` itself by GH-291/ISS-0076/PI-01) point here instead of restating them. See INV-4
(secrets from environment), INV-7 (no SQL string interpolation — new, was rule 1), INV-8 (no
`catch unreachable` on realistic failure paths — new, was rule 3), and the transition.zig I/O
rule (kept as project-wide guidance directly in `.claude/agents/backend-dev.md`, since it is a
purity constraint on one specific file rather than a tenant-security invariant — it is
cross-referenced from INV-8's Reference for completeness).

---

## How to read this file

Each invariant has four fields:

- **Rule** — the constraint itself, stated so it can be checked, not just admired.
- **Reference** — where this is currently enforced or documented in the codebase, if
  anywhere. Several invariants have **zero automated enforcement today**; that is stated
  plainly rather than implied by a reference that doesn't actually check anything.
- **How to verify** — a concrete, mechanical check. Where a lint script or test file already
  covers it, that command is the check. Where nothing automated exists yet, the manual review
  procedure is given instead, and is marked **(manual — no automated check yet)**.
- **Severity** — all eight invariants below are BLOCKER. On a multi-tenant platform with two
  untrusted runtimes, every one of these is a hard constraint, not a style preference; there
  is no MAJOR/MINOR tier for cross-tenant data exposure or secret leakage.

**SECURITY-REVIEWER gates against this exact list.** See
`.claude/agents/security-reviewer.md` and `CLAUDE.md`'s `## AGENT: SECURITY-REVIEWER`
section for the pipeline step (WF-02, after implementation and before TEST-DESIGNER) that
checks a change against every invariant that applies to it.

---

## INV-1 — Tenant data isolation

**Rule.** Every access to tenant business data is scoped to exactly one tenant, with no
exception for internal, admin, or system-worker paths. On this platform that scoping is
**schema-per-tenant**, not a `tenant_id` row predicate on a shared table: business tables
live exclusively in per-tenant Postgres schemas (`tenant_<slug>`), never in `public`, and the
connection pool sets `search_path` to the caller's tenant schema before any query using that
connection runs. A query that reaches business data through the wrong `search_path`, or a
migration that creates a business table under `public`, is a cross-tenant leak regardless of
whether the SQL text itself contains a `tenant_id` column reference.

**Reference.**
- `src/api/tenant_context.zig` — `set(tenant_id)` (36-char UUID validation) establishes the
  tenant context consumed by the pool on checkout.
- `src/db/pool.zig` — `schemaNameForTenant`; applies `SET search_path` per connection
  checkout per the tenant context (see `tests/integration/tnt_schema_isolation_test.zig`
  TNT-03: "Connection pool sets search_path per tenant on checkout").
- `src/db/provisioning.zig` — `provisionTenantSchema`, the schema-creation path.
- `tests/integration/tnt_schema_isolation_test.zig` — TNT-01..TNT-04: business tables in
  per-tenant schemas, migration runner schema-path enforcement, pool search_path behaviour,
  and a startup audit of what's permitted in `public`.
- 21 business tables are enumerated as schema-restricted in `tools/lint_migration_schema.py`
  (`BUSINESS_TABLES`).
- `docs/anti-patterns.md` documents at least two recurrence incidents of this exact class
  (GH #335 / ISS-0076 migration guard silently no-op'ing against the wrong schema; GH #338 /
  ISS-0089 an integration test resolving to the wrong schema via ambient `search_path` and
  recurring identically after its first fix) — this is a class of bug that has already shipped
  twice, not a hypothetical.

**How to verify.**
```bash
# Migration files: no business table created/referenced under public. schema.
python3 tools/lint_migration_schema.py         # exit 0 required, BLOCKER on violation

# Zig/test source: no lingering reference to a table renamed off public in the TNT migration.
python3 tools/lint_sql_table_refs.py            # exit 0 required

# Runtime behaviour: schema-per-tenant isolation itself (requires BPM_TEST_DB_URL locally;
# runs automatically in CI's `tenant_isolation_tests` job on every push/PR — see below).
zig build test-integration-tnt
```
Automated for all three: the two static-scan cases above, and — as of this file's own
introduction (GH-292 / ISS-0077 / PI-02) — the runtime isolation property itself via the
`tenant_isolation_tests` CI job (`.github/workflows/ci.yml`), which provisions a fresh
PostgreSQL service, runs `zig build migrate`, then `zig build test-integration-tnt`, on
every push/PR to `main`. Before this job existed, `tnt_schema_isolation_test.zig` ran only on
a developer's own database and never gated a PR — see INV-6.

**Severity.** BLOCKER.

---

## INV-2 — Server-side field authorisation

**Rule.** Field-level visibility is enforced by the server before a response is serialised.
The SPA is never the authorisation boundary — it may hide fields for UX reasons, but an
unauthorised field must never leave the server in the first place. A response payload that
relies on the frontend to omit or grey out a field it already received is a defect regardless
of whether the current UI happens to hide it correctly.

**Reference.**
- `QRY-04` (`docs/requirements.yaml`, "Empty envelope for unauthorised entity types") —
  requires the API to return an empty/authorised-only envelope rather than a full payload the
  client is expected to filter.
- `CAC-UI-01` (`docs/requirements.yaml`, "Tenant segment in every query key") — the client
  cache-key discipline that stops a stale unauthorised payload from leaking across a tenant
  switch inside a single browser session; this is the client-side complement to the
  server-side stripping rule, not a substitute for it.
- `src/api/routes/entities.zig`, `src/api/routes/tenant_config.zig` — response-shaping call
  sites for entity/tenant-scoped payloads.

**How to verify.** **(manual — no automated check yet).** No linter currently distinguishes
"server stripped the field" from "server sent it and the SPA hid it." Manual review procedure
for SECURITY-REVIEWER: for any new or changed API response type touching tenant-scoped data,
trace the handler function and confirm the struct/field selection happens before
serialisation (i.e. unauthorised fields are never assigned into the response value), not as a
post-hoc redaction pass on a client-visible object, and not left to a frontend conditional
render. Grep the diff for response structs that include more fields than the
route's documented authorisation level, e.g.:
```bash
git diff main... -- 'src/api/routes/*.zig' | grep -n "pub const .*Response"
```
then manually cross-check each new/changed response struct's fields against the caller's
actual authorisation grant.

**Severity.** BLOCKER.

---

## INV-3 — Untrusted runtime sandboxing

**Rule.** Tenant-authored scripts execute only inside the Lua or Wasm sandbox, gated by the
host capability allowlist. No ambient network access, no filesystem access, and no host
function is reachable unless the script's declared/granted capability set explicitly includes
it. A script must not be able to reach any host function, network socket, or file descriptor
that its capability grant does not name.

**Reference.**
- `src/lua/capabilities.zig` — `CapabilitySet` (string-grant allowlist: e.g.
  `service:call:payment`, `variable:read`); every `platform.*` host function checks its
  capability before executing.
- `src/lua/host_api/` and `src/lua/host_context.zig` — the host-function boundary Lua scripts
  cross through; this is the only path in.
- `src/lua/instruction_limiter.zig`, `src/lua/memory_limiter.zig`, `src/lua/timeout.zig` —
  resource-exhaustion bounds, a companion constraint to capability scoping (an unbounded
  tenant script is also a platform-availability risk, not just a data-access risk).
- `src/wasm/capabilities.zig` — `StandardCapabilities` + wildcard-matching `CapabilitySet` for
  Wasm modules; capabilities are validated against declared module capabilities at
  registration, and only matching host functions are provided at instantiation.
- `src/wasm/host_api/`, `src/wasm/instance.zig`, `src/wasm/pool.zig` — the Wasm instantiation
  boundary and per-instance isolation.
- `src/lua/capability_enforcement_test.zig` — capability-denial tests.
- `tests/simulation/scenarios/platform/platform-sandbox-cross-tenant-probe.yaml` — the
  business-level scenario (`SBX-05`-adjacent) that a workspace-holding worker cannot be probed
  or hijacked cross-tenant.

**How to verify.**
```bash
zig build test-lua        # capability_enforcement_test.zig + sibling Lua sandbox tests
zig build test-misc-unit  # tests/unit/lua_test.zig and wasm_executor_test.zig
```
Automated for capability-grant enforcement at the host-API boundary. **(manual — no automated
check for "no network/disk reachable at all" as a blanket property)**: SECURITY-REVIEWER must
manually confirm any new host-API function added to `src/lua/host_api/` or `src/wasm/host_api/`
is capability-gated before merge — grep for new `pub fn` additions under those two directories
in the diff and confirm each checks `CapabilitySet.has`/`hasWildcard` before performing I/O.

**Severity.** BLOCKER.

---

## INV-4 — Secrets by reference only

**Rule.** Secret material is never logged, traced, included in error messages, or serialised
into any payload — API response, audit record, webhook body, or handoff file. Code that needs
to use a secret resolves a `sec://` reference at the point of use; it never threads the
resolved plaintext through a return value, log call, or struct field that could be
serialised. This also folds in the former "No secrets in source. All credentials from
environment variables" rule — that constraint on *configuration* secrets (DB URLs, Keycloak
client secrets, etc.) and this constraint on *tenant* secrets (webhook keys, service
credentials, ISS-0074/GH-289's plaintext-storage finding) are the same rule applied to two
different secret populations, so they are stated together here rather than split.

**Reference.**
- `src/secrets/reference.zig` — `SecretRef`, `parseSecretRef` — the canonical
  `sec://tenant/<tenant>/<namespace>/<name>#<key_id>` reference format. Code holds this
  reference, not the plaintext.
- `src/secrets/store.zig` — `Store`, `putSecret`/`resolveSecret`; the only place plaintext
  secret material is materialised, and only for the duration of the resolving call.
- `src/secrets/redaction.zig` — `redactSecretRefForLog` (masks the key id: `...#***`),
  `assertNoSecretMaterialInLogFields` (rejects log payloads containing `secret`, `password`,
  `client_secret`, or `token` substrings, case-insensitive).
- `src/secrets/crypto.zig` — encryption at rest for stored secret material.
- `src/secrets/integration/webhook_keys.zig` — a concrete consumer using the reference
  pattern rather than holding plaintext.
- Config secrets (the pre-existing "no secrets in source" half of this rule): read from
  environment variables per `src/config/loader.zig` and `src/config/identity_provider.zig`;
  never hardcoded.
- Prior art: ISS-0074 / GH-289 (plaintext tenant-secret storage) is the incident that
  motivated `src/secrets/` existing at all — this invariant is that fix's condition made
  permanent, not a new idea.

**How to verify.**
```bash
# Log/trace/payload redaction unit coverage:
zig build test-crypto-iss0074   # ISS-0074 secrets/crypto.zig unit tests
zig build test                  # umbrella step; also runs redaction.zig/store.zig in-file tests

# Manual check for config-secret hardcoding (no dedicated linter yet):
grep -rn "client_secret\s*=\s*\"" src/ --include=*.zig
grep -rn "password\s*=\s*\"" src/ --include=*.zig
```
Automated for the redaction/reference-format unit tests. **(manual — no automated check yet)**
for "never serialised into a handoff file or audit payload" as a whole-system property —
SECURITY-REVIEWER must manually grep any new/changed struct that gets JSON/YAML-serialised
(API responses, audit records, webhook bodies) for a field typed as raw secret material
rather than a `SecretRef`.

**Severity.** BLOCKER.

---

## INV-5 — Not-found/forbidden indistinguishability

**Rule.** A cross-tenant probe against a resource that exists (but belongs to another tenant)
returns a response indistinguishable from probing a resource that has never existed: one
sentinel body, one HTTP status code, no timing or content signal that lets the prober
distinguish "exists, not yours" from "never existed." This is the platform's specific defence
against enumeration/probing attacks across tenant boundaries.

**Reference.**
- `FIL-06` (`docs/requirements.yaml`, "Probe-safe cross-tenant attachment reads").
- `SBX-05` (`docs/requirements.yaml`, "Single sentinel for inaccessible sandboxes").
- `tests/simulation/scenarios/platform/platform-attachment-cross-tenant-probe.yaml` — business
  scenario for FIL-06.
- `tests/simulation/scenarios/platform/platform-sandbox-cross-tenant-probe.yaml` — business
  scenario for SBX-05 (EO-001: "The answer the second company's worker receives for the first
  company's workspace is identical to the answer it receives for a workspace that has never
  existed. Nothing in either answer distinguishes them." — severity BLOCKER in the scenario
  itself, matching this invariant's severity here).

**How to verify.** **(manual — no automated unit/integration-level check yet; only the
business-level UAT scenarios above exercise it, and those run under WF-05, not on every PR)**.
SECURITY-REVIEWER must manually confirm, for any new or changed lookup-by-ID endpoint that
resolves tenant-scoped resources: (1) the not-found and forbidden-cross-tenant code paths
return the exact same status code and body shape (diff the two response constructions in the
handler), (2) no `else` branch or logging distinguishes the two cases in a way an attacker
could observe (timing included — a cross-tenant existence check that short-circuits before an
equivalent not-found check would do the same DB round-trips is itself a signal). A dedicated
integration test asserting response-byte-equality between the two cases for any given
resource type is the natural gap to close as a follow-up; note that gap explicitly in
SECURITY-REVIEWER's finding if no such test exists for the resource type under review, per
INV-6.

**Severity.** BLOCKER.

---

## INV-6 — New data-access paths prove their scoping

**Rule.** Every new data-access path (a new API route, a new Lua/Wasm host function that
touches tenant data, a new migration introducing a business table, a new report/export path)
must demonstrate its tenant scoping to SECURITY-REVIEWER before it merges. "It compiles and
the happy-path test passes" is not proof of scoping; the proof is an explicit statement of
which invariant(s) above apply and how the implementation satisfies each one.

**Reference.** This is the meta-invariant that the `SECURITY-REVIEWER` agent exists to
enforce (`.claude/agents/security-reviewer.md`; `CLAUDE.md`'s `## AGENT: SECURITY-REVIEWER`
section; inserted into the WF-02 pipeline after Step 2a/2b implementation, before Step 3
TEST-DESIGNER). There is no separate "Reference" implementation for this one — it names the
gate itself.

**How to verify.** A SECURITY-REVIEWER handoff exists for the change, is `status: PASS`, and
its result explicitly lists which of INV-1..INV-5, INV-7, INV-8 were assessed and why each
either applies-and-is-satisfied or does-not-apply to this specific change. Checked
procedurally by the WF-02 step-table gate itself (a change that touches a tenant-data path
cannot reach TEST-DESIGNER without a completed SECURITY-REVIEWER handoff) — see
`CLAUDE.md`'s WF-02 pipeline table.

**Severity.** BLOCKER.

---

## INV-7 — No SQL string interpolation

**Rule.** All SQL queries use parameterised placeholders (`$1`, `$2`, ...) via `pg.zig`.
User-controlled or tenant-controlled data is never concatenated or interpolated directly into
SQL text. This was rule 1 of the old BACKEND-DEV-only "Security rules (hard constraints)"
list; it is promoted to a numbered, verifiable invariant here because SQL injection is exactly
as severe as the other seven on a multi-tenant platform (a successful injection bypasses
schema-per-tenant isolation entirely, defeating INV-1 outright) and because FRONTEND-DEV and
ISSUE-FIXER need to know this rule exists even though neither writes raw SQL directly —
ISSUE-FIXER in particular diagnoses production defects and must recognise this class on sight.

**Reference.** `docs/guides/backend_developer_guide.md`; every `src/**/*.zig` file issuing
SQL via `pg.zig`'s parameterised query API.

**How to verify.**
```bash
python3 tools/lint_sql_param_types.py src tests   # catches asymmetric type-cast patterns
                                                   # (a related but distinct defect class —
                                                   # PostgreSQL C42883, not injection)
grep -rn "std.fmt.allocPrint.*SELECT\|std.fmt.allocPrint.*INSERT\|std.fmt.allocPrint.*UPDATE\|std.fmt.allocPrint.*DELETE" src/ --include=*.zig
```
`lint_sql_param_types.py` is automated but targets a different defect (asymmetric casts, not
interpolation). **(manual — no automated interpolation-specific linter yet)**: the grep above
is a heuristic starting point, not a complete check — SECURITY-REVIEWER must manually confirm
any SQL-issuing code in the diff uses `$N` placeholders for all variable content.

**Severity.** BLOCKER.

---

## INV-8 — No `catch unreachable` on realistic failure paths

**Rule.** Error handling uses typed error sets; `catch unreachable` is reserved for
conditions that are genuinely impossible given the surrounding invariants (e.g. a `parseInt`
on a string already validated as digits-only), never for external I/O, user input, or
tenant-controlled data — those can always fail and a `catch unreachable` there turns a
recoverable error into a process crash, which on a multi-tenant platform is itself a
cross-tenant availability issue (one tenant's malformed input crashing the process affects
every other tenant's in-flight requests). This was rule 3 of the old BACKEND-DEV-only list;
promoted here for the same reason as INV-7 — a systemic gap that let one tenant's bad input
degrade every other tenant's service is a security invariant, not a style preference.

A related purity constraint — `src/engine/transition.zig` must have zero I/O (it is BPM
Platform's pure-function workflow-transition core) — remains stated directly in `CLAUDE.md`'s
BACKEND-DEV section rather than duplicated here, since it is a single-file architectural rule
rather than a tenant-security boundary; CI enforces it via the `transition.zig in-file tests`
job in `.github/workflows/ci.yml`.

**Reference.** `docs/guides/backend_developer_guide.md`; BACKEND-DEV's self-review checklist
in `CLAUDE.md`.

**How to verify.**
```bash
grep -rn "catch unreachable" src/ --include=*.zig
```
**(manual — no automated check yet distinguishing "genuinely impossible" from "realistic
failure path" — that classification requires reading the surrounding function)**. Every hit
from the grep above must be individually justified by SECURITY-REVIEWER or BACKEND-DEV's own
self-review as touching only a condition that is provably unreachable given prior validation
in the same function; any hit on a path reachable from external I/O, tenant input, or network
data is a BLOCKER finding.

**Severity.** BLOCKER.

---

## Coverage note vs. the six starting invariants

`docs/agents/PIPELINE_BACKLOG.md` PI-02 proposed six invariants (INV-1 through INV-6 above,
unchanged in substance). Reading the codebase surfaced two more that were already stated as
hard rules in CLAUDE.md's BACKEND-DEV section but had no invariant number and no
SECURITY-REVIEWER coverage: SQL string interpolation (INV-7) and `catch unreachable` on
realistic failure paths (INV-8). Both were folded in here rather than left to silently
disappear when the four BACKEND-DEV-only rules were extracted — see the "How the numbering
maps" note at the top of this file. No invariant beyond these eight was added; the six given
in the backlog entry were judged complete for the tenant-isolation/sandbox/secrets surface the
issue named, and the two additions are pre-existing rules being given equal footing, not new
scope.
