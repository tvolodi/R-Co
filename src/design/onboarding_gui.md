# Design: Stage F7 — Tenant Onboarding GUI

**Requirements covered:** ONB-UI-01, ONB-UI-02, ONB-UI-03, ONB-UI-04  
**Classification:** Type E (novel — multi-step wizard with async saga polling; no matching codegen template)  
**Related designs:** oidc35-onboarding.md, oidc-12-realm-tenant-binding.md, oidc-17-provisioning-idempotency.md  

---

## 1. Classification Rationale

All four requirements are classified as **Type E** because:

- The flow is a multi-step wizard (form → progress → result) with shared state, not a standalone CRUD page.
- Step 3 (ONB-UI-03) has a non-trivial polling lifecycle with transient-error counting, cleanup-on-unmount, and page-reload restore logic.
- The idempotency-key lifecycle (generated fresh per submission, distinct across retries) is cross-cutting UI state not captured by any Type A/B/D template.
- The "Try Again" action requires carrying form values backward across the wizard — a pattern absent from any codegen template.

---

## 2. Route Structure

All four screens live under the existing admin subtree. They are registered as children of the root layout route (inside `ProtectedRoute` + `AppShell`) exactly as all other admin pages are registered today in `router.tsx`.

| Screen | Path |
|---|---|
| Register Tenant form | `/admin/onboarding/new` |
| Onboarding progress | `/admin/onboarding/:onboardingId/progress` |
| Onboarding result | `/admin/onboarding/:onboardingId/result` |

The `/admin/onboarding/new` path is the entry point linked from the sidebar. The progress and result paths are navigated to programmatically by the application, never entered by the user directly during the happy path. Both can, however, be reloaded by the browser, and both must restore their state on mount.

There is no `/admin/onboarding` index path. If a user navigates to `/admin/onboarding`, the router should redirect to `/admin/onboarding/new`.

---

## 3. Screen Breakdown

### 3.1 RegisterTenantPage

**Purpose:** Collect all required onboarding inputs from the PLATFORM_ADMIN, validate them client-side, and submit to the backend.

This page renders a single-screen form. It has no sub-panels or tabs. It occupies the main content area under `AppShell` exactly as `UsersPage` and `HealthDashboardPage` do today.

Fields presented (matching the POST body, see section 4):

- `slug` — tenant identifier
- `display_name` — human-readable tenant name
- `admin_email` — email address for the initial tenant admin account
- `admin_username` — login username for the initial tenant admin
- `admin_display_name` — display name for the initial tenant admin
- `hostname` — the hostname by which this tenant's realm will be reached
- `redirect_uris` — one or more OAuth redirect URIs (dynamic list; at least one entry required)
- `realm_config` section (optional, collapsible):
  - `default_token_lifetime_seconds` (integer, optional)
  - `min_password_length` (integer, optional)
  - `require_uppercase` (boolean, optional)
  - `require_digit` (boolean, optional)
  - `signing_key_algorithm` (string, optional)
- `client_config` section (optional, collapsible):
  - `service_account_enabled` (boolean, optional)

The page performs role enforcement on render (see section 6). If the user does not hold `PLATFORM_ADMIN`, the page redirects immediately to `/instances`.

On submission, if client-side validation fails, the form stays on this page and displays per-field error messages. No network call is made.

On successful submission (POST returns 201), the page navigates to `/admin/onboarding/:onboardingId/progress`, passing the submitted form values through router state (not URL parameters) so that the progress screen can pass them to the result screen for "Try Again" pre-fill.

### 3.2 OnboardingProgressPage

**Purpose:** Display a "working" indicator while the onboarding saga executes, and advance to the result screen when the saga reaches a terminal state.

This page receives the `onboardingId` from the URL parameter. It begins polling immediately on mount. It displays a spinner or indeterminate progress bar and a status message.

The page performs role enforcement on render (see section 6). If the user does not hold `PLATFORM_ADMIN`, the page redirects immediately to `/instances`.

The page reads the submitted form values from router location state (passed forward from `RegisterTenantPage`) so it can pass them to the result screen via router state when navigating.

