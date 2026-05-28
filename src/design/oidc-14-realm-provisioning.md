# Module: OIDC-14 Realm Provisioning via Adapter

## Module purpose

This module extends the OIDC-01 `IdentityProvider.provisionRealmFn` contract with a richer provisioning profile that, beyond basic realm creation, configures default token lifetimes, password policy, MFA policy, signing key generation, and the OIDC-13 `tenant_id` protocol mapper. The Keycloak adapter (`oidc-02-keycloak-adapter.md`) implements this via the Keycloak Admin REST API. The goal is that creating a BPM tenant (OIDC-12) with `provision_realm: true` results in a fully configured, immediately-usable realm at the provider.

## Public interface

### Extended provisioning input (extends OIDC-01 `ProvisionRealmInput`)

```zig
/// Extended realm provisioning configuration passed through the
/// IdentityProvider interface.
pub const ProvisionRealmInput = struct {
    /// The BPM tenant UUID that this realm is being created for.
    tenant_id: [36]u8,
    /// A URL-safe, human-readable identifier for the realm.
    /// Used as the Keycloak realm name if desired_realm_id is not set.
    tenant_slug: []const u8,
    /// Human-readable display name for the realm.
    display_name: []const u8,
    /// Optional explicit realm identifier override. If null,
    /// the adapter normalizes tenant_slug.
    desired_realm_id: ?[]const u8,

    // --- Realm configuration (new for OIDC-14) ---

    /// Default access token lifetime in seconds.
    /// Keycloak default: 300 (5 minutes).
    /// Recommended BPM default: 900 (15 minutes).
    default_token_lifetime_seconds: u32 = 900,
    /// Default ID token lifetime in seconds.
    /// Keycloak default: 300 (5 minutes).
    /// Recommended BPM default: 900 (15 minutes).
    default_id_token_lifetime_seconds: u32 = 900,
    /// Default refresh token lifetime in seconds.
    /// Keycloak default: 1800 (30 minutes).
    /// Recommended BPM default: 3600 (60 minutes).
    default_refresh_token_lifetime_seconds: u32 = 3600,
    /// Session max lifetime in seconds (absolute expiry, not sliding).
    /// Keycloak default: 86400 (24 hours).
    /// Recommended BPM default: 28800 (8 hours).
    session_max_lifetime_seconds: u32 = 28800,

    // --- Password policy ---
    /// Minimum password length. 0 = no minimum (use Keycloak defaults).
    min_password_length: u8 = 8,
    /// Whether to require at least one uppercase character.
    require_uppercase: bool = true,
    /// Whether to require at least one digit.
    require_digit: bool = true,
    /// Whether to require at least one special character.
    require_special_char: bool = false,
    /// Number of previous passwords to remember (0 = disabled).
    password_history_count: u8 = 5,

    // --- MFA / OTP policy ---
    /// Whether OTP (TOTP) is required for all users in this realm.
    otp_required: bool = false,
    /// OTP algorithm. Keycloak supports SHA1, SHA256, SHA512.
    otp_algorithm: OtpAlgorithm = .SHA256,
    /// OTP token length (6 or 8).
    otp_digits: u8 = 6,
    /// OTP look-ahead window (number of adjacent time steps to accept).
    otp_look_ahead: u8 = 1,

    // --- Signing key ---
    /// The signing key algorithm for the realm's active keyset.
    /// Keycloak defaults to RS256 when not specified.
    signing_key_algorithm: SigningAlgorithm = .RS256,
    /// Whether to regenerate the realm keys on provisioning.
    /// If false, Keycloak auto-generates keys on first use.
    regenerate_keys: bool = true,
};

pub const OtpAlgorithm = enum {
    SHA1,
    SHA256,
    SHA512,
};

pub const SigningAlgorithm = enum {
    RS256,
    RS384,
    RS512,
    ES256,
    ES384,
    ES512,
    PS256,
    PS384,
    PS512,
};
```

### Provisioning result

