# Test Spec: OIDC-F-06 — Frontend resolveRealmFromUrl priority chain

**Requirement:** OIDC-F-06 — The frontend reads a realm slug from URL `?realm=` parameter or
sessionStorage `bpm_realm_slug` key before falling back to hostname-based lookup. When found in
URL, the slug is written to sessionStorage for subsequent page reloads.
**Priority:** MUST
**Test layer:** unit (frontend)

## Test Cases

### TC-OIDC-F06-01: resolveRealmFromUrl returns slug from ?realm= URL param and persists to sessionStorage
**Given:** `sessionStorage` is empty; `window.location.search = '?realm=swiftroute'`
**When:** `resolveRealmFromUrl()` is called
**Then:** Returns `'swiftroute'`; `sessionStorage.getItem('bpm_realm_slug')` equals `'swiftroute'`
**Layer:** unit (Vitest, jsdom environment)
**Acceptance criterion mapped:** URL param takes priority when sessionStorage is absent; side-effect writes sessionStorage

### TC-OIDC-F06-02: resolveRealmFromUrl returns slug from sessionStorage when key is already set
**Given:** `sessionStorage.setItem('bpm_realm_slug', 'meridian')`; `window.location.search = ''`
**When:** `resolveRealmFromUrl()` is called
**Then:** Returns `'meridian'` (from sessionStorage, does not attempt URL parsing)
**Layer:** unit (Vitest, jsdom environment)
**Acceptance criterion mapped:** sessionStorage key takes priority over URL param on subsequent page loads
