# BPM Platform — Architecture Document

**Version:** 0.4-draft
**Scope:** Stages 6.5–11 (in-scope) plus roadmap for future Stages 12–16 (deferred / sketched). Covers identity provider integration, execution layers (DSL, Lua, Wasm), Platform Repository, and Test Runner.
**Audience:** Engineering agents (Claude Code) and human reviewers
**Companion document:** `02-functional-requirements.md`

---

## 1. Purpose and Reading Guide

This document describes the architecture of the BPM Platform — a low-level process execution kernel that doubles as a **software factory** for higher-level business applications (ERP, CRM, HRM, etc.). It covers:

- The layered architecture from infrastructure to business application
- The three-tier execution model (Expression DSL → Lua → Wasm)
- The Platform Repository (versioned artifact store, the "Git of the platform")
- The AI Agent Pipeline (Architect → Developer → DevOps) as the internal CI/CD
- Tenancy, staging vs production, and migration of running instances

**For implementation agents:** Treat this document as authoritative for *what* the system is and *how its parts relate*. The companion `02-functional-requirements.md` is authoritative for *what each part must do*. When the two disagree, the functional requirements win, and a discrepancy report must be raised.

---

## 2. Guiding Principles

These principles resolve ambiguities that requirements cannot anticipate. Every implementation decision should be consistent with all of them.

1. **Event sourcing as ground truth.** No state is stored as mutable rows updated in place. All state is derived by projecting an immutable event log. Read-model tables may exist for performance but are always rebuildable from events.

2. **Explicit over magic.** Every state transition, every variable mutation, every timer firing traces to a specific event in the log. No hidden framework behaviour.

3. **Mechanism, not policy.** The platform provides mechanisms (process execution, scripting, forms, reports). Business applications (CRM, ERP, HRM) provide policy. The platform has no domain knowledge of those applications.

4. **Deterministic kernel, tiered execution.** The platform kernel is deterministic — event append, state transitions, scheduler firing, and audit chaining never make LLM calls. Business logic runs in tiered execution environments hosted by the kernel: Tier 1 (Expression DSL), Tier 2 (Lua), Tier 3 (Wasm), and a future Tier 4 (LLM-driven). The Architect Agent selects the minimum-power tier per node based on logic shape, irreversibility of consequences, and audit requirements. LLM execution at the node level is legitimate when the problem genuinely requires language understanding or judgement; it is not a default.

5. **Capability-based security.** Scripts and modules can only do what the platform explicitly grants them. The default is zero capability. This applies to Lua sandboxes, Wasm imports, and the Expression DSL evaluator.

6. **Versioning is the audit trail.** Every artifact (definition, script, form, report) is versioned. Every running instance is bound to specific artifact versions. Rollback is reactivation of prior versions, never deletion.

7. **Crash safety.** The platform assumes it can be killed at any point. Every write is either fully committed or fully rolled back. No multi-step sequence leaves a partial state without recovery.

8. **Incremental correctness.** Each stage is fully correct and tested before the next begins. Scope is reduced before quality is reduced.

---

## 3. System Context

```
┌────────────────────────────────────────────────────────────────────┐
│                  Business Owners & Operators                        │
│        (state requirements, review artifacts, monitor)              │
└─────────────────────────────┬──────────────────────────────────────┘
                              │ Natural language + UI
┌─────────────────────────────▼──────────────────────────────────────┐
│                      AI Agent Pipeline                              │
│           Architect → Developer → DevOps                            │
└─────────────────────────────┬──────────────────────────────────────┘
                              │ Versioned artifacts
┌─────────────────────────────▼──────────────────────────────────────┐
│                    BPM Platform Runtime                             │
│  ┌───────────┐  ┌───────────┐  ┌──────────┐  ┌────────────────┐   │
│  │   BPM     │  │ Execution │  │  Form    │  │  Projection /  │   │
│  │  Kernel   │  │  Layers   │  │  Engine  │  │  Report Engine │   │
│  └─────┬─────┘  └─────┬─────┘  └────┬─────┘  └────────┬───────┘   │
│        │              │              │                  │           │
│  ┌─────▼──────────────▼──────────────▼──────────────────▼───────┐ │
│  │              Event Store + Platform Repository                │ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────┬──────────────────────────────────────┘
                              │ REST + Webhooks
┌─────────────────────────────▼──────────────────────────────────────┐
│             Business Applications (CRM, ERP, HRM, custom)          │
│                  UI, integrations, reports                          │
└────────────────────────────────────────────────────────────────────┘
```

The platform serves three types of consumers:
- **Business owners** define requirements; the agent pipeline turns them into running processes.
- **End users** interact with business applications, which call the platform REST API.
- **Operators** monitor health, approve promotions, manage rollbacks.

---

## 4. Layered Architecture

### 4.1 Layer Map