```zig
/// Extended provisioning result.
pub const ProvisionRealmResult = struct {
    /// The chosen realm identifier (matches desired_realm_id or
    /// normalized tenant_slug).
    realm_id: []const u8,
    /// True when a new realm was created; false when the realm
    /// already existed (idempotent path).
    created: bool,
    /// The realm's keyset info (only populated when created=true).
    keyset: ?KeysetInfo,
    /// The protocol mapper ID for the tenant_id claim mapper.
    tenant_id_mapper_id: ?[]const u8,
};

pub const KeysetInfo = struct {
    /// The active key algorithm.
    algorithm: SigningAlgorithm,
    /// The active key's Key ID (kid) as used in JWKS.
    kid: []const u8,
    /// The JWKS URL for this realm.
    jwks_url: []const u8,
};
```

### Adapter-local realm provisioning function (Keycloak)

In `src/identity/provider/adapters/keycloak/realm_api.zig`, the provisioning sequence:

```zig
/// Provision a fully configured realm at Keycloak.
///
/// Keycloak Admin REST sequence:
///   1. GET /admin/realms/{realm_id} — idempotency check (skip if exists).
///   2. POST /admin/realms — create realm with basic config.
///   3. PUT /admin/realms/{realm_id} — apply token/session lifetimes.
///   4. PUT /admin/realms/{realm_id}/password-policy — set password policy.
///   5. PUT /admin/realms/{realm_id}/authentication/required-actions/VERIFY_PROFILE/config
///      or PUT /admin/realms/{realm_id}/otp-policy — set OTP policy.
///   6. POST /admin/realms/{realm_id}/keys — regenerate signing keys
///      (if regenerate_keys is true — keys are auto-created on first
///      issuance when not explicitly regenerated).
///   7. POST /admin/realms/{realm_id}/protocol-mappers/models
///      — create the tenant_id claim mapper (OIDC-13).
///   8. GET /admin/realms/{realm_id} — read back full realm config
///      including generated keyset info.
///
/// The adapter MUST handle partial failures:
///   - If step 2 succeeds but step 3 fails → realm exists but is
///     partially configured. Log a CRITICAL alert for reconciliation.
///   - The function is NOT idempotent, but the idempotency check
///     (step 1) ensures the caller can safely retry: on retry the
///     realm already exists and steps 3-8 are reapplied as an
///     "ensure configuration" pass.
///
/// Error cases (all from provider_errors):
///   - UpstreamUnavailable / UpstreamTimeout: Keycloak unreachable.
///   - DuplicateResource: Realm already exists (from step 1 check).
///   - UnauthorizedAdminCall: Admin token expired or invalid.
///   - UpstreamProtocolError: Unexpected Keycloak response.
///   - OutOfMemory.
pub fn provisionRealm(
    admin_token: *AdminToken,
    http_client: *HttpClient,
    input: ProvisionRealmInput,
) ProvisionError!ProvisionRealmResult;
```

### Default realm configuration constants

```zig
/// Default realm configuration used when provisioning a BPM tenant realm.
pub const DEFAULT_REALM_CONFIG = struct {
    token_lifetimes: TokenLifetimesConfig = .{},
    password_policy: PasswordPolicyConfig = .{
        .min_password_length = 8,
        .require_uppercase = true,
        .require_digit = true,
        .password_history_count = 5,
    },
    otp_policy: OtpPolicyConfig = .{
        .otp_required = false,
    },
    signing: SigningConfig = .{
        .algorithm = .RS256,
    },
};
```

## Key invariants

1. **Realm provisioning is a multi-step, partially-failure-tolerant operation.** Each step configures a different aspect of the realm. If a non-critical step fails (e.g., password policy), the realm is still usable but configuration is incomplete. Critical steps (realm creation, tenant_id mapper) must succeed for the realm to be functional.

2. **Idempotent on retry.** If the first attempt fails mid-sequence, retrying must not produce duplicate configuration. The GET-before-POST pattern for realm creation and `PUT` (not `POST`) for configuration updates ensures this.

3. **Tenant_id mapper is mandatory.** Without the protocol mapper (OIDC-13), the realm cannot participate in tenant-scoped operations. If step 7 fails, the provisioning result MUST indicate that the realm exists but is not fully tenant-ready.

