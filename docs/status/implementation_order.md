# BPM Platform — Implementation Order

**Version:** 0.2 · 2026-05-26  
**Maintained by:** ORCH

---

## How stages work

- ORCH runs WF-02 one stage at a time.
- Before launching stage N+1, ORCH checks that every **MUST** requirement in stage N has status `RELEASED` in `requirement_status.json`.
- Within a stage, all requirements are handed to CODE-DESIGNER as a single batch. BACKEND-DEV and FRONTEND-DEV implement them in parallel where possible.
- SHOULD / COULD requirements within a stage are included in the same batch but do not block the stage gate.

---

## Backend implementation order

### Stage 1 — Foundation (event store + database)

_Gate: nothing. This is the baseline._

| ID | Title | Priority |
|---|---|---|
| DB-01 | Schema initialisation | MUST |
| DB-02 | Connection pooling | MUST |
| DB-03 | Transactional integrity | MUST |
| DB-04 | Health check query | MUST |
| ES-01 | Append event | MUST |
| ES-02 | Ordered read | MUST |
| ES-03 | Event idempotency | MUST |
| ES-04 | Global event stream | MUST |
| ES-05 | Event type registry | MUST |
| ES-06 | Point-in-time query | MUST |
| ES-07 | Retention policy | SHOULD |
| ES-08 | Event metadata | SHOULD |

### Stage 2 — Process definitions

_Gate: Stage 1 MUST requirements RELEASED._

| ID | Title | Priority |
|---|---|---|
| PD-01 | Create definition | MUST |
| PD-02 | Graph validation | MUST |
| PD-03 | Version management | MUST |
| PD-04 | Definition lifecycle | MUST |
| PD-05 | Node types | MUST |
| PD-06 | Edge conditions | MUST |
| PD-07 | Definition retrieval | MUST |
| PD-08 | Definition snapshot | MUST |
| PD-09 | Definition import/export | SHOULD |
| PD-10 | Definition search | COULD |

### Stage 3 — Execution engine

_Gate: Stage 2 MUST requirements RELEASED._

| ID | Title | Priority |
|---|---|---|
| EE-01 | Start instance | MUST |
| EE-02 | Pure transition function | MUST |
| EE-03 | Task activation | MUST |
| EE-04 | Complete task | MUST |
| EE-05 | Exclusive gateway | MUST |
| EE-06 | Parallel gateway (split) | MUST |
| EE-07 | Parallel gateway (join) | MUST |
| EE-08 | Instance cancellation | MUST |
| EE-09 | Variable scoping | MUST |
| EE-10 | Execution error handling | MUST |
| EE-11 | State reconstruction | MUST |
| EE-12 | Concurrent instance safety | MUST |

### Stage 4 — REST API

_Gate: Stage 3 MUST requirements RELEASED._

| ID | Title | Priority |
|---|---|---|
| API-01 | REST conventions | MUST |
| API-02 | Process definition CRUD | MUST |
| API-03 | Instance management | MUST |
| API-04 | Task operations | MUST |
| API-05 | History endpoint | MUST |
| API-06 | Pagination | MUST |
| API-07 | Input validation | MUST |
| API-08 | Bearer token auth | MUST |
| API-09 | Request tracing | MUST |
| API-10 | Rate limiting | SHOULD |
| API-11 | OpenAPI specification | SHOULD |
| API-12 | Health endpoints | MUST |

### Stage 5 — Scheduler + Identity

_Gate: Stage 4 MUST requirements RELEASED._

| ID | Title | Priority |
|---|---|---|
| SCH-01 | Durable timer creation | MUST |
| SCH-02 | Timer polling | MUST |
| SCH-03 | Timer cancellation | MUST |
| SCH-04 | Escalation timer | MUST |
| SCH-05 | Missed timer recovery | MUST |
| SCH-06 | Timer jitter | SHOULD |
| SCH-07 | Recurring timers | SHOULD |
| IDN-01 | User registry | MUST |
| IDN-02 | Group management | MUST |
| IDN-03 | Role-based access | MUST |
| IDN-04 | API token management | MUST |

