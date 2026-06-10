# Process: Compliance Review

| Field | Value |
|-------|-------|
| Process ID | `proc-meridian-compliance-review` |
| Owner | Meridian Capital AG |
| Tenant | `meridian` |
| Domain | Regulated lending — BaFin (§25a KWG) |

## Summary

Triggered when a KYC/AML screening returns a hit during loan origination, or
when a standalone compliance review is initiated. The Compliance Officer
investigates the hit, gathers evidence, and renders a decision. If the
30-day statutory review period is breached, BaFin must be notified
automatically. The review result feeds back into the loan origination process
or stands alone as a compliance record.

---

## Roles

| Role | Person | Responsibility |
|------|--------|----------------|
| Compliance Officer | Claudia Fuchs | Leads the manual review; gathers evidence; renders decision |
| Risk Manager | Miriam Schäfer | Provides risk context if screening involves counterparty exposure |
| CRO | Thomas Reiter | Escalation authority; approves high-risk compliance decisions |
| CEO | Eva Kremer | Regulatory sign-off and escalation for BaFin notifications |
| Platform | System | Runs screening, tracks the 30-day timer, files BaFin notification automatically |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| Loan application reference | UUID | Links the review to the originating application |
| KYC screening result | object | Hit categories: PEP, sanctions, adverse media, beneficial ownership |
| Borrower identity data | object | Legal entity or individual — name, DOB, country, identifiers |
| Beneficial ownership data | object | UBO chain with percentage thresholds |
| Trigger type | enum | `kyc-hit`, `aml-hit`, `adverse-media`, `manual-initiation` |

---

## Steps

| # | Actor | Action | Decision | Outcome |
|---|-------|--------|----------|---------|
| 1 | Platform | Receives KYC hit from screening service | Trigger type? | Loan origination Track B2 opened; 30-day timer starts |
| 2 | Compliance Officer | Acknowledges review and assigns priority | — | Review record created; evidence collection begins |
| 3 | Compliance Officer | Gathers and evaluates evidence | PEP / sanctions / adverse media? | Each category follows specific investigation sub-steps |
| 3a | Compliance Officer | PEP investigation | PEP confirmed with political exposure? | Yes → Risk Manager consulted. No → PEP finding dismissed |
| 3b | Compliance Officer | Sanctions screening | Confirmed sanctions match? | Yes → application blocked; regulatory filing. No → cleared |
| 3c | Compliance Officer | Adverse media review | Material adverse finding? | Yes → CRO review. No → cleared |
| 3d | Compliance Officer | Beneficial ownership check | UBO chain opaque or > 25% undisclosed? | Yes → request clarification. No → cleared |
| 4 | Risk Manager | Provides risk opinion (if escalated from 3a or 3c) | — | Risk opinion documented on review record |
| 5 | Compliance Officer | Renders final decision | Decision? | `cleared` → Step 6a. `blocked` → Step 6b. `pending-info` → return to Step 3 |
| 6a | Compliance Officer | Marks review `cleared` | — | Loan origination Track B2 marked done; origination continues |
| 6b | Compliance Officer | Marks review `blocked`; escalates to CRO | CRO confirms block? | Yes → application rejected; regulatory record created. No → CRO sends back for more investigation |
| **Timer path** | | | | |
| T | Platform | 30-day SLA timer fires (720 hours from Step 1) | Review not yet closed? | BaFin notification auto-filed; CEO notified; review continues |
| 7 | Platform | Closes review record | — | Final status logged; process `COMPLETED` |

---

## Business Rules

| Rule | Detail |
|------|--------|
| BaFin notification mandatory | If the compliance review is not closed within **30 days (720 hours)**, BaFin **must** be notified automatically under §25a KWG. This is a statutory obligation — failure is always a BLOCKER. |
| Sanctions hit → immediate block | A confirmed sanctions list match immediately blocks the loan application. No further review steps proceed; a regulatory filing is created automatically. |
| PEP confirmation → Risk Manager mandatory | A confirmed PEP finding requires Risk Manager input before the Compliance Officer can render a final decision. |
| Adverse media → CRO review | Material adverse media findings require CRO review before closure. |
| UBO opacity → information request | If the beneficial ownership chain cannot be established or exceeds 25% undisclosed, the Compliance Officer must request clarification from the borrower before clearing. |
| Review cannot be closed while pending information | Step 5 `pending-info` outcome sends the process back to Step 3; the review cannot be marked complete while outstanding information requests exist. |
| Regulatory filing immutable | Once a BaFin notification or sanctions filing is created, it cannot be retracted or modified. |

---

## Outputs

| Output | Description |
|--------|-------------|
| Compliance review status | `cleared`, `blocked`, or `closed-with-notification` |
| Review record | Full evidence log with actor IDs, timestamps, and decision rationale |
| BaFin notification | Auto-filed on SLA breach; references application ID and review record |
| Sanctions filing | Created on confirmed sanctions match; submitted to relevant authority |
| Risk opinion | Risk Manager's documented opinion (if PEP or adverse media escalation) |
| Loan origination track result | Feeds `Track B done` (cleared) or `rejected` (blocked) back to loan origination |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Statutory review SLA | 30 days / 720 hours | KYC hit received (Step 1) | BaFin notification auto-filed; CEO notified; review continues |
| Information request timeout | Not formally defined | Borrower information request issued | Compliance Officer escalates to CRO after reasonable waiting period |
| Sanctions response | Immediate | Confirmed sanctions match | Application blocked; regulatory filing created synchronously |

---

## Error / Exception Paths

| Situation | Trigger | Outcome |
|-----------|---------|---------|
| Screening service unavailable | Step 1: external API error | Review record created with `pending-screening` status; retry automatically; escalate to CRO if unresolved within 24 hours |
| Borrower does not provide UBO information | Step 3d: no response | After reasonable period, Compliance Officer marks application as `blocked` due to insufficient KYC |
| CRO overrules Compliance Officer | Step 6b: CRO rejects block | Additional investigation required; CRO must document rationale; review loops back to Step 3 |
| BaFin notification fails to send | Timer T: platform error | CEO notified immediately; manual notification required; platform error logged as CRITICAL |
| Concurrent review for same borrower | New application submitted while review open | Compliance Officer links reviews; new application put on hold until first review completes |
