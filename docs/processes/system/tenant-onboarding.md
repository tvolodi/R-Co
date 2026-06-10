# Process: Tenant Onboarding

| Field | Value |
|-------|-------|
| Process ID | `sys-tenant-onboarding` |
| Owner | Platform Admin |
| Scope | System-wide |
| Source | `src/identity/onboarding.zig` |

## Summary

Provisions a new tenant on the platform: creates the database schema, binds a
Keycloak realm, provisions the admin user with role assignment, registers the
tenant hostname, and verifies the setup end-to-end. Idempotent — a duplicate
slug or realm re-submission is rejected before any write occurs.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Platform Admin | System operator / automation | Initiates onboarding via API; receives result |
| BPM Platform | System | Executes all provisioning steps atomically |
| Keycloak (IdP) | Identity Provider | Creates and configures the realm and client |
| PostgreSQL | Database | Creates tenant schema and seed data |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `slug` | string | Unique across all tenants; used as DB schema name and realm ID |
| `display_name` | string | Human-readable tenant name |
| `admin_email` | string | Valid email; uniqueness enforced in Keycloak |
| `admin_username` | string | Valid Keycloak username |
| `admin_display_name` | string | Display name for the admin user |
| `hostname` | string | Unique FQDN bound to this tenant |
| `realm_config` | object (optional) | Token lifetime, password policy, signing key algorithm |
| `client_config` | object (optional) | Redirect URIs, service account flag |

---

## Steps

| # | Actor | Action | Decision | Outcome |
|---|-------|--------|----------|---------|
| 1 | Platform | Validate input | `slug` or `hostname` already exists? | → Error: `DuplicateTenantSlug` / `DuplicateHostname` |
| 2 | Platform | Generate idempotency key | Key already used? | → Error: `IdempotencyConflict` |
| 3 | PostgreSQL | Create tenant DB schema | Schema creation fails? | → Error: `PersistenceFailed` |
| 4 | Keycloak | Provision realm | Realm already exists? | → Error: `RealmAlreadyExists` / `RealmProvisioningFailed` |
| 5 | Keycloak | Create admin user | User creation fails? | → Error: `UserProvisioningFailed` |
| 6 | Keycloak | Assign admin roles | Role assignment fails? | → Error: `RoleAssignmentFailed` |
| 7 | Keycloak | Provision OAuth client | Client creation fails? | → Error: `ClientProvisioningFailed` |
| 8 | Platform | Bind hostname to tenant | Binding fails? | → Error: `HostnameBindingFailed` |
| 9 | Platform | Verify end-to-end setup | Verification fails? | → Error: `VerificationFailed`; state → `failed` |
| 10 | Platform | Return result | — | State → `completed`; return `OnboardingResult` |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Slug uniqueness | `slug` must be globally unique; checked before any write |
| Hostname uniqueness | `hostname` must be globally unique; checked before any write |
| Realm uniqueness | Keycloak realm ID derived from `slug`; rejected if realm already exists |
| Idempotency | Callers may retry with the same key; second call returns the existing result without re-provisioning |
| Atomicity | All steps form a single logical transaction; a failure at any step leaves no partial state (rollback executed) |
| Authorization | Only callers with platform-admin privilege may invoke this process (`Forbidden` error otherwise) |
| Pool availability | Provisioning requires a free connection from the pool; `PoolExhausted` if none available |

---

## Outputs

| Output | Description |
|--------|-------------|
| `onboarding_id` | UUID identifying this onboarding record |
| `tenant_id` | UUID of the newly created tenant |
| `idp_realm_id` | Keycloak realm ID (equals `slug`) |
| Tenant state | `completed` persisted in the onboarding table |
| DB schema | `<slug>` schema created in PostgreSQL |
| Keycloak realm | Realm with admin user, roles, and OAuth client |
| Hostname binding | FQDN mapped to tenant in routing table |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| No SLA defined | Onboarding is synchronous; caller waits for the result |
| Step timeout | Keycloak and DB calls are subject to connection pool timeout; `PoolExhausted` returned to caller |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| `DuplicateTenantSlug` | `slug` already registered | Caller must choose a different slug |
| `DuplicateHostname` | `hostname` already bound | Caller must provide a different hostname |
| `RealmAlreadyExists` | Keycloak realm exists but tenant record does not | Manual cleanup required; indicates prior partial run |
| `RealmProvisioningFailed` | Keycloak API error during realm creation | Platform rolls back DB schema; caller may retry |
| `UserProvisioningFailed` | Keycloak API error during user creation | Platform rolls back realm and DB schema |
| `RoleAssignmentFailed` | Keycloak API error during role grant | Platform rolls back user, realm, and DB schema |
| `ClientProvisioningFailed` | Keycloak OAuth client creation fails | Platform rolls back all prior steps |
| `HostnameBindingFailed` | Routing table write fails | Platform rolls back all prior steps |
| `VerificationFailed` | End-to-end check after all steps fails | State set to `failed`; manual investigation required |
| `IdempotencyConflict` | Same key used with different parameters | Caller must not reuse keys across distinct requests |
| `Forbidden` | Caller lacks platform-admin privilege | Caller must authenticate with platform-admin credentials |
| `ValidationFailed` | Input fields fail format checks | Caller must fix and resubmit |
| `OutOfMemory` | Allocator exhausted | Platform restarts the request handler |