### Stage 6 — Observability + Extensions

_Gate: Stage 5 MUST requirements RELEASED._

| ID | Title | Priority |
|---|---|---|
| OBS-01 | Structured logging | MUST |
| OBS-02 | Prometheus metrics | MUST |
| OBS-03 | Audit log | MUST |
| OBS-04 | Instance timeline view | MUST |
| OBS-05 | Dead letter queue | MUST |
| OBS-06 | Alerting hooks | SHOULD |
| EXT-01 | Service task node type | MUST |
| EXT-02 | Webhook event dispatch | MUST |
| EXT-03 | Plugin interface | SHOULD |
| EXT-04 | Variable transformer | SHOULD |
| EXT-05 | Sub-process support | SHOULD |

---

### Stage 6.5 — Schema adaptations + OIDC foundations

_Gate: Stage 6 MUST requirements RELEASED._

**Note:** This stage has two parallel streams (A and B) that can run simultaneously. Both must complete before Stage 7 begins. The adaptation requirements (ADP-*) extend shipped tables additively — no existing behaviour changes.

**Stream A — Schema adaptations (BACKEND-DEV):**

| ID | Title | Priority |
|---|---|---|
| ADP-01 | Tenant column on event store | MUST |
| ADP-02 | Tenant column on definition, instance, and audit tables | MUST |
| ADP-03 | Tenant context resolution on API | MUST |
| ADP-04 | User tenant binding | MUST |
| ADP-04a | External identity linkage on user | MUST |
| ADP-04b | Realm binding on tenant | MUST |
| ADP-05 | Artifact hash reference on instance | MUST |
| ADP-06 | Pipeline run correlation on audit and events | SHOULD |
| ADP-07 | Agent role and reserved usernames | MUST |
| ADP-08 | Service task catalog reference | MUST |
| ADP-09 | Tamper-evident audit chain | MUST |
| ADP-10 | Agent I/O capture in audit | MUST |
| ADP-11 | Replay-safe retention policy | MUST |
| ADP-12 | Default-tenant regression suite | MUST |

**Stream B — Identity provider integration (BACKEND-DEV):**

| ID | Title | Priority |
|---|---|---|
| OIDC-01 | Pluggable provider interface | MUST |
| OIDC-02 | Keycloak adapter |
| OIDC-03 | Configuration source | MUST |
| OIDC-04 | Standards compliance boundary | MUST |
| OIDC-05 | Bearer token acceptance | MUST |
| OIDC-06 | JWKS caching | MUST |
| OIDC-07 | Claim validation | MUST |
| OIDC-08 | Standard claim mapping | MUST |
| OIDC-09 | JIT user creation | MUST |
| OIDC-10 | Attribute synchronisation | MUST |
| OIDC-11 | External user identity stability | MUST |
| OIDC-12 | Realm-tenant binding | MUST |
| OIDC-13 | Tenant claim source | MUST |
| OIDC-14 | Realm provisioning via adapter | MUST |
| OIDC-15 | Realm deletion safety | MUST |
| OIDC-16 | Full lifecycle API for agents | MUST |
| OIDC-17 | Provisioning idempotency | MUST |
| OIDC-18 | Provisioning transactional semantics | MUST |
| OIDC-19 | Provisioning audit | MUST |
| OIDC-20 | Service accounts for agents | MUST |
| OIDC-21 | Agent token rotation | MUST |
| OIDC-22 | Bootstrap agent identity | MUST |
| OIDC-23 | IDP federation support | MUST |
| OIDC-24 | Federated user attribute mapping | SHOULD |
| OIDC-25 | Provider health check | MUST |
| OIDC-26 | Provider metrics | MUST |
| OIDC-27 | Token verification performance | SHOULD |
| OIDC-28 | Local development realm | MUST |
| OIDC-29 | Realm seed as versioned artifact | MUST |
| OIDC-30 | Test token issuance helper | MUST |
| OIDC-31 | End-to-end authentication test suite | MUST |
| OIDC-32 | Agent test identities | MUST |
| OIDC-33 | Coexistence period | MUST |
| OIDC-34 | Migration helper | SHOULD |