When the poll response shows `state: "completed"`, the page stops polling and navigates to `/admin/onboarding/:onboardingId/result`, carrying the submitted form values in router state.

When the poll response shows `state: "failed"`, the page stops polling and navigates to `/admin/onboarding/:onboardingId/result`, carrying the submitted form values and the failure detail from the response body in router state.

### 3.3 OnboardingResultPage

**Purpose:** Show the final outcome of the onboarding saga — either success details or failure with a "Try Again" action.

This page receives the `onboardingId` from the URL parameter.

On mount, the page attempts to restore state from router location state first. If location state is absent (e.g. the user reloaded the page), the page calls `GET /api/v1/onboarding?hostname=<h>` where `<h>` is the hostname extracted from URL search params (see section 7).

The page performs role enforcement on render (see section 6). If the user does not hold `PLATFORM_ADMIN`, the page redirects immediately to `/instances`.

**Completed outcome view:** Renders the tenant `slug` and `oidc_authority` URL from the saga response. Provides a button to navigate back to the admin section.

**Failed outcome view:** Renders the failure reason from the saga response. Provides a "Try Again" button that navigates back to `/admin/onboarding/new`, passing the original form values through router location state for pre-fill.

---

## 4. API Integration

### 4.1 POST /api/v1/onboarding — called by RegisterTenantPage on submit

**When called:** When the user submits the registration form and client-side validation passes.

**Request:**
- Method: POST
- Path: `/api/v1/onboarding`
- Headers: `Authorization: Bearer <token>` (injected by `client.ts`), `Idempotency-Key: <uuid>` (generated fresh per submission by the page)
- Body fields sent:
  - `slug` (string, required)
  - `display_name` (string, required)
  - `admin_email` (string, required)
  - `admin_username` (string, required)
  - `admin_display_name` (string, required)
  - `hostname` (string, required)
  - `client_config.redirect_uris` (array of strings, at least one entry)
  - `client_config.service_account_enabled` (boolean, optional — only sent if set)
  - `realm_config.default_token_lifetime_seconds` (integer, optional — only sent if set)
  - `realm_config.min_password_length` (integer, optional — only sent if set)
  - `realm_config.require_uppercase` (boolean, optional — only sent if set)
  - `realm_config.require_digit` (boolean, optional — only sent if set)
  - `realm_config.signing_key_algorithm` (string, optional — only sent if set)

**Response fields read:**
- `201` success: `onboarding_id` (string) — used to construct the progress screen URL
- `409` with body `{"error":"onboarding_in_progress"}` — a prior submission with the same idempotency key is still running; treat as "already in progress"; navigate to progress screen using the `onboarding_id` from the idempotency duplicate record if available, or show an inline warning that a submission is already in flight
- `409` with RFC 9457 body and type `https://bpm.example.com/problems/idempotency-conflict` — idempotency key reused with different body; this should not occur in normal flow since each submission generates a fresh key; treat as a generic API error
- `422` — server-side validation failed; show inline form error (see error taxonomy, section 8)
- `503` — service unavailable; show inline form error
- Other non-2xx — show generic API error banner

### 4.2 GET /api/v1/onboarding/:onboardingId — called by OnboardingProgressPage during polling

**When called:** On a fixed interval while the progress screen is mounted (see section 6).

**Request:**
- Method: GET
- Path: `/api/v1/onboarding/<onboardingId>` where `onboardingId` is taken from the URL parameter
- Headers: `Authorization: Bearer <token>` (injected by `client.ts`)

**Response fields read from the `response_body_json` embedded in the record:**
- `state` — one of `pending`, `completed`, `failed` (note: the backend uses `pending`; the requirements text says `fresh`/`in_progress` — implement against the backend enum, not the requirement wording)
- On `completed`: `onboarding_id`, `tenant_id`, `idp_realm_id`, `client_id`, `admin_user_id`, `hostname`, `oidc_authority`, `discovery_url`, `created`
- On `failed`: `error` (string describing the failure reason)

The backend returns the stored `response_body_json` verbatim as the 200 body. For a pending record, the body is `{}` or the initial empty object written at insert time.

### 4.3 GET /api/v1/onboarding?hostname=<hostname> — called by OnboardingResultPage on page-reload restore