4. **Default configuration is sensible for production.** Token lifetimes are longer than Keycloak defaults to reduce auth overhead in BPM workflows (processes may run for hours). Password policy enforces basic strength. MFA is optional per-tenant.

5. **Signing key regeneration is optional.** `regenerate_keys = true` ensures the realm has a fresh key pair immediately, so the first token issued uses the correct algorithm. When `false`, Keycloak auto-generates keys on first token issuance — this is acceptable for test environments.

## DB tables/columns touched

No new DB tables or columns. The realm configuration is stored entirely within Keycloak's internal database. The BPM platform only stores the binding reference (`tenant.idp_realm_id` from ADP-04b / OIDC-12).

If realm configuration overrides (per-tenant deviations from defaults) are needed in future, they would be stored in a new `realm_provisioning_config` table:

```sql
-- Future (not part of OIDC-14 initial implementation):
CREATE TABLE IF NOT EXISTS realm_provisioning_config (
    tenant_id UUID PRIMARY KEY REFERENCES tenant(tenant_id),
    token_lifetime_seconds INT NOT NULL DEFAULT 900,
    refresh_token_lifetime_seconds INT NOT NULL DEFAULT 3600,
    password_policy_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    otp_required BOOLEAN NOT NULL DEFAULT FALSE,
    signing_algorithm TEXT NOT NULL DEFAULT 'RS256',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

This table is NOT part of OIDC-14 and should only be added if the per-tenant override requirement is confirmed.

## Cross-module dependencies

### This module calls / depends on:

| Module | Why |
|---|---|
| `src/identity/provider/interface.zig` | `IdentityProvider.provisionRealmFn` — the function pointer contract |
| `src/identity/provider/adapters/keycloak/realm_api.zig` | Keycloak-specific realm provisioning REST calls |
| `src/identity/provider/adapters/keycloak/admin_token.zig` | Admin bearer token acquisition for REST calls |
| `src/identity/provider/adapters/keycloak/http_client.zig` | Transport layer for admin REST calls |
| `src/identity/provider/types.zig` | `ProvisionRealmInput`, `ProvisionRealmResult` |
| `src/identity/provider/errors.zig` | Provider error types |
| OIDC-12 module | `resolveRealmByTenant` — to get the realm ID for an existing tenant |
| OIDC-13 module | `createTenantIdMapper` — protocol mapper configuration |

### This module must NOT depend on:

| Module | Why |
|---|---|
| `src/db/pool.zig` | Realm config is in Keycloak, not in BPM DB |
| `src/oidc/jit_provisioning.zig` | JIT provisioning consumes the realm, does not create it |
| Any route handler or API module | Configuration-only, no HTTP awareness for BPM endpoints |

## Identified risks / open questions

1. **Keycloak API stability for realm configuration endpoints.** The password-policy, OTP-policy, and keys endpoints are less frequently used than basic realm CRUD and may have changed in Keycloak 26.x. Integration testing must verify each endpoint's request/response format.

2. **Partial provisioning failure handling.** If the realm is created but configuration fails, the realm exists in an incomplete state. Options:
   - Return the realm as partially provisioned (mark `tenant.idp_realm_id` as 'provisioning_incomplete' state — requires a state column on tenant).
   - Destroy the incomplete realm and return an error (but the caller may not retry).
   - Leave the incomplete realm for manual remediation.
   
   **Recommended approach:** Return the realm as created but include a `warnings` list in `ProvisionRealmResult` indicating which steps failed. The tenant still gets its `idp_realm_id` set. A background reconciliation process (or the next provisioning retry) re-applies the missing configuration.

3. **Token lifetime vs. BPM workflow duration.** Default token lifetime (15 min) may be too short for long-running BPM processes that accumulate tasks. Refresh tokens handle this, but clients must implement refresh logic. If a client holds a stale access token beyond the lifetime, the platform returns 401 — the client must refresh. This is standard OIDC behaviour, but BPM-specific SDKs should handle refresh transparently.

4. **Signing key rotation.** Regenerating keys at provisioning is a one-time operation. For ongoing key rotation, Keycloak's automatic key rotation should be configured. This is outside the scope of provisioning but should be documented for platform operators.
