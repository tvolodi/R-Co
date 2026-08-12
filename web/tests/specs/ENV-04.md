# Test Specification — ENV-04

**Requirement ID:** ENV-04  
**Title:** UI clearly labels test tenants and blocks accidental production actions  
**Priority:** MUST  
**Author:** TEST-DESIGNER  
**Run:** WF02-env04-20260812 Step 03  

---

## Scope

These tests verify the three frontend surfaces added by ENV-04:

1. `TestEnvironmentBanner` — sticky yellow banner shown only in test-tenant sessions  
2. `ConfirmPromoteModal` — confirmation dialog that must display precise prescribed text  
3. `DefinitionEditorPage` promote button — visible only for test tenants with ACTIVE definitions  
4. `TenantsPage` `[TEST]` badge — displayed next to test-tenant rows in the admin table  

All tests are **component unit tests** (Vitest + React Testing Library, `@vitest-environment jsdom`).  
No network calls are made; dependencies are mocked via `vi.mock`.

---

## Test cases

| TC ID | Component | Input | Expected |
|---|---|---|---|
| TC-ENV04-01 | `TestEnvironmentBanner` | `tenantType='test'`, `productionDisplayName='Acme Production'` | Banner renders; "TEST ENVIRONMENT" and "Paired with production: Acme Production" visible |
| TC-ENV04-02 | `TestEnvironmentBanner` | `tenantType='production'` | Component returns null; banner absent from DOM |
| TC-ENV04-03 | `TestEnvironmentBanner` | `tenantType='test'`, `productionDisplayName=null` | "Paired with production: (unknown)" visible |
| TC-ENV04-04 | `ConfirmPromoteModal` | `definitionName='Onboarding Flow'`, `productionDisplayName='Acme Production'`, click Confirm | Heading and body match prescribed text exactly; `onConfirm` called once |
| TC-ENV04-05 | `ConfirmPromoteModal` | Same props, click Cancel | `onCancel` called once; `onConfirm` not called |
| TC-ENV04-06 | `DefinitionEditorPage` | `tenantType='test'`, `def.status='ACTIVE'`, designer role | `data-testid="promote-to-production-btn"` in DOM |
| TC-ENV04-07 | `DefinitionEditorPage` | `tenantType='production'`, `def.status='ACTIVE'`, designer role | `promote-to-production-btn` absent from DOM |
| TC-ENV04-07b | `DefinitionEditorPage` | `tenantType='test'`, `def.status='DRAFT'`, designer role | `promote-to-production-btn` absent from DOM |
| TC-ENV04-08 | `TenantsPage` | List with one test and one production tenant | `[TEST]` badge present for test tenant, absent for production tenant |
| TC-ENV04-09 | `InstanceBoardPage` | test tenant session, `useInstances` mocked to return one row | component renders row; `useInstances` called without `tenant_id` prop (backend-enforced isolation) |

---

## Coverage

All 10 test cases map 1-to-1 to TC-ENV04-01 through TC-ENV04-09 (TC-ENV04-07b is a sub-case of TC-ENV04-07).  
Each `test "..."` block in the implementation files corresponds to exactly one row above.

---

## Test file locations

| File | TCs |
|---|---|
| `web/src/components/layout/__tests__/TestEnvironmentBanner.test.tsx` | TC-ENV04-01, TC-ENV04-02, TC-ENV04-03 |
| `web/src/components/ui/__tests__/ConfirmPromoteModal.test.tsx` | TC-ENV04-04, TC-ENV04-05 |
| `web/src/pages/definitions/__tests__/DefinitionEditorPage.promote.test.tsx` | TC-ENV04-06, TC-ENV04-07, TC-ENV04-07b |
| `web/src/pages/admin/tenants/__tests__/TenantsPage.test.tsx` | TC-ENV04-08 |
| `web/src/pages/instances/__tests__/InstanceBoardPage.tenant-isolation.test.tsx` | TC-ENV04-09 |