```
┌──────────────────────────────────────────────────────────────┐
│  L7. Business Applications                                    │
│      ERP modules, CRM views, HRM workflows, custom apps       │
├──────────────────────────────────────────────────────────────┤
│  L6. Platform API Boundary                                    │
│      REST endpoints, webhook dispatch, OpenAPI spec           │
├──────────────────────────────────────────────────────────────┤
│  L5. AI Agent Pipeline                                        │
│      Architect Agent, Developer Agent, DevOps Agent           │
├──────────────────────────────────────────────────────────────┤
│  L4. Form & Report Engines                                    │
│      Schema-driven forms, event-projection reports            │
├──────────────────────────────────────────────────────────────┤
│  L3. Execution Layers                                         │
│      Expression DSL, Lua sandbox, Wasm runtime                │
├──────────────────────────────────────────────────────────────┤
│  L2. BPM Kernel                                               │
│      Execution engine, scheduler, instance state machine      │
├──────────────────────────────────────────────────────────────┤
│  L1. Persistence & Repository                                 │
│      Event store, artifact repository, schema registry        │
├──────────────────────────────────────────────────────────────┤
│  L0. Infrastructure                                           │
│      PostgreSQL, file storage, process supervisor             │
└──────────────────────────────────────────────────────────────┘

       External, sibling system (not a layer of the platform):
       ┌─────────────────────────────────────────────────────────┐
       │  Identity Provider (Keycloak)                            │
       │  Realms, users, federations, OIDC token issuance         │
       │  Accessed by L6 (token verify) and L5/L6 (provisioning)  │
       └─────────────────────────────────────────────────────────┘
```

Each layer depends only on layers below it. No upward dependencies. No layer-skipping (L5 must not talk to L1 directly; it talks through L2–L4). The Identity Provider is an external system the platform integrates with — it is not part of the layer stack; it sits beside it.

### 4.2 Layer Responsibilities

| Layer | Responsibility | Implementation |
|---|---|---|
| L0 | Run the process, store bytes durably | PostgreSQL 15+, OS, supervisor |
| L1 | Persist events and artifacts atomically; provide read access | Zig + pg.zig |
| L2 | Drive process instances through definitions | Zig (pure transition function + persistence wiring) |
| L3 | Evaluate user-supplied logic safely | Zig host + DSL parser + LuaJIT bindings + Wasmtime embed |
| L4 | Render forms, project reports from events | Zig host + schema registry |
| L5 | Generate artifacts from requirements; provision identity resources | LLM calls + structured I/O; IdentityProvider adapter calls |
| L6 | Expose platform to external consumers; verify OIDC tokens | http.zig + auth middleware + IdentityProvider adapter |
| L7 | Domain-specific applications | Out of platform scope |
| External | Authenticate humans, issue tokens, manage federations | Keycloak (or any OIDC-compliant provider via adapter) |

---

## 5. The Three-Tier Execution Model

A central design choice: business logic generated by the agent pipeline runs in one of three execution environments, chosen by complexity.

```
┌─────────────────────────────────────────────────────────────────┐
│  Tier 3 — Wasm Modules                                           │
│  Complex custom node types, integrations, heavy computation      │
│  Compiled Zig → wasm32 → cached in repository                    │
│  Strict capability sandbox via host imports                      │
│  Compile latency: seconds. Execution: near-native.              │
├─────────────────────────────────────────────────────────────────┤
│  Tier 2 — Lua Scripts                                            │
│  Business rules, task scripts, complex form validation           │
│  Interpreted by embedded LuaJIT, restricted stdlib              │
│  Compile latency: zero. Execution: fast (JIT).                  │
├─────────────────────────────────────────────────────────────────┤
│  Tier 1 — Expression DSL                                         │
│  Gateway conditions, simple field validations, edge transforms   │
│  Parsed and evaluated natively in Zig                           │
│  Compile latency: zero. Execution: native.                      │
└─────────────────────────────────────────────────────────────────┘
```

### 5.1 Tier 1 — Expression DSL

A small, total expression language with no side effects. Used for:
- Gateway transition conditions: `order.total > 10000 and customer.tier == "VIP"`
- Field-level form validation: `field.length > 0 and field.length <= 100`
- Simple variable derivations on edges: `discount = order.total * 0.05`

**Grammar (informal):**
```
expr     := or_expr
or_expr  := and_expr ('or' and_expr)*
and_expr := not_expr ('and' not_expr)*
not_expr := 'not'? cmp_expr
cmp_expr := add_expr (('==' | '!=' | '<' | '<=' | '>' | '>=') add_expr)?
add_expr := mul_expr (('+' | '-') mul_expr)*
mul_expr := unary (('*' | '/' | '%') unary)*
unary    := '-'? primary
primary  := number | string | bool | null
          | identifier ('.' identifier)*
          | '(' expr ')'
          | func_call
func_call := identifier '(' (expr (',' expr)*)? ')'
```

**Built-in functions** (whitelisted, all pure): `length`, `lower`, `upper`, `trim`, `contains`, `startsWith`, `endsWith`, `coalesce`, `now`, `date_add`, `date_diff`.

**No I/O. No loops. No assignments. No user-defined functions.** Total by construction: evaluation cannot diverge, cannot fail except by type error (returned as evaluation result), cannot mutate state.

**Implementation:** Hand-written recursive descent parser in Zig producing an AST. Evaluator walks the AST against a context map. No code generation, no runtime compilation.

