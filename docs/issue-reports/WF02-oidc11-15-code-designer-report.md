# CODE-DESIGNER Report: OIDC-11 through OIDC-15

**Run ID:** WF02-oidc11-15-20260528  
**Handoff:** step-01-code-designer (ID: 0b3b27c4)  
**Completed:** 2026-05-27T20:47:23Z  
**Result:** PASS

## Artefacts produced

| File | Requirement |
|---|---|
| `src/design/oidc-11-external-user-identity-stability.md` | OIDC-11: `sub` as stable identifier, `(external_realm, external_id)` authoritative lookup |
| `src/design/oidc-12-realm-tenant-binding.md` | OIDC-12: tenant ↔ realm one-to-one binding, `tenant.idp_realm_id` |
| `src/design/oidc-13-tenant-claim-source.md` | OIDC-13: Keycloak protocol mapper for `tenant_id` claim, client override prevention |
| `src/design/oidc-14-realm-provisioning.md` | OIDC-14: Extended realm provisioning (token lifetimes, password/MFA policy, signing keys, protocol mapper) |
| `src/design/oidc-15-realm-deletion-safety.md` | OIDC-15: Two-phase deletion (mark → grace period → hard delete), audit-logged |

## Open issues (MINOR)

1. **Orphan realm at IdP (OIDC-12):** If IdP realm creation succeeds but DB INSERT fails, the realm exists at the provider without a tenant binding. Needs background reconciliation.
2. **Partial provisioning failure (OIDC-14):** Multi-step realm provisioning may partially fail (e.g., password policy applied but OTP policy not). Needs operational guide for retry/reconciliation.
3. **Post-deletion user migration (OIDC-15):** After hard delete, OIDC users from the deleted realm should be marked INACTIVE. Not in scope for initial implementation.

## Next action

Route to BACKEND-DEV for Step 2a implementation.