**When called:** On mount of `OnboardingResultPage` when router location state is absent (see section 7).

**Request:**
- Method: GET
- Path: `/api/v1/onboarding` with query parameter `hostname=<h>`
- The hostname is stored in the result page URL as a search param: `/admin/onboarding/:onboardingId/result?hostname=<h>`

**Response fields read:** Same as 4.2. The backend filters to `state = 'completed'` for this endpoint. If the saga was a failure, this endpoint returns 404; the page should fall back to showing a "could not restore state" message with a link to start over.

---

## 5. State Flow

The three pages share state through two mechanisms: React Router location state (for forward-navigation) and URL search params (for page-reload restore).

### 5.1 Forward state (form → progress → result)

When `RegisterTenantPage` submits successfully and receives an `onboarding_id`, it navigates to the progress screen using `navigate('/admin/onboarding/:id/progress', { state: { formValues, hostname } })`. The `formValues` object contains all form field values as submitted. The `hostname` field is duplicated at the top level for convenience.

When `OnboardingProgressPage` detects a terminal saga state, it navigates to the result screen using `navigate('/admin/onboarding/:id/result?hostname=<h>', { state: { sagaResult, formValues } })`. It passes:
- `sagaResult` — the full parsed response body from the last poll (state, and for completed: all result fields; for failed: error field)
- `formValues` — forwarded unchanged from the location state it received

### 5.2 "Try Again" backward state (result → form)

When the user clicks "Try Again" on `OnboardingResultPage`, the page navigates to `/admin/onboarding/new` with `{ state: { prefill: formValues } }`. `RegisterTenantPage` reads `prefill` from location state on mount and pre-populates all form fields with those values. A fresh `Idempotency-Key` is generated for the new submission — it is never reused from the previous attempt.

### 5.3 Page-reload restore (result screen only)

If `OnboardingResultPage` mounts without location state (router state is absent after reload), the page reads the `hostname` query parameter from the current URL (`/admin/onboarding/:id/result?hostname=<h>`) and calls `GET /api/v1/onboarding?hostname=<h>` to fetch the completed record. Pre-fill of the form is not possible after a page reload of the result screen (the form values were in-memory only), so "Try Again" from a reloaded result screen opens a blank form.

---

## 6. Role Guard

The role guard is applied at three levels:

### 6.1 Sidebar entry point (ONB-UI-01)

The existing `AppShell.tsx` renders the sidebar by filtering `NAV_ITEMS` through `session?.roles.includes(r)`. A new entry is appended to `NAV_ITEMS` with the path `/admin/onboarding/new`, the label "Register Tenant", and restricted to the `PLATFORM_ADMIN` role. Because `NAV_ITEMS` are filtered before rendering, the "Register Tenant" entry is absent from the DOM (not disabled, not hidden via CSS) for any user without `PLATFORM_ADMIN`. This satisfies the ONB-UI-01 requirement that the entry point be hidden from the DOM, not merely disabled.

### 6.2 Per-page role check (ONB-UI-02, ONB-UI-03, ONB-UI-04)

Each of the three pages (`RegisterTenantPage`, `OnboardingProgressPage`, `OnboardingResultPage`) reads `session` from `useAuth()` on render. If `session?.roles.includes('PLATFORM_ADMIN')` is false, the page renders `<Navigate to="/instances" replace />` immediately, before rendering any onboarding content. This follows the same pattern used by `HealthDashboardPage`.

This means a user without `PLATFORM_ADMIN` who navigates directly to any onboarding URL is redirected without seeing any onboarding data.

### 6.3 What is NOT used

There is no separate `RoleProtectedRoute` wrapper component for these routes. The per-page check is consistent with the existing admin page pattern (`HealthDashboardPage`, `AuditLogPage`). All three pages use the identical early-return redirect pattern.

---

## 7. Polling Lifecycle (ONB-UI-03)

The `OnboardingProgressPage` manages polling with a `useEffect` that creates a `setInterval`. No TanStack Query `refetchInterval` is used for polling because the terminal-state transition requires stopping the interval and navigating — the component needs direct control over the timer.

### 7.1 Start

