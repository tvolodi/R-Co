# Test Spec: OIDC-F-02 — Realm slug embedded in OIDC callback redirect_uri

**Requirement ID:** OIDC-F-02  
**Issue:** ISS-0073  
**Layer:** Frontend unit test (Vitest / jsdom)  
**Source file:** `web/src/auth/buildRedirectArgs.test.ts`  
**Helper under test:** `buildRedirectArgs()` in `web/src/auth/oidcRedirectArgs.ts`

---

## Background

When `ProtectedRoute` (and `AuthProvider` on session-expiry) calls
`m.signinRedirect(buildRedirectArgs())`, the resulting `redirect_uri` must
include `?realm=<slug>` so that `OidcCallbackPage` can identify the correct
Keycloak realm after the authorization-code redirect, independently of
`sessionStorage` state. Without this, a hard refresh of a protected page drops
the `sessionStorage` entry and causes a login-redirect loop (ISS-0073).

---

## Test Cases

| # | ID | Description | Expected |
|---|---|---|---|
| 1 | TC-OIDC-F02-01 | Slug present — returns qualified redirect_uri | `{ redirect_uri: origin + '/auth/callback?realm=swiftroute' }` |
| 2 | TC-OIDC-F02-02 | No slug — returns undefined | `undefined` |
| 3 | TC-OIDC-F02-03 | Slug with special chars — encodes correctly | `redirect_uri` contains `my%20realm%2Ftest` |

---

## TC-OIDC-F02-01: Returns realm-qualified redirect_uri when slug present

**Setup:**
- `resolveRealmFromUrl()` mocked to return `'swiftroute'`
- `window.location.origin` stubbed to `'https://app.example.com'`

**Action:** call `buildRedirectArgs()`

**Assert:**
- Result is `{ redirect_uri: 'https://app.example.com/auth/callback?realm=swiftroute' }`

---

## TC-OIDC-F02-02: Returns undefined when no slug

**Setup:**
- `resolveRealmFromUrl()` mocked to return `null`

**Action:** call `buildRedirectArgs()`

**Assert:**
- Result is `undefined`
- `signinRedirect(undefined)` causes UserManager to use its built-in `redirect_uri`

---

## TC-OIDC-F02-03: Encodes special characters in realm slug

**Setup:**
- `resolveRealmFromUrl()` mocked to return `'my realm/test'`

**Action:** call `buildRedirectArgs()`

**Assert:**
- `result.redirect_uri` contains `'my%20realm%2Ftest'`
- Full value is `'https://app.example.com/auth/callback?realm=my%20realm%2Ftest'`

---

## Coverage

- Implemented test blocks: 3
- Spec cases: 3
- All MUST acceptance criteria covered: YES
- No `test.skip` used
- No HTTP mocking (DIRECTIVE T-2 compliant — pure utility function)
