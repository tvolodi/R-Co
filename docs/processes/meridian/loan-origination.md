# Process: Loan Origination

| Field | Value |
|-------|-------|
| Process ID | `proc-meridian-loan-origination` |
| Owner | Meridian Capital AG |
| Tenant | `meridian` |
| Domain | Regulated lending — BaFin |

## Summary

A Credit Analyst submits a loan application. Three parallel tracks run
simultaneously: credit memo review, risk assessment, and KYC/AML compliance
check. All three must complete before the eligibility gate. Loans up to
€500,000 are approved by the Credit Director (L2). Loans above €500,000
require a Credit Committee vote with quorum of 2 of 3 members (CEO, CRO,
Credit Director). A KYC hit routes the application to a mandatory manual
compliance review before the parallel join.

---

## Roles

| Role | Person | Responsibility |
|------|--------|----------------|
| Credit Analyst | Sophie Weiß / Lars Berger | Creates loan application and credit memo |
| Credit Manager | Benjamin Koch | L1 review; requests additional information; rejects incomplete applications |
| Credit Director | Julia Hartmann | L2 approval for loans ≤ €500,000; convenes committee for loans > €500,000 |
| Risk Analyst | Oliver Krug | Performs risk assessment |
| Risk Manager | Miriam Schäfer | Approves risk assessment; escalates to committee if needed |
| Compliance Officer | Claudia Fuchs | Runs KYC/AML screening; approves compliance check |
| CEO | Eva Kremer | Credit Committee vote (loans > €500,000); regulatory sign-off |
| CRO | Thomas Reiter | Credit Committee vote (loans > €500,000); risk appetite setting |
| Loan Operations Specialist | Marcus Braun | Disburses loan after all approvals; updates core banking system |
| Credit Committee | Eva, Thomas, Julia | Votes on loans > €500,000; quorum = 2 of 3 APPROVE |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| Loan application | object | Borrower ID, loan amount (EUR), purpose, term, collateral |
| Loan amount | decimal (EUR) | Determines L1/L2 vs. committee path; ≥ 0 |
| Credit memo | document | Analyst's assessment of borrower creditworthiness |
| Borrower KYC data | object | ID documents, beneficial ownership, PEP/sanctions screening inputs |
| Risk data | object | Financial statements, sector risk, exposure data |

---

## Steps

| # | Actor | Action | Decision | Outcome |
|---|-------|--------|----------|---------|
| 1 | Credit Analyst | Submits loan application and credit memo | — | Application created; Credit Manager notified |
| 2 | Credit Manager | L1 review: completeness and eligibility check | Application complete? | Incomplete → returned to Analyst. Complete → Step 3 |
| **3 — Parallel tracks open simultaneously** | | | | |
| 3A | Risk Analyst | Performs risk assessment | — | Risk report created |
| 3A2 | Risk Manager | Approves risk assessment | Approved? | Yes → Track A done. No → Risk Analyst revises |
| 3B | Compliance Officer | Runs KYC/AML screening | KYC hit found? | No hit → Track B done. Hit → Step 3B2 |
| 3B2 | Compliance Officer | Manual compliance review | Review complete? | Yes → Track B done. Unresolvable → application rejected |
| 3C | Credit Manager | Reviews credit memo | Memo approved? | Yes → Track C done. No → returned to Analyst |
| **Parallel join** | | | | |
| 4 | Platform | Eligibility gate: all three tracks complete | All tracks done? | Yes → Step 5. No → wait |
| 5 | Credit Director | Convenes and routes based on amount | Amount > €500,000? | Yes → Step 6 (committee). No → Step 7 (L2 direct) |
| 6 | Credit Committee | Vote (Eva, Thomas, Julia) | Quorum ≥ 2 APPROVE? | Yes → Step 8. No → application rejected; reason documented |
| 7 | Credit Director | L2 approval decision | Approved? | Yes → Step 8. No → application rejected |
| 8 | Platform | Approval confirmed; disbursement authorised | — | Loan Operations Specialist notified |
| 9 | Loan Operations Specialist | Disburses loan; updates core banking | — | Funds transferred; facility created; process `COMPLETED` |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Three-track parallel assessment | Credit memo, risk assessment, and KYC/AML **all run simultaneously**. The eligibility gate (Step 4) does not open until all three are complete. No track can be skipped. |
| KYC hit → mandatory manual review | A KYC/AML screening hit **must** route to manual compliance review (Step 3B2) before the track is marked done. Approving a KYC-hit application without manual review is a BLOCKER. |
| €500,000 threshold | Loans **≤ €500,000**: Credit Director may approve directly (L2). Loans **> €500,000**: Credit Committee vote is mandatory. |
| Committee quorum | Committee requires **at least 2 of 3** APPROVE votes (Eva Kremer, Thomas Reiter, Julia Hartmann). A single BLOCKER vote from any member overrides quorum and blocks approval. |
| BaFin regulatory notification | If the compliance review SLA (30 days / 720 hours) is breached, BaFin must be notified automatically (§25a KWG). This is a legal obligation — failure to notify is always a BLOCKER. |
| L1 completeness gate | Credit Manager must confirm the application is complete and eligible before the parallel tracks open. Incomplete applications are returned; the parallel tracks do not start. |
| Disbursement only after full approval | No funds may be disbursed before Step 8 confirmation. Loan Operations Specialist has `disburse_loan` permission gated to approved applications only. |
| Immutable approval record | Once the committee or Credit Director approves, the approval decision is immutably logged with voter IDs and timestamps. |

---

## Outputs

| Output | Description |
|--------|-------------|
| Loan application status | `approved`, `rejected`, `pending` |
| Risk report | Risk Manager's signed assessment |
| KYC/AML record | Screening result and compliance officer sign-off |
| Credit committee minutes | Votes and rationale for all committee decisions (loans > €500,000) |
| Loan facility | Created in core banking system on disbursement |
| Audit trail | All track completions, votes, and state changes immutably logged |
| BaFin notification (if triggered) | Regulatory notice filed automatically on SLA breach |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Compliance review SLA | 30 days (720 hours) | KYC/AML manual review initiated | BaFin regulatory notification auto-filed on breach |
| Risk assessment SLA | Not formally defined | Risk track opened | Operational escalation to Risk Manager |
| Committee convening | Not formally defined | L2 routes to committee | Credit Director tracks; no automated timer |
| Total process SLA | Not formally defined | Application submission | Monitored by Credit Manager |

---

## Error / Exception Paths

| Situation | Trigger | Outcome |
|-----------|---------|---------|
| L1 returns incomplete application | Step 2 | Application sent back to Credit Analyst; no parallel tracks started |
| Risk assessment rejected | Step 3A2 | Risk Analyst revises and resubmits; Track A remains open |
| KYC hit — unresolvable | Step 3B2: manual review cannot clear | Application rejected; borrower notified; regulatory record created |
| Committee rejects | Step 6: fewer than 2 APPROVE | Application rejected; Credit Director documents reason |
| L2 rejects directly | Step 7 | Application rejected; Analyst notified |
| Compliance SLA breach | 720-hour timer fires | BaFin notification filed automatically; application continues |
| Disbursement fails | Step 9: core banking API error | Loan Operations escalates to Credit Director; retry or manual intervention |
