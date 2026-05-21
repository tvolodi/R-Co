# BPM Platform — Implementation Order

**Version:** 0.1 · 2026-05-20  
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

---

## Summary counts

| Track | Stages | MUST | SHOULD | COULD | Total |
|---|---|---|---|---|---|
| Backend | 1–6 | 54 | 12 | 2 | 68 |
| Frontend | F1–F6 | 47 | 16 | 3 | 66 |
| **All** | | **101** | **28** | **5** | **134** |
