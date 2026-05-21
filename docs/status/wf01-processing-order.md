# WF-01 Processing Order — Per-Requirement Pipeline

**Version:** 1.0 · 2026-05-20  
**Strategy:** One requirement (or tightly-coupled pair) per WF-01 run. Each run completes  
`REQ-ANALYST → REQ-VALIDATOR → DOC-UPDATER` before the next run starts.  
VALIDATED requirements immediately feed WF-02 in parallel sessions.

---

## Grouping rules

- **Solo run:** requirement has no intra-stage peer dependencies
- **Coupled pair:** two requirements describe two halves of one atomic mechanism;  
  splitting them creates artificial validator failures

---

## Processing sequence

### Stage 1 — Event Store & Infrastructure

| Run | ID | Unit | Type | Depends on | Notes |
|---|---|---|---|---|---|
| 001 | ES-01 | `ES-01` | solo | — | Foundational; defines event structure all others reference |
| 002 | ES-02 | `ES-02` | solo | ES-01 | Read ordering; references append guarantees |
| 003 | DB-01 | `DB-01` | solo | — | Schema init; independent of event semantics |
| 004 | DB-02 | `DB-02` | solo | DB-01 | Pool layered on schema |
| 005 | ES-03 | `ES-03` | solo | ES-01 | Idempotency references event structure from ES-01 |
| 006 | ES-04 | `ES-04` | solo | ES-01, ES-02 | Global stream; needs ordered-read semantics clear first |
| 007 | ES-05 | `ES-05` | solo | ES-01 | Registry gates appending; ES-01 AC must be settled |
| 008 | ES-06 | `ES-06` | solo | ES-01, ES-02 | Point-in-time query over ordered events |
| 009 | DB-03 | `DB-03` | solo | ES-01, DB-01 | Transactional integrity references both append and schema |
| 010 | DB-04 | `DB-04` | solo | DB-02 | Health query needs pool AC settled |
| 011 | ES-07 | `ES-07` | solo | ES-01, ES-02 | SHOULD — retention/archive; needs append + read clear |
| 012 | ES-08 | `ES-08` | solo | ES-01 | SHOULD — metadata on append record |

### Stage 2 — Process Definition Model

| Run | ID | Unit | Type | Depends on | Notes |
|---|---|---|---|---|---|
| 013 | PD-01 | `PD-01` | solo | — (stage gate: Stage 1 MUST validated) | Foundational for all PD requirements |
| 014 | PD-02 | `PD-02` | solo | PD-01 | Graph validation runs on create; PD-01 AC must be settled |
| 015 | PD-03 | `PD-03` | solo | PD-01 | Versioning layered on create |
| 016 | PD-04 | `PD-04` | solo | PD-01, PD-03 | Lifecycle transitions reference versioning |
| 017 | PD-05 | `PD-05` | solo | PD-01, PD-02 | Node types validated during graph validation |
| 018 | PD-06 | `PD-06` | solo | PD-02, PD-05 | Edge conditions on EXCLUSIVE_GATEWAY nodes |
| 019 | PD-07 | `PD-07` | solo | PD-01 | Retrieval; independent of lifecycle/versioning |
| 020 | PD-08 | `PD-08` | solo | PD-01, PD-04 | Snapshot ties to lifecycle (only ACTIVE definitions) |
| 021 | PD-09 | `PD-09` | solo | PD-01 | SHOULD — import/export; needs create AC settled |
| 022 | PD-10 | `PD-10` | solo | PD-01, PD-07 | COULD — search over retrieval result set |

### Stage 3 — Execution Engine

| Run | ID | Unit | Type | Depends on | Notes |
|---|---|---|---|---|---|
| 023 | EE-01 | `EE-01` | solo | PD-08 | Start instance; requires snapshot AC |
| 024 | EE-02 | `EE-02` | solo | EE-01 | Pure transition function; core of the engine |
| 025 | EE-03 | `EE-03` | solo | EE-01, EE-02 | Task activation; output of transition |
| 026 | EE-04 | `EE-04` | solo | EE-03 | Complete task; triggers next transition |
| 027 | EE-05 | `EE-05` | solo | EE-02, PD-06 | Exclusive gateway; needs CEL condition AC from PD-06 |
| 028 | EE-06+07 | `EE-06` + `EE-07` | **coupled pair** | EE-02 | Split and join are one atomic mechanism; EE-07 cancel behaviour references EE-08 |
| 029 | EE-08 | `EE-08` | solo | EE-01 | Cancellation; referenced by EE-06+07 join logic |
| 030 | EE-09 | `EE-09` | solo | EE-04 | Variable merge; output of task completion |
| 031 | EE-10 | `EE-10` | solo | EE-05, EE-09 | Error handling; triggered by gateway failure and schema violation |
| 032 | EE-11 | `EE-11` | solo | EE-01, EE-02 | State reconstruction; requires event sourcing AC settled |
| 033 | EE-12 | `EE-12` | solo | EE-01 | Concurrent safety; instance isolation |

> **Note on run 028 (coupled pair):** EE-07 defines join cancellation behaviour as: "An incoming branch  
> that was cancelled (via EE-08) contributes no token." Splitting would require EE-07's AC to reference  
> EE-08 before EE-08 is validated. Treating them as one unit avoids a forward-reference problem.

### Stage 4 — REST API & Authentication