Polling begins immediately when the component mounts (the saga is already running before the user reaches this screen). The interval is read from `VITE_POLL_INTERVAL_MS` (default 10 000 ms), reusing the same environment variable used by instance/task polling elsewhere.

### 7.2 Tick behaviour

On each tick:
- If the tab is hidden (Page Visibility API: `document.hidden === true`), the tick is skipped and the transient error counter is not incremented. This follows the pattern in the existing `usePolling` hook.
- The tick calls `GET /api/v1/onboarding/:onboardingId`.
- On a successful response:
  - If `state` is `pending`: reset the transient error counter to 0. Stay on the progress screen.
  - If `state` is `completed`: clear the interval, navigate to the result screen.
  - If `state` is `failed`: clear the interval, navigate to the result screen.
- On a 5xx or network error:
  - Increment the transient error counter.
  - If the counter is below 3: stay on the progress screen silently (no error shown to user).
  - If the counter reaches 3: clear the interval and show an error message inline on the progress screen. The message indicates that the status check failed and offers a manual "Retry" button that restarts polling.

### 7.3 Cleanup on unmount

The `useEffect` cleanup function calls `clearInterval` unconditionally. This ensures polling stops if the user navigates away (e.g. via the sidebar or browser back button) before the saga completes.

### 7.4 Manual retry after 3 consecutive errors

When 3 consecutive transient errors occur, the page shows an error banner with a "Retry" button. Clicking "Retry" resets the transient error counter to 0 and starts a new interval from the current time. The interval handle is stored in a `useRef` so it can be replaced without triggering re-renders.

---

## 8. Page-Reload Restore (ONB-UI-04)

The result screen URL includes the `hostname` as a query parameter:

```
/admin/onboarding/<onboardingId>/result?hostname=<hostname>
```

The `hostname` is appended when `OnboardingProgressPage` navigates to the result screen. On mount of `OnboardingResultPage`:

1. The page checks `location.state` (React Router). If `sagaResult` is present in state, it renders immediately from state (no API call needed).
2. If `location.state` is absent (page was reloaded), the page reads the `hostname` from `new URLSearchParams(location.search).get('hostname')`.
3. If `hostname` is present, the page shows a loading indicator and calls `GET /api/v1/onboarding?hostname=<hostname>`.
4. On 200: render the result using the saga data from the response body.
5. On 404 (completed record not found — the saga may have failed or the hostname is wrong): render a "Could not restore onboarding state" message with a "Start over" link to `/admin/onboarding/new`.
6. If `hostname` is also absent (URL was corrupted), render the same "Could not restore" message.

Note: The hostname-based lookup only returns `completed` records (the backend query filters `WHERE state = 'completed'`). If the saga failed, the user will see the "Could not restore" fallback after a page reload. A "Try Again" with pre-fill is not available after a page reload of a failed result; the user starts from a blank form.

---

## 9. Error Taxonomy

### 9.1 Client-side validation errors (blocking submission)

Each error appears inline under the field that failed. The form is not submitted. No network call is made.

| Field | Rule | Error message |
|---|---|---|
| `slug` | Required | "Slug is required" |
| `slug` | 3–63 characters | "Slug must be 3–63 characters" |
| `slug` | Lowercase alphanumeric and hyphens only | "Slug may only contain lowercase letters, digits, and hyphens" |
| `display_name` | Required | "Display name is required" |
| `admin_email` | Required | "Admin email is required" |
| `admin_email` | Contains `@` and a domain part | "Enter a valid email address" |
| `admin_username` | Required | "Admin username is required" |
| `admin_display_name` | Required | "Admin display name is required" |
| `hostname` | Required | "Hostname is required" |
| `hostname` | No protocol prefix (`http://`, `https://`), no path component | "Enter a hostname only (no protocol or path)" |
| `redirect_uris` | At least one non-empty URI | "At least one redirect URI is required" |

### 9.2 API error on submit (from POST /api/v1/onboarding)

These appear as an inline error banner at the top of the form or as field-level messages where the field is identifiable.