### 5.2 Tier 2 — Lua Scripts

Embedded LuaJIT (~800KB). Used for:
- Task scripts (compute, transform, decide)
- Complex multi-field form validation
- Pre/post hooks on task completion
- Custom gateway conditions where DSL is insufficient

**Sandboxing rules (enforced by host, not script):**
- `io`, `os`, `package`, `debug` libraries NOT loaded
- `loadstring`, `load`, `dofile`, `loadfile` removed from global env
- Only `math`, `string`, `table` from stdlib (and pure subsets)
- All platform interaction via host-registered C functions
- Per-script CPU instruction limit (configurable, default 10M instructions)
- Per-script memory limit (configurable, default 16 MB)
- Per-script wall clock timeout (configurable, default 5 seconds)
- Script CPU/memory tracked; exhaustion aborts script with structured error

**Host API (functions registered into Lua state):**
```
platform.read_variable(name) → value
platform.write_variable(name, value)
platform.read_instance_id() → string
platform.read_definition_id() → string
platform.call_service(service_id, payload) → response  -- only if granted
platform.log(level, message, context_table)
platform.now() → timestamp
platform.uuid() → string
platform.fail(reason, details_table)
```

Each `platform.*` function is governed by the script's capability grant (see §8).

### 5.3 Tier 3 — Wasm Modules

Embedded Wasmtime (~5MB static linkage). Used for:
- Custom node type implementations
- Complex integrations with proprietary protocols
- CPU-intensive computations (e.g., schedule optimisation, ML inference)
- Anything where Lua is too slow or too dynamic for the task

**Module ABI (every module must export):**
```
init(config_ptr, config_len) → handle_or_error
execute(handle, input_ptr, input_len) → output_or_error
deinit(handle)
get_capabilities() → capability_list
```

**Host imports (provided to module):**
- `platform_*` functions identical in semantics to Lua API but via Wasm linker imports
- Memory: only the module's own linear memory; no shared memory with host
- No filesystem, no network, no clocks except via host imports

**Compilation pipeline:**
```
Developer Agent emits Zig source
        ↓
Build job compiles: zig build-lib -target wasm32-freestanding -dynamic
        ↓
Output .wasm cached in Platform Repository keyed by source hash
        ↓
At execution time: Wasmtime instantiates from cached module
        ↓
Module runs in isolated linear memory, with explicit imports
```

The platform never recompiles on the execution path. Compilation happens once per source version, during the Developer Agent's build phase.

### 5.4 Tier Selection Rules

The Architect Agent decides the tier per scriptable node by applying these heuristics, in order. The principle is **minimum power**: choose the lowest tier that suffices, biased toward determinism, cheapness, and auditability.

**Logic-shape discriminator (primary axis):**

1. **Pure boolean or arithmetic expression?** → Tier 1 (DSL)
2. **Logic fits in <30 lines of pseudocode, no loops over external data, all paths enumerable?** → Tier 2 (Lua)
3. **Logic is computationally demanding, needs strong type safety, or requires complex algorithms over well-defined inputs?** → Tier 3 (Wasm)
4. **Logic requires natural-language understanding, open-ended judgement, or synthesis across unstructured inputs?** → Tier 4 (LLM)

**Irreversibility discriminator (modifier):**

Independent of logic shape, the agent MUST consider the irreversibility of being wrong:

- **Reversible / low-consequence** (routing, categorisation, suggestion): tier chosen by logic shape stands
- **Reversible / moderate-consequence** (resource allocation, scheduling): prefer lower tier; if Tier 4 selected, require a structured-output schema and a deterministic fallback
- **Irreversible / high-consequence** (financial transfer, legal commitment, safety-critical action): Tier 4 is **prohibited** as the sole decision-maker; either lower the tier with explicit rules, or wrap Tier 4 in a human-approval checkpoint that is the actual decision point

**Tier promotion / demotion:**

A node may be promoted to a higher tier on subsequent versions if requirements grow. Demotion is allowed only when test scenarios still pass at the lower tier.

**Tier 4 caveats (when introduced as a future stage):**

Tier 4 is not a quality continuation of Tiers 1–3 — it is a different category of execution. Specifically:
- Audit format differs: Tier 4 captures inputs, prompt, model version, and output, but cannot capture the reasoning step
- Capability grants differ: Tier 4 requires not only data-access capabilities but also a `tier4:invoke:<model_class>` capability
- Replay differs: Tier 4 nodes replay from recorded outputs (per XC-05), not by re-invoking the LLM
- Cost differs: Tier 4 invocations have token-level budgets and per-call latency budgets enforced by the host

The Architect Agent records the chosen tier and the rationale (logic shape + irreversibility class) for every scriptable node, per ARC-06.

---

## 6. Platform Repository

The repository is the platform's source of truth for *artifacts* — distinct from the event store, which is the source of truth for *runtime state*.

### 6.1 Conceptual Model

