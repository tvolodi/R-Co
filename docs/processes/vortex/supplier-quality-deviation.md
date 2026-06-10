# Process: Supplier Quality Deviation

| Field | Value |
|-------|-------|
| Process ID | `proc-vortex-supplier-quality-deviation` |
| Owner | Vortex Manufacturing GmbH |
| Tenant | `vortex` |
| Domain | Quality Assurance — ISO 9001 |

## Summary

A Quality Engineer logs a defect against a supplier batch. The affected batch
is **immediately quarantined** in the MES before any severity assessment begins
(ISO 9001 hard requirement). The Quality Manager then classifies the deviation.
A CRITICAL classification spawns an 8D corrective action sub-process routed to
Procurement. A false-positive path releases the quarantine without locking the
batch.

---

## Roles

| Role | Person | Responsibility |
|------|--------|----------------|
| Quality Engineer | Nina Brandt | Detects defect, logs deviation, triggers quarantine |
| Quality Manager | Karl Fischer | Reviews deviation, performs severity classification |
| Procurement Manager | Felix Wagner | Executes 8D corrective action for CRITICAL deviations |
| CEO / MD | Dirk Haas | Final authority; may reject suppliers or override decisions |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| Supplier batch ID | string | Must reference an existing batch in the MES |
| Supplier ID | string | Must reference a registered supplier |
| Defect description | text | Required; minimum meaningful description |
| Sample data | object | Number of units sampled, defect count, defect type |
| Deviation severity (initial) | enum (optional) | Quality Engineer may suggest; Quality Manager is authoritative |

---

## Steps

| # | Actor | Action | Decision | Outcome |
|---|-------|--------|----------|---------|
| 1 | Quality Engineer | Logs deviation in QA system | — | Deviation record created |
| **2** | **Platform / MES** | **Immediately quarantines batch** | **Always — no condition** | **Batch locked in MES; no production use until classification** |
| 3 | Quality Manager | Reviews deviation and evidence | Classification decision | See Step 4a / 4b / 4c |
| 4a | Quality Manager | Classifies as **CRITICAL** | — | 8D corrective action sub-process spawned → Step 5 |
| 4b | Quality Manager | Classifies as **MAJOR** | — | Supplier corrective action requested (SCAR); batch remains quarantined |
| 4c | Quality Manager | Classifies as **MINOR** | — | Batch released from quarantine; supplier notified; deviation closed |
| 4d | Quality Manager | Classifies as **false positive** | — | Batch released from quarantine (no lock); deviation closed without penalty |
| 5 | Procurement Manager | Executes 8D corrective action | 8D steps complete? | Yes → Step 6. No → Procurement tracks open actions |
| 6 | Quality Manager | Reviews 8D completion | Satisfactory? | Yes → deviation formally closed. No → escalate to CEO |
| 7 | CEO | Reviews escalated deviation | CEO decision | Approve closure or reject supplier |
| 8 | Platform | Closes deviation record | — | Deviation status `closed`; audit trail complete; process `COMPLETED` |

---

## Business Rules

| Rule | Detail |
|------|--------|
| **Quarantine before classification** | Batch **must** be quarantined at Step 2, before Quality Manager reviews at Step 3. This ordering is non-negotiable under ISO 9001. Any deviation where classification precedes quarantine is a BLOCKER. |
| False-positive compensation | If the Quality Manager reclassifies to false positive, the quarantine is released **without creating a lock record** on the batch. The batch is treated as if it was never quarantined for production scheduling purposes. |
| CRITICAL → 8D mandatory | A CRITICAL classification **always** spawns the 8D sub-process routed to Procurement. This cannot be skipped. |
| MAJOR → SCAR | A MAJOR classification triggers a Supplier Corrective Action Request. The batch stays quarantined until SCAR resolution. |
| MINOR → release | A MINOR classification allows immediate batch release after Quality Manager sign-off. |
| Supplier rejection authority | Only the CEO holds `reject_supplier` permission. Procurement Manager may recommend but cannot unilaterally reject. |
| ISO 9001 audit trail | All steps — including the quarantine timestamp — are immutably logged for audit purposes. |

---

## Outputs

| Output | Description |
|--------|-------------|
| Deviation status | `open`, `under-8D`, `closed` |
| Batch quarantine status | `quarantined`, `released`, or `released-false-positive` |
| 8D corrective action record | Created for CRITICAL deviations; contains root cause, corrective actions, preventive actions |
| SCAR record | Created for MAJOR deviations; tracks supplier response |
| Audit trail | ISO 9001-compliant log with timestamps and actor IDs for every state change |
| Supplier notification | Formal notification sent to supplier for MAJOR and CRITICAL deviations |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Quarantine response | Immediate (synchronous) | Deviation logged | MES quarantine applied before any other step |
| 8D completion | Defined in 8D sub-process | CRITICAL classification | Procurement Manager tracked against D-deadlines; CEO escalation on breach |
| SCAR response | Defined by SCAR terms | MAJOR classification | Escalation to Quality Manager if supplier does not respond |

---

## Error / Exception Paths

| Situation | Trigger | Outcome |
|-----------|---------|---------|
| MES quarantine fails | Step 2: MES API error | Deviation record created but quarantine unconfirmed; Quality Manager notified; manual quarantine required; process blocked until confirmed |
| Quality Manager unavailable | Step 3: no response | Batch stays quarantined; escalation to CEO after SLA |
| 8D rejected by Quality Manager | Step 6: unsatisfactory completion | Procurement must redo relevant 8D steps; loop repeats |
| CEO rejects closure | Step 7 | Supplier rejection process initiated; deviation remains open |
| Batch consumed before quarantine | Race condition in MES | Audit event raised; deviation flagged as BLOCKER; manual production hold issued |