| HTTP status | Body / condition | UI treatment |
|---|---|---|
| 409 | `error: "onboarding_in_progress"` | Banner: "An onboarding for this tenant is already in progress." with a link to the progress screen if `onboarding_id` is available. |
| 409 | RFC 9457 type `idempotency-conflict` | Banner: "A conflicting submission was detected. Please start over." with a link to `/admin/onboarding/new`. |
| 409 | Other (e.g. `DuplicateTenantSlug`, `DuplicateHostname`, `RealmAlreadyExists`) | Banner showing the `title` or `detail` from the Problem Details body, e.g. "A tenant with this slug already exists." |
| 422 | `error: "validation_failed"` | Banner: "The server rejected the submission due to a validation error. Please check all fields." |
| 422 | `error: "idempotency_key_required"` | This should not occur in normal flow (the page always generates a key); banner: "Internal error: idempotency key missing. Please reload and try again." |
| 502 | `RealmProvisioningFailed`, `UserProvisioningFailed`, `RoleAssignmentFailed`, `ClientProvisioningFailed`, or `VerificationFailed` | Banner: "Tenant provisioning failed at the identity provider. Check Keycloak connectivity and try again." |
| 503 | `error: "service_unavailable"` | Banner: "The onboarding service is temporarily unavailable. Please try again in a moment." |
| 5xx (other) | Any | Generic banner: "An unexpected error occurred. Please try again." |

### 9.3 Transient poll error (from GET /api/v1/onboarding/:id during progress polling)

- 1 or 2 consecutive errors: no message shown; polling continues silently.
- 3rd consecutive error: inline error message on the progress screen: "Unable to check onboarding status. The service may be temporarily unavailable." plus a "Retry" button to restart polling.

### 9.4 Saga failed (state = "failed")

The result screen shows the failure reason from the response body's `error` field. The message is displayed verbatim from the API. If the `error` field is absent or empty, a generic message is shown: "Onboarding failed. No additional detail is available."

A "Try Again" button is shown. Clicking it navigates to `/admin/onboarding/new` with form values pre-filled from the previous attempt (from router state). If form values are not available (page was reloaded), the button navigates to a blank form.

### 9.5 Role mismatch on direct URL navigation

Any user without `PLATFORM_ADMIN` who navigates directly to any of the three onboarding URLs receives an immediate redirect to `/instances` with `replace: true` (so the browser back button does not return to the onboarding URL). No onboarding content is rendered. No error message is shown; the redirect is silent.

An unauthenticated user (no session at all) is handled upstream by `ProtectedRoute`, which triggers `oidcManager.signinRedirect()` before any page component renders. The role check inside the page never fires for unauthenticated users.

---

## 10. Public Interface — Screen Behaviour Specifications

### RegisterTenantPage

**Inputs:**
- Router location state (optional): `{ prefill: FormValues }` — if present, pre-populates all form fields on mount
- No URL parameters

**Behaviour:**
- On mount: if `session.roles` does not include `PLATFORM_ADMIN`, redirect to `/instances`; otherwise render the form, applying `prefill` to initial field values if present, and generate a fresh `Idempotency-Key` UUID for this submission session
- On field change: run field-level client-side validation; display inline error under the field if invalid
- On submit click: run full form validation; if any field fails, show all errors and do not submit; if all fields pass, POST to `/api/v1/onboarding` with the `Idempotency-Key` header, disable the submit button for the duration of the request
- On 201 response: navigate to `/admin/onboarding/:onboardingId/progress` with form values in router state
- On error response: re-enable the submit button; show error banner or field error as per the error taxonomy

**Outputs:**
- Navigates to `OnboardingProgressPage` on success
- Renders field-level or banner-level errors on failure

---

### OnboardingProgressPage

**Inputs:**
- URL parameter: `onboardingId`
- Router location state: `{ formValues: FormValues, hostname: string }`

**Behaviour:**
- On mount: if `session.roles` does not include `PLATFORM_ADMIN`, redirect to `/instances`; otherwise start polling interval at `VITE_POLL_INTERVAL_MS`; show progress indicator
- On each poll tick: fetch `GET /api/v1/onboarding/:onboardingId`; process response as per polling lifecycle (section 7)
- On `state = "completed"`: stop polling; navigate to `/admin/onboarding/:onboardingId/result?hostname=<hostname>` with `{ sagaResult, formValues }` in router state
- On `state = "failed"`: stop polling; navigate to `/admin/onboarding/:onboardingId/result?hostname=<hostname>` with `{ sagaResult, formValues }` in router state
- On 3rd consecutive transient error: stop polling; show error banner with "Retry" button
- On unmount: clear interval unconditionally