```
Repository
├── definitions/
│   └── <definition_name>/
│       ├── v1.0/
│       ├── v1.1/
│       └── v2.0/            ← active
│           ├── definition.json
│           ├── blueprint.json
│           ├── forms/
│           ├── scripts/
│           │   ├── tier1/<node_id>.dsl
│           │   ├── tier2/<node_id>.lua
│           │   └── tier3/<node_id>.{zig,wasm}
│           ├── projections/
│           ├── tests/
│           │   ├── scenarios.json
│           │   └── results/
│           └── deploy-log.json
├── shared/
│   ├── forms/        ← reusable form schemas
│   ├── projections/  ← reusable projections
│   └── modules/      ← reusable Wasm modules
└── tenants/
    └── <tenant_id>/
        └── activations.json  ← which artifact versions are active here
```

### 6.2 Repository Properties

- **Immutable.** A given version of a given artifact is never modified after creation. Edits create new versions.
- **Content-addressed.** Every artifact has a SHA-256 hash. Equal artifacts (regardless of name) deduplicate at storage.
- **Atomic activations.** Activating a definition version atomically activates all its associated forms, scripts, projections.
- **Per-tenant scoping.** Activations are tenant-scoped. A definition v2.0 may be active in production tenant A and not yet in production tenant B.
- **Schema registry.** All form schemas, event types, and projection outputs are indexed for queryability by the Architect Agent.

### 6.3 Storage

The repository is persisted in PostgreSQL alongside the event store:

```sql
-- Conceptual schema (full DDL in functional requirements)
artifact (
  hash         TEXT PRIMARY KEY,    -- SHA-256 of content
  kind         TEXT NOT NULL,        -- 'definition' | 'form' | 'script' | 'projection' | 'wasm_module' | ...
  content      JSONB OR BYTEA,       -- text artifacts in JSONB, binary in BYTEA
  created_at   TIMESTAMPTZ NOT NULL
)

artifact_version (
  id           UUID PRIMARY KEY,
  name         TEXT NOT NULL,
  version      TEXT NOT NULL,
  artifact_hash TEXT REFERENCES artifact(hash),
  parent_version UUID REFERENCES artifact_version(id),  -- lineage
  created_by   TEXT NOT NULL,        -- 'agent:architect' | 'user:<id>' | etc
  created_at   TIMESTAMPTZ NOT NULL,
  UNIQUE (name, version)
)

activation (
  tenant_id    UUID NOT NULL,
  name         TEXT NOT NULL,
  active_version UUID REFERENCES artifact_version(id),
  activated_by TEXT NOT NULL,
  activated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (tenant_id, name)
)
```

Binary blobs (Wasm modules) may use external object storage with hash references; small artifacts live inline.

---

## 7. Tenancy and Environments

The platform is **multi-tenant by construction**. Staging and production are not separate deployments — they are tenants within the same platform instance.

### 7.1 Tenant Model

```
Tenant
  ├── isolated event store namespace
  ├── isolated instance state
  ├── isolated activations (which artifact versions are live here)
  ├── isolated user/role bindings
  └── shared artifact repository (artifacts themselves are global)
```

A tenant is uniquely identified by a `tenant_id` (UUID). All API requests carry an authenticated tenant context. The platform enforces tenant isolation at the data layer — no query crosses tenant boundaries.

### 7.2 Typical Tenant Roles

- `tenant:staging` — used by Developer & DevOps agents for testing
- `tenant:production` — live business operations
- `tenant:training` — for end-user onboarding, isolated data
- Customer-specific tenants for SaaS deployments

### 7.3 Promotion Flow

```
Artifact created in repository (global)
        ↓
Activated in staging tenant by DevOps agent
        ↓
Smoke tests run against staging
        ↓
Promotion proposal generated (impact analysis)
        ↓
Human approval (or auto-approval if configured)
        ↓
Activated in production tenant
        ↓
Monitored; auto-rollback if error thresholds exceeded
```

### 7.4 Identity Provider Integration

Each tenant is bound to a realm at an external OIDC-compliant identity provider. The platform delegates all human authentication to that provider and consumes OIDC tokens via standard claims.

```
BPM Tenant  ─────1:1─────  IDP Realm
   │                          │
   ├── users (local mirror)   ├── users (authoritative)
   ├── instances               ├── groups, roles
   ├── activations             ├── federations (SAML, social)
   └── audit                   └── tokens (issued)
```

The platform's authentication layer is implemented behind a provider-agnostic `IdentityProvider` interface. Keycloak is the primary implementation target (Apache 2.0, single OSS edition, no commercial division). The interface allows substitution of another OIDC provider without changes outside the adapter package.

**Realm-per-tenant rationale:**
- Full isolation of users, policies, federations between tenants
- Independent customisation per tenant (e.g., one tenant federates to its corporate SAML, another uses local accounts only)
- Clean blast radius: a misconfiguration in tenant A's realm cannot affect tenant B
- Maps cleanly to the platform's tenant isolation model

**Agent identities at the provider:** Each AI pipeline agent is a service-account client at the provider, obtaining tokens via the OIDC client-credentials flow. Agent tokens carry the same standard claims as human tokens, with `auth_source` distinguishing them.