| Run | ID | Unit | Type | Depends on | Notes |
|---|---|---|---|---|---|
| 034 | API-01 | `API-01` | solo | — (stage gate: Stage 3 MUST validated) | REST conventions; foundational for all endpoints |
| 035 | API-08 | `API-08` | solo | API-01 | Auth; must be clear before endpoint ACs reference it |
| 036 | API-12 | `API-12` | solo | DB-04 | Health endpoints; references DB health check AC |
| 037 | API-07 | `API-07` | solo | API-01 | Input validation; cross-cutting concern for all endpoints |
| 038 | API-09 | `API-09` | solo | API-01 | Tracing; cross-cutting concern |
| 039 | API-06 | `API-06` | solo | API-01 | Pagination spec; used by all list endpoints |
| 040 | API-02 | `API-02` | solo | PD-01..PD-08, API-01, API-07, API-08 | Definition CRUD endpoints |
| 041 | API-03 | `API-03` | solo | EE-01, EE-08, API-01, API-07, API-08 | Instance management endpoints |
| 042 | API-04 | `API-04` | solo | EE-03, EE-04, API-01, API-07, API-08 | Task operation endpoints |
| 043 | API-05 | `API-05` | solo | ES-02, ES-06, API-01, API-08 | History endpoint; queries event log |
| 044 | API-10 | `API-10` | solo | API-08 | SHOULD — rate limiting per token |
| 045 | API-11 | `API-11` | solo | API-01..API-12 | SHOULD — OpenAPI generated from all endpoints |

### Stage 5 — Scheduler & Identity

| Run | ID | Unit | Type | Depends on | Notes |
|---|---|---|---|---|---|
| 046 | IDN-01 | `IDN-01` | solo | — (stage gate: Stage 4 MUST validated) | User registry; foundational for identity |
| 047 | IDN-02 | `IDN-02` | solo | IDN-01 | Group management |
| 048 | IDN-03 | `IDN-03` | solo | IDN-01, IDN-02 | Role-based access; references full identity model |
| 049 | IDN-04 | `IDN-04` | solo | IDN-03 | Token management; requires role AC settled |
| 050 | SCH-01 | `SCH-01` | solo | EE-03 | Timer creation; references task/node model |
| 051 | SCH-02 | `SCH-02` | solo | SCH-01 | Timer polling; fires due timers |
| 052 | SCH-03 | `SCH-03` | solo | SCH-01, SCH-02, EE-08 | Cancellation; atomic with instance cancel (EE-08) |
| 053 | SCH-04 | `SCH-04` | solo | SCH-01, SCH-02, EE-03 | Escalation; HUMAN_TASK timer feature |
| 054 | SCH-05 | `SCH-05` | solo | SCH-01, SCH-02 | Missed timer recovery on restart |
| 055 | SCH-06 | `SCH-06` | solo | SCH-02 | SHOULD — jitter on polling interval |
| 056 | SCH-07 | `SCH-07` | solo | SCH-01 | SHOULD — recurring ISO 8601 timers |

### Stage 6 — Observability, Extensions & Integration

| Run | ID | Unit | Type | Depends on | Notes |
|---|---|---|---|---|---|
| 057 | OBS-01 | `OBS-01` | solo | — (stage gate: Stage 5 MUST validated) | Structured logging; foundational for all OBS |
| 058 | OBS-02 | `OBS-02` | solo | OBS-01 | Metrics expose log-derived counters |
| 059 | OBS-03 | `OBS-03` | solo | API-08 | Audit log; references actor identity |
| 060 | OBS-04 | `OBS-04` | solo | ES-02, OBS-01 | Timeline view; queries ordered event log |
| 061 | OBS-05 | `OBS-05` | solo | ES-01, OBS-01 | DLQ; stores failed event context |
| 062 | OBS-06 | `OBS-06` | solo | OBS-01, OBS-05 | SHOULD — alerting hooks |
| 063 | EXT-01 | `EXT-01` | solo | EE-03, OBS-05 | Service task; retries route to DLQ |
| 064 | EXT-02 | `EXT-02` | solo | OBS-05, EE-01 | Webhook dispatch; at-least-once via DLQ |
| 065 | EXT-03 | `EXT-03` | solo | EE-03 | SHOULD — plugin interface |
| 066 | EXT-04 | `EXT-04` | solo | EE-09, PD-06 | SHOULD — CEL variable transformer on edges |
| 067 | EXT-05 | `EXT-05` | solo | EE-01, EE-08, EE-10 | SHOULD — sub-process support |

---

## Stage gates for WF-02

WF-02 (implementation) may start for a requirement as soon as its status = `VALIDATED`.  
WF-02 for Stage N+1 MUST NOT start until all MUST requirements for Stage N are `RELEASED`.

---

## Parallelism opportunities

Within a stage, requirements with no dependency on each other (or only cross-stage dependencies)  
can be processed in parallel WF-01 runs:

- Stage 1: `ES-01` and `DB-01` are independent → parallel start
- Stage 3: `EE-01` and `EE-02` are independent at the start → parallel after `PD-08` is VALIDATED
- Stage 5: `IDN-01` and `SCH-01` are independent → parallel start within Stage 5

---

## Run ID convention

```
WF01-<REQ-ID>-20260520
e.g. WF01-ES01-20260520
     WF01-EE0607-20260520   (coupled pair)
```

## Current run status

| Run | Unit | WF-01 Status |
|---|---|---|
| 001 | ES-01 | PENDING (active) |
| 002–067 | (all others) | NOT STARTED |