**Outputs:**
- Navigates to `OnboardingResultPage` on terminal saga state
- Renders progress indicator while pending
- Renders error banner + "Retry" button after 3 consecutive transient errors

---

### OnboardingResultPage

**Inputs:**
- URL parameter: `onboardingId`
- URL search parameter: `hostname` (required for page-reload restore)
- Router location state (optional): `{ sagaResult: SagaResult, formValues: FormValues }`

**Behaviour:**
- On mount: if `session.roles` does not include `PLATFORM_ADMIN`, redirect to `/instances`
- If router location state contains `sagaResult`: render from state immediately (no API call)
- If router location state is absent: read `hostname` from URL search params; call `GET /api/v1/onboarding?hostname=<hostname>` to restore state; show loading indicator during fetch; on 404 or missing hostname, show "Could not restore" message with "Start over" link
- For a completed result: display `slug` and `oidc_authority`; provide "Back to Admin" button navigating to `/admin/users`
- For a failed result: display failure reason from `error` field; provide "Try Again" button navigating to `/admin/onboarding/new` with `{ prefill: formValues }` in router state (if form values are unavailable from state, navigate to blank form)

**Outputs:**
- Renders completed onboarding details (`slug`, `oidc_authority`) on success
- Renders failure reason and "Try Again" button on failure
- Renders "Could not restore" fallback if page was reloaded and restore lookup fails

---

## 11. New API Module

A new file `web/src/api/onboarding.ts` must be created to encapsulate all three endpoint calls. It follows the same pattern as `web/src/api/instances.ts` and `web/src/api/health.ts` — all calls go through `client` from `web/src/api/client.ts`.

The module exposes:

- A function to submit a new onboarding: takes the form values and an idempotency key string; calls `POST /api/v1/onboarding`; returns the created record body
- A function to poll onboarding status by ID: takes `onboardingId`; calls `GET /api/v1/onboarding/:onboardingId`; returns the response body
- A function to restore onboarding status by hostname: takes `hostname`; calls `GET /api/v1/onboarding?hostname=<hostname>`; returns the response body

The idempotency key header (`Idempotency-Key`) must be injected per-call by the submit function, not by `client.ts` globally (it is not needed on any other endpoint).

---

## 12. Query Keys

Query keys for the onboarding screens are added to the existing `queryKeys` factory in `web/src/api/queryKeys.ts`. Key structure:

- Status by ID: `['onboarding', 'status', onboardingId]`
- Status by hostname: `['onboarding', 'hostname', hostname]`

Note: the polling loop in `OnboardingProgressPage` uses a manual `setInterval` (not TanStack Query `refetchInterval`) because it needs to clear the timer and navigate on terminal state. However, the hostname-based restore in `OnboardingResultPage` uses a standard `useQuery` call because it is a one-time fetch on mount.

---

## 13. Dependency on Existing Code

- `web/src/auth/AuthContext.tsx` — `useAuth()` for session and role check
- `web/src/api/client.ts` — all HTTP calls
- `web/src/api/queryKeys.ts` — query key factory (to be extended)
- `web/src/components/layout/AppShell.tsx` — `NAV_ITEMS` array (to be extended with "Register Tenant" entry)
- `web/src/router.tsx` — route definitions (to be extended with three new paths)

No modifications are required to `ProtectedRoute.tsx`. The per-page role check is the authoritative guard for these screens, consistent with all other admin pages.

---

## 14. Non-Goals (Out of Scope for This Design)

- Listing previously created tenants (separate requirement, not in ONB-UI-01..04)
- Editing or deleting tenant records via this flow
- Admin email verification or any post-onboarding workflow steps
- Displaying the full `OnboardingRecord` schema fields beyond what the requirements specify (`slug`, `oidc_authority` on success; `error` on failure)