**Bootstrap:** A one-time bootstrap secret enables the first agent identity to be provisioned at the provider when no agent yet exists. After successful bootstrap, the bootstrap path is disabled until manually re-enabled.

Detailed requirements live in Stage 6.5 of the functional requirements (`OIDC-*`).

---

## 8. Capability Model

Every script and module declares the capabilities it requires. The platform grants only what is declared. No script discovers capabilities at runtime.

### 8.1 Capability Vocabulary

| Capability | Effect |
|---|---|
| `var:read` | Read instance variables |
| `var:write` | Write instance variables |
| `service:call:<service_id>` | Invoke a specific registered service |
| `service:call:*` | Invoke any registered service (rare, requires explicit grant) |
| `log:write` | Write to structured log |
| `time:read` | Read current platform time |
| `uuid:generate` | Generate a UUID |
| `instance:read_history` | Read prior events of this instance |
| `tenant:read_metadata` | Read non-sensitive tenant metadata |

### 8.2 Declaration

Every script artifact has a manifest:

```json
{
  "script_id": "approval-router-v3",
  "tier": "lua",
  "capabilities": ["var:read", "var:write", "service:call:credit_check", "log:write"],
  "limits": {
    "cpu_instructions": 10000000,
    "memory_bytes": 16777216,
    "wall_clock_ms": 5000
  }
}
```

The Lua/Wasm host enforces these limits. Calling an undeclared capability returns a structured error and terminates the script.

### 8.3 Capability Review

The DevOps agent performs static review of capability changes between versions. A new version requesting an additional capability is flagged for human approval before promotion.

---

## 9. The AI Agent Pipeline

> **Status note (v0.4):** This section describes the *prior* design of the agent pipeline. The corresponding functional requirements (Stage 12) have been formally deferred — see Functional Requirements §"Stage 12 — AI Agent Pipeline (DEFERRED)". The content below is preserved as background for the eventual re-specification but **MUST NOT be treated as actionable architecture for current implementation work**. Implementing agents working on Stages 6.5 and 7–11 should ignore §9 in its entirety. See §14 (Roadmap) for the intended direction.

The pipeline is the platform's CI/CD. It runs inside the platform as a sequence of stages, each producing structured artifacts consumed by the next.

### 9.1 Pipeline Stages

```
[Requirement Intake]
       ↓
[Architect Agent] ──── ambiguity resolution loop ────→ Owner
       ↓ Blueprint
[Owner Approval Checkpoint]
       ↓
[Developer Agent] ──── self-test iteration loop ─────→ (internal)
       ↓ Artifact bundle + test results
[Quality Gate]
       ↓
[Human Review Checkpoint] (configurable: required / optional)
       ↓
[DevOps Agent — Staging]
       ↓ Smoke test results + impact analysis
[Promotion Approval Checkpoint]
       ↓
[DevOps Agent — Production]
       ↓
[Runtime Monitoring]
       ↓
(feedback to next intake cycle)
```

Each stage has:
- Defined inputs (structured, validated)
- Defined outputs (structured, validated)
- A handoff contract (next stage cannot start without valid output from prior)
- A timeout and retry policy
- An audit record (who/what/when, full I/O)

### 9.2 Agent Roles

#### 9.2.1 Architect Agent

**Input:** Natural language requirement + optional examples and constraints from a business owner.

**Output:** Blueprint package:
- `requirement.md` — restated requirement after ambiguity resolution
- `process_definition.json` — graph (nodes, edges, gateways)
- `data_model.json` — entities, fields, types touched by this process
- `forms/*.json` — form schemas for each HUMAN_TASK node
- `services_required.json` — external services this process needs
- `test_scenarios.json` — happy path + edge cases as structured scenarios
- `tier_assignments.json` — for each scriptable node: assigned tier and rationale