---

### Stages 7, 8, 9 — Execution tiers (parallel)

_Gate: Stage 6.5 Stream A (ADP-* MUST) RELEASED. Stages 7, 8, 9 are fully independent of each other and can run in parallel._

#### Stage 7 — Expression DSL

| ID | Title | Priority |
|---|---|---|
| DSL-01 | Grammar conformance | MUST |
| DSL-02 | AST stability | MUST |
| DSL-03 | Error recovery | SHOULD |
| DSL-04 | Supported types | MUST |
| DSL-05 | Type coercion rules | MUST |
| DSL-06 | Total evaluation | MUST |
| DSL-07 | Function whitelist | MUST |
| DSL-08 | Function purity | MUST |
| DSL-09 | Date built-ins | MUST |
| DSL-10 | Context resolution | MUST |
| DSL-11 | Dot path traversal | MUST |
| DSL-12 | Engine API | MUST |
| DSL-13 | Performance target | SHOULD |

#### Stage 8 — Lua Script Execution

| ID | Title | Priority |
|---|---|---|
| LUA-01 | LuaJIT integration | MUST |
| LUA-02 | State isolation | MUST |
| LUA-03 | Stdlib restriction | MUST |
| LUA-04 | Bytecode loading disabled | MUST |
| LUA-05 | Host API registration | MUST |
| LUA-06 | Capability check at call site | MUST |
| LUA-07 | Capability manifest validation | MUST |
| LUA-08 | Instruction limit | MUST |
| LUA-09 | Memory limit | MUST |
| LUA-10 | Wall clock timeout | MUST |
| LUA-11 | Variable read/write | MUST |
| LUA-12 | Service call | MUST |
| LUA-13 | Logging | MUST |
| LUA-14 | Time source | MUST |
| LUA-15 | Structured failure | MUST |
| LUA-16 | Runtime error capture | MUST |

#### Stage 9 — Wasm Module Execution

| ID | Title | Priority |
|---|---|---|
| WASM-01 | Wasmtime integration | MUST |
| WASM-02 | Module ABI | MUST |
| WASM-03 | Source compilation job | MUST |
| WASM-04 | Compile caching | MUST |
| WASM-05 | Build reproducibility | SHOULD |
| WASM-06 | Import whitelist | MUST |
| WASM-07 | No filesystem access | MUST |
| WASM-08 | Memory isolation | MUST |
| WASM-09 | Fuel-based execution limit | MUST |
| WASM-10 | Memory cap | MUST |
| WASM-11 | Wall clock timeout | MUST |
| WASM-12 | Parity with Lua host API | MUST |
| WASM-13 | Instance pooling | SHOULD |
| WASM-14 | Hot reload | MUST |

---

### Stage 10 — Platform Repository

_Gate: Stages 7, 8, 9 MUST requirements RELEASED. Stage 6.5 Stream B (OIDC-* MUST) RELEASED._

| ID | Title | Priority |
|---|---|---|
| REPO-01 | Content addressing | MUST |
| REPO-02 | Immutability | MUST |
| REPO-03 | Versioning | MUST |
| REPO-04 | Canonical serialisation | MUST |
| REPO-05 | Form schema indexing | MUST |
| REPO-06 | Event type registry | MUST |
| REPO-07 | Service catalog | MUST |
| REPO-08 | Atomic activation | MUST |
| REPO-09 | Per-tenant activation | MUST |
| REPO-10 | Activation history | MUST |
| REPO-11 | Create artifact | MUST |
| REPO-12 | List versions | MUST |
| REPO-13 | Tenant activations | MUST |
| REPO-14 | Bulk bundle operations | SHOULD |

**Cross-cutting requirements applied at this stage:**