**Responsibilities:**
- Resolve ambiguities through structured dialogue with the owner
- Decompose the requirement into graph nodes
- Identify reusable artifacts from the schema registry (don't re-create existing forms)
- Decide tier assignment per node per §5.4
- Author test scenarios *before* any code is generated (TDD as structural constraint)

**Must NOT:**
- Write executable scripts or modules
- Assume capabilities not granted by a human
- Skip ambiguity resolution to produce a faster output

**Prompt structure (host-controlled, not part of input):**
```
SYSTEM: You are the Architect Agent for the BPM Platform...
        [persistent persona, platform constraints, output schemas]
INPUT:  - Requirement: <text>
        - Context: existing definitions/forms/services in repository
        - Tenant: <id>
        - Reviewer: <owner_user_id>
TOOLS:  - schema_registry.search(...)
        - existing_definitions.search(...)
        - ambiguity_question(question_id, text, options) → owner_response
OUTPUT: Strict JSON matching Blueprint schema
```

#### 9.2.2 Developer Agent

**Input:** Blueprint package from Architect.

**Output:** Artifact bundle:
- `scripts/tier1/<node_id>.dsl` — DSL expressions
- `scripts/tier2/<node_id>.lua` — Lua scripts
- `scripts/tier3/<node_id>.zig` — Zig source for Wasm modules
- `scripts/tier3/<node_id>.wasm` — compiled Wasm
- `projections/*.json` — projection definitions
- `manifests/*.json` — capability declarations per script
- `test_results.json` — execution results for every scenario

**Responsibilities:**
- For each tier-assigned node, generate the corresponding artifact
- Compile Wasm modules using the platform's build job
- Execute every test scenario from the blueprint against the generated code
- Iterate (regenerate, recompile, retest) until all scenarios pass, up to N iterations
- If unable to pass all scenarios within iteration limit, halt and return failure with diagnostics

**Must NOT:**
- Add capabilities not justified by the blueprint
- Suppress or weaken test scenarios to make them pass
- Generate code that calls unregistered services

**Iteration loop:**
```
For up to MAX_ITERATIONS:
    generate_or_update_artifacts()
    compile_if_needed()
    results = run_all_scenarios()
    if all_passing(results):
        return success(bundle, results)
    else:
        feedback = analyze_failures(results)
        continue
return failure(bundle, results, diagnostics)
```

#### 9.2.3 DevOps Agent

**Input:** Artifact bundle from Developer + currently active versions in target tenants.

**Output:** Deployment record:
- `impact_analysis.json` — what changes, what running instances are affected, migration assessment
- `staging_smoke_results.json` — results of staging execution
- `promotion_proposal.json` — recommendation: promote / hold / reject + rationale
- `deploy_log.json` — actions taken (activation, rollback, etc.)

**Responsibilities:**
- Activate artifact bundle in staging tenant atomically
- Run smoke test scenarios against staging
- Compute impact on production: which definitions change, instance migration plan
- Generate promotion proposal with risk assessment
- After human approval, activate in production atomically
- Monitor error rates for a configurable window post-promotion
- Auto-rollback if error thresholds exceeded
- Record full deployment timeline

**Must NOT:**
- Promote to production without explicit approval (if configured as required)
- Skip impact analysis for "small" changes
- Hide failed smoke tests

#### 9.2.4 Shared Agent Constraints

All agents:
- Are stateless between invocations; all state is in the repository
- Carry a trace_id propagated from the originating request
- Produce structured output validated against a schema; non-conforming output is rejected
- Record full I/O to the audit log
- Operate under per-invocation time and token budgets
- Are configurable per-tenant (some tenants may require stricter human review)

### 9.3 Handoff Contracts

Each handoff between agents is governed by a schema. The receiving agent's first action is to validate the input. Invalid input halts the pipeline and produces a structured failure report.

| Handoff | Schema document |
|---|---|
| Owner → Architect | `requirement_intake_v1.json` |
| Architect → Owner (ambiguity) | `ambiguity_question_v1.json` |
| Architect → Developer | `blueprint_package_v1.json` |
| Developer → DevOps | `artifact_bundle_v1.json` |
| DevOps → Reviewer | `promotion_proposal_v1.json` |
| Monitoring → Pipeline | `monitoring_signal_v1.json` |

Schemas are versioned independently. Schema changes follow semver: breaking changes increment the major and require a coordinated agent update.

### 9.4 Checkpoints

| Checkpoint | Required by default? | Bypass policy |
|---|---|---|
| Blueprint approval (Architect → Developer) | Yes | Owner self-approval allowed; logged |
| Quality gate (Developer test pass) | Yes | Cannot bypass; failed tests block progression |
| Human review (Developer → DevOps) | Configurable per tenant | Auto-pass for low-risk changes if tenant policy allows |
| Promotion approval (Staging → Production) | Yes | Auto-promote allowed for tenant policies that explicitly enable it for specific definition tags |
| Rollback decision | Automatic by thresholds; human override always available | — |

---

## 10. Data Flow Examples

### 10.1 Authoring a New Process

```
Owner: "When a purchase request over $10k is submitted, route to the
       requester's manager. If over $50k, also require finance director.
       Notify the requester at each step."
                                  │
                                  ▼
Architect Agent:
  - Asks: "What's the timeout for manager approval? Auto-escalate?"
  - Owner answers
  - Produces blueprint: 6 nodes, 2 forms, 3 scripts (1 tier-1, 2 tier-2),
    8 test scenarios
                                  │
                                  ▼
Owner approves blueprint
                                  │
                                  ▼
Developer Agent:
  - Generates DSL expression for $10k/$50k gateway
  - Generates Lua scripts for notifications
  - Runs 8 scenarios; 7 pass, 1 fails on edge case
  - Iterates; all 8 pass on iteration 2
  - Hands off artifact bundle with manifests
                                  │
                                  ▼
DevOps Agent:
  - Activates in staging
  - Runs scenarios end-to-end through real execution engine
  - Computes impact: no production instances on prior version
  - Proposes auto-promotion (low risk)
                                  │
                                  ▼
Owner approves promotion
                                  │
                                  ▼
Production tenant: definition active, ready to accept instances
```

### 10.2 Running a Process Instance

```
Application calls REST: POST /api/instances
  { definition: "purchase-approval", variables: { amount: 25000, ... } }
                                  │
                                  ▼
Platform:
  - Loads active definition version for tenant
  - Snapshots definition into instance
  - Appends INSTANCE_STARTED event
  - Engine enters START node, transitions to first gateway
  - DSL evaluator: order.amount > 10000 → route to manager_approval
  - Creates HUMAN_TASK for manager
  - Appends TASK_ACTIVATED event
  - Returns instance_id to caller
                                  │
                                  ▼
Manager UI fetches: GET /api/tasks/<id>
  Returns: form schema + current variables
  Manager submits approval via: POST /api/tasks/<id>/complete
                                  │
                                  ▼
Platform:
  - Validates output against form schema
  - Appends TASK_COMPLETED event
  - Engine evaluates next gateway
  - Continues to completion or next task
```

---

## 11. Cross-Cutting Concerns

### 11.1 Observability

- **Structured logs** (JSON to stdout) with trace_id correlation across all layers
- **Prometheus metrics** at `/metrics` covering instance counts, task latencies, agent latencies, script execution times per tier, Wasm compile times
- **Event-based timeline view** per instance, per definition, per agent run
- **Dead letter queue** for failed events and failed agent runs

### 11.2 Security

- Bearer token authentication at L6
- Role-based authorisation: `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`, `AGENT_RUNNER`
- Capability model at L3 (see §8)
- Tenant isolation at L1 (no cross-tenant queries by construction)
- Signed audit trail: every approval is recorded with actor identity and content hash

### 11.3 Performance Targets (non-binding, guide for design)

| Operation | Target p95 |
|---|---|
| Event append | < 5 ms |
| Task complete (DSL-only path) | < 20 ms |
| Task complete (with Lua script) | < 50 ms |
| Task complete (with Wasm module, cached) | < 100 ms |
| Architect agent run (typical) | < 60 s |
| Developer agent run (typical, no Wasm) | < 120 s |
| Developer agent run (with Wasm compile) | < 300 s |
| DevOps staging promotion | < 30 s |

### 11.4 Migration of Running Instances

When a definition is activated at a new version, in-flight instances on prior versions:
- Continue on their snapshotted version (default — safest)
- May be migrated forward if the DevOps agent determines compatibility (same nodes, same variable schema, only logic changes inside scripts)
- Are reported in the impact analysis before promotion

Incompatible changes (node removal, edge restructuring) never auto-migrate. Operators must drain old instances or define an explicit migration plan.

---

## 12. Implementation Stack

| Layer | Choice | Rationale |
|---|---|---|
| Language (kernel + L1–L4) | Zig | Performance, explicit memory, simple deployment |
| HTTP | `http.zig` (karlseguin) | Pure Zig, mature, ~140k req/s |
| PostgreSQL client | `pg.zig` (karlseguin) | Pure Zig, pooling, same author |
| Database | PostgreSQL 15+ | Mature, JSONB, mature event sourcing patterns |
| Lua runtime | LuaJIT | Small, fast, well-known sandboxing pattern |
| Wasm runtime | Wasmtime (embedded) | Mature, well-documented imports, security focus |
| Wasm guest compiler | Zig (via platform build job) | Same language end-to-end for type-safe modules |
| LLM provider (agents) | Anthropic API (Claude) | Strong structured-output and tool-use support |
| Identity provider (primary) | Keycloak (Apache 2.0) | Mature, single OSS edition, full OIDC/SAML, multi-realm, comprehensive admin API |
| Identity integration | OIDC standard via abstract `IdentityProvider` interface | Allows substitution of another OIDC provider without code change outside adapter |
| Build / orchestration | Zig build system | Native, no external build tool |

---

## 13. Out of Scope

To prevent scope creep, the following are explicitly **not** part of the platform:

- End-user UI for business applications (only platform admin/operator UI)
- Specific ERP, CRM, HRM domain models
- Email/SMS notification infrastructure (use service tasks calling external services)
- Document generation (PDF, Word) — done as service tasks
- Building or hosting the identity provider itself (Keycloak runs as a separate deployment; the platform integrates with it)
- Machine learning training (only inference via Wasm modules)
- Native mobile apps

---

## 14. Roadmap — Future Stages

The platform's design anticipates substantial growth beyond Stages 6.5–11 (the current in-scope work). The stages described below are **named and sketched, not specified.** They exist here so implementing agents can avoid choices that foreclose future direction. Each will receive a full functional-requirements section when its preceding dependencies are operational and the design has stabilised.

The stages are listed in expected dependency order. Numbers are placeholders; later renumbering is possible.

### Stage 12 — Agent Pipeline (re-specification)

The Architect → Developer → DevOps pipeline that transforms business requirements into deployed artifacts. A prior draft was withdrawn (see Functional Requirements §"Stage 12 — DEFERRED") because it predates the design direction set by Stages 13–16 below. Once Stages 6.5–11 land, this stage will be re-specified with pipeline agents as MCP clients of the platform, with the four-tier model (including Tier 4 below) as the unit of artifact generation, and with the policy silo (Stage 15) as one of its requirement sources.

### Stage 13 — Tier 4 Execution (LLM-Driven Nodes)

A fourth execution tier alongside DSL / Lua / Wasm. Tier 4 nodes delegate execution to a configured LLM (or its successor) with strict capability scoping, structured-output schema validation, replay-from-recorded-output semantics, and token / latency / cost budgets. Tier 4 is the right choice for nodes requiring language understanding, open-ended judgement, or synthesis across unstructured inputs. It is governed by the irreversibility discriminator in §5.4: Tier 4 alone cannot decide irreversible high-consequence actions; such decisions require a human checkpoint above the Tier 4 invocation.

Tier 4 is a distinct execution category, not a quality continuation of Tiers 1–3. Audit format, capability vocabulary, and replay semantics all differ. Tier 4 is hosted *alongside* the kernel, not inside it — kernel paths remain deterministic per XC-04.

### Stage 14 — MCP Surface (Agent-Native Platform Interface)

The platform exposes its capabilities as Model Context Protocol (MCP) tools, in addition to the existing REST API. This makes the platform a discoverable, addressable node in agent meshes — internal pipeline agents, customer agents, and (eventually) inter-organisational agents all interact with the platform through the same uniform interface.

The MCP surface is a *projection* of the platform's capabilities, not a new capability set. Every MCP tool corresponds to a REST endpoint or kernel operation, with identical authentication, capability checks, and audit recording. The shift is from "software the company uses" to "node in the agent mesh that runs the company."

The agent pipeline (Stage 12) is one of many MCP clients; pipeline agents have no architecturally privileged channel. This decouples the platform from the specific pipeline design and makes pipeline agents replaceable by customer-supplied alternatives.

### Stage 15 — Policy Document Silo & Change-Impact Analysis

A first-class store for the organisation's formal policy documents — procurement policies, HR handbook, security policies, regulatory references — stored as versioned artifacts with structured links to processes, forms, roles, and event types.

A new agent role (Policy Analyst Agent) reviews proposed document changes against the linked operational artifacts, produces a structured impact report (which processes are affected, what specifically needs to change, what the risk class is), and feeds the result into the change-management pipeline for human approval. The discipline: document changes drive process changes, with the platform as the medium of propagation.

This stage closes the loop between organisational policy and operational execution. It also makes the platform usable as a system of record for "why does this process work this way?" — every process traces back to a policy artifact that justified it.

### Stage 16 — Inter-Organisational Protocols & Reputation

Extension of the MCP surface (Stage 14) and audit infrastructure (Stage 6 + ADP-09) to support agent-to-agent interaction across organisational boundaries. Capabilities include:

- A standard inter-organisational protocol layer (likely MCP-based plus higher-level negotiation primitives)
- Cryptographically signed commitments — every promise the company makes is a verifiable object
- Execution attestations — agent decisions carry signed evidence of inputs, policy applied, and output
- Portable reputation — counterparty reliability is first-class economic data
- Reversibility scoring on every action, with stronger checks for irreversible operations

This is the stage where the platform stops being an internal tool and becomes a participant in the wider machine economy. Most of this stage's substance depends on industry-level infrastructure (cross-organisational reputation registries, attestation standards, jurisdictional protocol fragments) that doesn't fully exist yet. The platform's job is to *not foreclose* this evolution while shipping immediate value.

### Roadmap Constraints (Apply to All Future Stages)

These constraints govern any future stage, not just the ones listed:

- **Kernel determinism (XC-04) is permanent.** No future stage may put LLM calls on kernel paths.
- **Capability discipline is permanent.** Every new capability vocabulary entry must be granted explicitly; no defaults.
- **Audit chain is permanent.** Every state-changing action, regardless of which stage owns it, appends to the chained audit log.
- **MCP becomes the native interface after Stage 14.** Future surfaces are MCP projections by default; REST is retained for legacy clients but no new functionality is REST-only.
- **Tenant isolation is permanent.** No future feature crosses tenant boundaries without an explicit cross-tenant protocol step.

---

## 15. Open Questions

To be resolved before or during implementation:

1. **Wasm module distribution.** When a Wasm module is large, should it stream from object storage or live inline in the artifact repository? Threshold?
2. **Cross-tenant artifact sharing.** Are shared artifacts (e.g., a generic approval form) global, or do tenants get copies? Affects governance.
3. **DSL extension protocol.** As needs grow, will the DSL gain features (e.g., array operations)? Or do users always escalate to Lua?
4. **Idempotency window.** Event idempotency keys — how long are they retained before a new submission with the same key is treated as fresh?
5. **Tier 4 model selection.** Which model classes will be available at Tier 4? How is model upgrading governed?
6. **MCP protocol stability.** MCP is still evolving. How will the platform handle MCP version bumps?

These should be resolved by writing additional design notes referenced from this document, not by modifying this document silently.

---

## 16. Document Conventions

- **MUST / SHOULD / MAY** follow RFC 2119 semantics.
- Every requirement in the companion document has a stable ID. IDs are never reused, even after deletion.
- Code samples are illustrative, not normative. Normative behaviour lives in functional requirements.
- Diagrams in this document are conceptual. Detailed sequence diagrams belong to design notes per subsystem.