| ID | Title | Priority | Note |
|---|---|---|---|
| XC-01 | Trace propagation | MUST | Verify end-to-end with new stages |
| XC-02 | Audit immutability | MUST | Chain validation (ADP-09) now exercised |
| XC-03 | Configuration in repository | MUST | First use of repository for platform config |
| XC-04 | Kernel determinism | MUST | Confirm no LLM calls on kernel paths |
| XC-05 | Deterministic replay for non-LLM tiers | SHOULD | First replay tests across all tiers |
| XC-06 | Backwards compatibility | MUST | Upgrade test: pre-Stage 6.5 instances continue |

---

### Stage 11 — Test Runner and Simulation Mode

_Gate: Stage 10 MUST requirements RELEASED._

| ID | Title | Priority |
|---|---|---|
| SIM-01 | Simulation tenant | MUST |
| SIM-02 | Service mocking | MUST |
| SIM-03 | Time control | MUST |
| SIM-04 | Deterministic UUIDs | MUST |
| SIM-05 | Scenario schema | MUST |
| SIM-06 | Assertion vocabulary | MUST |
| SIM-07 | Scenario runner | MUST |
| SIM-08 | Batch execution | MUST |
| SIM-09 | Test result storage | MUST |
| SIM-10 | Failure diagnostics | MUST |

---

### Stage 12 — AI Agent Pipeline

_Gate: Stage 11 MUST requirements RELEASED. **DEFERRED** — specification not yet written. See docs/addon-1/02-functional-requirements.md §"Stage 12" for rationale._

---

## Frontend implementation order

Frontend stages align with backend stages that provide the APIs they depend on.

### Stage F1 — Shell

_Gate: Backend Stage 4 MUST requirements RELEASED (API exists)._

| ID | Title | Priority |
|---|---|---|
| SH-01 | Authenticated shell | MUST |
| SH-02 | Navigation | MUST |
| SH-03 | Login page | MUST |
| SH-04 | Token storage | MUST |
| SH-05 | Session expiry | MUST |
| SH-06 | Role-aware routing | MUST |
| SH-07 | Global error boundary | MUST |

### Stage F2 — Process Designer

_Gate: Stage F1 MUST requirements RELEASED. Backend Stage 2 MUST RELEASED._

| ID | Title | Priority |
|---|---|---|
| PD-UI-01 | Definition list page | MUST |
| PD-UI-02 | Create definition | MUST |
| PD-UI-03 | Canvas | MUST |
| PD-UI-04 | Add / delete node | MUST |
| PD-UI-05 | Node property panel | MUST |
| PD-UI-06 | Add / delete edge | MUST |
| PD-UI-07 | CEL expression editor | MUST |
| PD-UI-08 | Save definition | MUST |
| PD-UI-09 | Validation feedback | MUST |
| PD-UI-10 | Version list | MUST |
| PD-UI-11 | Activate version | MUST |
| PD-UI-12 | Deprecate version | MUST |
| PD-UI-13 | Definition export | SHOULD |
| PD-UI-14 | Definition import | SHOULD |
| PD-UI-15 | Read-only canvas | MUST |
| PD-UI-16 | Diff view | SHOULD |
| PD-UI-17 | Canvas keyboard shortcuts | SHOULD |
| PD-UI-18 | Auto-layout | COULD |
| PD-UI-19 | Mini-map | COULD |

### Stage F3 — Instance monitoring

_Gate: Stage F1 MUST requirements RELEASED. Backend Stage 3 MUST RELEASED._

| ID | Title | Priority |
|---|---|---|
| IN-UI-01 | Instance board | MUST |
| IN-UI-02 | Instance filters | MUST |
| IN-UI-03 | Start instance | MUST |
| IN-UI-04 | Instance detail view | MUST |
| IN-UI-05 | Event history tab | MUST |
| IN-UI-06 | Timeline tab | MUST |
| IN-UI-07 | Cancel instance | MUST |
| IN-UI-08 | Auto-refresh | SHOULD |
| IN-UI-09 | Active token visualisation | SHOULD |
| IN-UI-10 | History scrubber | SHOULD |

### Stage F4 — Task inbox

_Gate: Stage F3 MUST requirements RELEASED. Backend Stage 4 task endpoints RELEASED._

| ID | Title | Priority |
|---|---|---|
| TK-UI-01 | Task inbox | MUST |
| TK-UI-02 | Task detail panel | MUST |
| TK-UI-03 | Dynamic form rendering | MUST |
| TK-UI-04 | Complete task | MUST |
| TK-UI-05 | Claim task | MUST |
| TK-UI-06 | Reassign task | MUST |
| TK-UI-07 | Task sort & search | SHOULD |
| TK-UI-08 | Badge count | SHOULD |
| TK-UI-09 | Escalation indicator | SHOULD |
| TK-UI-10 | Mobile task completion | MUST |

### Stage F5 — Administration

_Gate: Stage F1 MUST requirements RELEASED. Backend Stage 5 MUST RELEASED._

| ID | Title | Priority |
|---|---|---|
| ADM-UI-01 | User list | MUST |
| ADM-UI-02 | Create user | MUST |
| ADM-UI-03 | Edit user | MUST |
| ADM-UI-04 | Deactivate user | MUST |
| ADM-UI-05 | Group management | MUST |
| ADM-UI-06 | Token list | MUST |
| ADM-UI-07 | Issue token | MUST |
| ADM-UI-08 | Revoke token | MUST |
| ADM-UI-09 | Health dashboard | MUST |
| ADM-UI-10 | Metrics viewer | SHOULD |
| ADM-UI-11 | Audit log viewer | MUST |

### Stage F6 — DLQ + Webhooks

_Gate: Stage F5 MUST requirements RELEASED. Backend Stage 6 MUST RELEASED._

| ID | Title | Priority |
|---|---|---|
| DLQ-UI-01 | DLQ list | MUST |
| DLQ-UI-02 | DLQ item detail | MUST |
| DLQ-UI-03 | Retry action | MUST |
| DLQ-UI-04 | Discard action | MUST |
| DLQ-UI-05 | DLQ depth indicator | SHOULD |
| WH-UI-01 | Webhook subscription list | MUST |
| WH-UI-02 | Create webhook subscription | MUST |
| WH-UI-03 | Pause / resume subscription | MUST |
| WH-UI-04 | Delivery log | SHOULD |

### Stage F7 — Identity management (OIDC-aware)

_Gate: Stage F5 MUST requirements RELEASED. Backend Stage 6.5 MUST RELEASED._

**Note:** This stage updates the existing administration UI to reflect the OIDC identity model — realm management, external user provisioning, agent identities. Exact requirement IDs to be specified in WF-02 for this stage.

---

## Dependency graph

```
Already shipped:  Stages 1–6  (Stages 1–6 + F1–F6)
                       │
                       ▼
              ┌────────┴────────────────┐
              │ Stream A                │ Stream B
        ADP-01..ADP-12            OIDC-01..OIDC-34
        (schema adaptations)      (IDP integration)
              │                         │
              └─────────┬───────────────┘
                        │ Stage 6.5 gate (both streams)
                        │
              ┌─────────┼─────────┐
              │         │         │
        Stage 7       Stage 8   Stage 9
        (DSL)         (Lua)     (Wasm)
              │         │         │
              └────────┬┘─────────┘
                       │ Stages 7+8+9 gate
                       ▼
                 Stage 10 (Repository)
                       │
                       ▼
                 Stage 11 (Test Runner)
                       │
                       ▼
           Stage 12 (Agent Pipeline — DEFERRED)
```

---

## Summary counts

| Track | Stages | MUST | SHOULD | COULD | Total |
|---|---|---|---|---|---|
| Backend (original) | 1–6 | 54 | 12 | 2 | 68 |
| Backend (extension) | 6.5–11 + ADP + XC | 115 | 9 | 0 | 124 |
| Frontend (original) | F1–F6 | 47 | 16 | 3 | 66 |
| Frontend (extension) | F7 | TBD | TBD | TBD | TBD |
| **All (in-scope)** | | **216+** | **37+** | **5** | **258+** |
