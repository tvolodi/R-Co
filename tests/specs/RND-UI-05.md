# Test Spec: RND-UI-05 — Rate-limit backpressure with retry countdown

**Requirement:** RND-UI-05 — When a `GET` query returns HTTP 429 with a `Retry-After` response header, the page surface must mount a one-per-second countdown that announces the remaining seconds through an `aria-live="polite"` region and fires a single refetch when the countdown reaches zero.
**Priority:** MUST
**Test layer:** unit (Vitest), e2e (Playwright, no mocks — real backend with API-10 rate-limit middleware)

**Design reference:** `src/design/pw13-pw16-batch19-20260813.md` §1.1, §1.2, §1.3, §1.4, §5.1, §12.1.

## Test Cases

### TC-RND-UI-05-01: countdown text decreases by one each second
**Given:** `<RateLimitBackpressure retryAfter={5} />` is mounted with fake timers
**When:** the test advances time by 1s, then by 2s
**Then:** the `data-testid="retry-countdown"` element reads `"Retry in 5s"` → `"Retry in 4s"` → `"Retry in 2s"`
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-05 AC-2
**Implemented by:** `web/tests/unit/RateLimitBackpressure.test.tsx` (`TC-RLB-01`)

### TC-RND-UI-05-02: aria-live="polite" wrapper renders role="status" + aria-atomic="true"
**Given:** the component is mounted with any positive retryAfter
**When:** the wrapper element is inspected
**Then:** it has `role="status"`, `aria-live="polite"`, `aria-atomic="true"` and `data-testid="rate-limit-backpressure"`
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-05 AC-1
**Implemented by:** `web/tests/unit/RateLimitBackpressure.test.tsx` (`TC-RLB-02`)

### TC-RND-UI-05-03: onRetry fires exactly once when countdown reaches zero
**Given:** `<RateLimitBackpressure retryAfter={3} onRetry={onRetry} />` with `onRetry` mocked, fake timers
**When:** the test advances time by 3 s
**Then:** `onRetry` is called exactly once and the interval is cleared
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-05 AC-3
**Implemented by:** `web/tests/unit/RateLimitBackpressure.test.tsx` (`TC-RLB-03`), `web/tests/unit/RateLimitBackpressure.12.test.tsx` (`TC-RLB-09`)

### TC-RND-UI-05-04: component unmount during countdown NEVER fires onRetry
**Given:** `<RateLimitBackpressure retryAfter={5} />` is mounted with fake timers
**When:** the test advances 2 s and then unmounts the component
**Then:** the `setInterval` is cleared; advancing another 5 s does NOT call `onRetry`
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-05 AC-3 + §12.1 mode 3, mode 4
**Implemented by:** `web/tests/unit/RateLimitBackpressure.test.tsx` (`TC-RLB-04`), `web/tests/unit/RateLimitBackpressure.12.test.tsx` (`TC-RLB-07`, `TC-RLB-08`)

### TC-RND-UI-05-05: clicking "Retry now" does NOT double-fire alongside the countdown
**Given:** `<RateLimitBackpressure retryAfter={3} onRetry={onRetry} />`
**When:** the user clicks `[data-testid="rate-limit-retry-now"]` and the countdown subsequently reaches zero
**Then:** `onRetry` is called exactly once (the firedRef prevents the timer from also firing it)
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-05 AC-3 + §12.1 mode 5
**Implemented by:** `web/tests/unit/RateLimitBackpressure.test.tsx` (`TC-RLB-05`)

### TC-RND-UI-05-06: non-finite Retry-After (HTTP-date, malformed) falls back to 60 s default
**Given:** `retryAfter={Number('Wed, 21 Oct 2026 07:28:00 GMT')}` (NaN)
**When:** the component mounts
**Then:** the countdown starts at 60 s and `console.warn` is called with the fallback message
**Layer:** unit
**Acceptance criterion mapped:** §12.1 mode 6
**Implemented by:** `web/tests/unit/RateLimitBackpressure.test.tsx` (`TC-RLB-06`)

### TC-RND-UI-05-07: surfaceLabel renders into the announcement copy
**Given:** `surfaceLabel="Task Inbox"` is passed
**When:** the component is rendered
**Then:** the announcement text contains `"Task Inbox"`
**Layer:** unit
**Acceptance criterion mapped:** RND-UI-05 AC-1
**Implemented by:** `web/tests/unit/RateLimitBackpressure.test.tsx` (`TC-RLB-07`)

### TC-RND-UI-05-08: real backend 429 surfaces the RateLimitBackpressure component on the Task Inbox
**Given:** the BPM API is up with the rate-limit middleware (API-10) and the seeded `worker-user` has a Token; the test bursts 60 concurrent GETs to `/api/v1/tasks/inbox`
**When:** at least one response is HTTP 429 with `Retry-After` header
**Then:** navigating to `/tasks/inbox` shows `[data-testid="rate-limit-backpressure"]` with `role="status"` and `aria-live="polite"`
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-05 AC-1, AC-5
**Implemented by:** `web/tests/e2e/rnd-ui-05.rate-limit-backpressure.e2e.spec.ts` (`TC-RND-UI-05-E2E-01`)

### TC-RND-UI-05-09: after the countdown fires, exactly one additional GET is observed
**Given:** the RateLimitBackpressure countdown reaches zero with the seeded tenant's rate-limit bucket drained
**When:** the countdown completes
**Then:** a single refetch is observed (`page.on('request', …)` counter for `**/api/v1/tasks/inbox` increases by exactly one)
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-05 AC-3
**Implemented by:** `web/tests/e2e/rnd-ui-05.rate-limit-backpressure.e2e.spec.ts` (`TC-RND-UI-05-E2E-03`)

### TC-RND-UI-05-10: 429 without Retry-After is classified as fetch-failure (no RateLimitBackpressure)
**Given:** the BPM API fixture is configured to strip `Retry-After` from the 429 response
**When:** the rate-limit triggers a 429 with no `Retry-After`
**Then:** `<FetchError>` is rendered; `[data-testid="rate-limit-backpressure"]` is NOT in the DOM
**Layer:** e2e
**Acceptance criterion mapped:** RND-UI-05 AC-5 + §12.1 mode 2
**Implemented by:** `web/tests/e2e/rnd-ui-05.rate-limit-backpressure.e2e.spec.ts` (`TC-RND-UI-05-E2E-05`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| RND-UI-05 AC-1: 429 region shows header value in seconds; aria-live polite | `TC-RND-UI-05-02`, `TC-RND-UI-05-08` |
| RND-UI-05 AC-2: live region announces value decreasing by one per second | `TC-RND-UI-05-01` |
| RND-UI-05 AC-3: exactly one refetch after countdown reaches zero | `TC-RND-UI-05-03`, `TC-RND-UI-05-04`, `TC-RND-UI-05-05`, `TC-RND-UI-05-09` |
| RND-UI-05 AC-4: second 429 starts a new countdown (parent unmount/remount) | `TC-RND-UI-05-08` (second burst), `TC-RND-UI-05-04` (cleanup invariant) |
| RND-UI-05 AC-5: 429 without Retry-After → fetch-failure | `TC-RND-UI-05-10` |
| §12.1 mode 1: classifyError fall-through → fetch-failure | covered by existing `web/tests/unit/classifyError.test.ts` (`TC-CE-04`) |
| §12.1 mode 2: 429 with no Retry-After | `TC-RND-UI-05-10` |
| §12.1 mode 3 + mode 4: unmount before zero → no fire | `TC-RND-UI-05-04`, `web/tests/unit/RateLimitBackpressure.12.test.tsx` (`TC-RLB-07`, `TC-RLB-08`) |
| §12.1 mode 5: multi-zero-tick guard | `TC-RND-UI-05-05`, `TC-RND-UI-05-09`, `web/tests/unit/RateLimitBackpressure.12.test.tsx` (`TC-RLB-09`) |
| §12.1 mode 6: non-integer Retry-After fallback to 60 s | `TC-RND-UI-05-06` |

## Acceptance Test Coverage Matrix

| AC | E2E | Unit | Status |
|---|---|---|---|
| AC-1 | `TC-RND-UI-05-08` | `TC-RND-UI-05-02`, `TC-RND-UI-05-07` | COVERED |
| AC-2 | (via AC-1 E2E) | `TC-RND-UI-05-01` | COVERED |
| AC-3 | `TC-RND-UI-05-09` | `TC-RND-UI-05-03`, `TC-RND-UI-05-04`, `TC-RND-UI-05-05` | COVERED |
| AC-4 | `TC-RND-UI-05-08` (repeat) | `TC-RND-UI-05-04` | COVERED |
| AC-5 | `TC-RND-UI-05-10` | (via classifyError) | COVERED |
| §12.1 mode 1 | (covered by RND-UI-03 classifyError tests) | (covered) | COVERED |
| §12.1 mode 2 | `TC-RND-UI-05-10` | (covered) | COVERED |
| §12.1 mode 3 | (covered) | `TC-RLB-07` | COVERED |
| §12.1 mode 4 | (covered) | `TC-RLB-08` | COVERED |
| §12.1 mode 5 | `TC-RND-UI-05-09` | `TC-RLB-09` | COVERED |
| §12.1 mode 6 | (covered) | `TC-RND-UI-05-06` | COVERED |

## Execution Notes For TEST-RUNNER

- E2E uses real Keycloak + BPM API + PostgreSQL per design §0 (no `page.route()` interception of API or auth).
- Per-test isolation: the rate-limit bucket state is observed but not mutated; the test burst is bounded to 60 requests which fits inside the seeded tenant's `api/v1/tasks/inbox` 429 quota.
- `lint_handoffs.py` and `lint_test_isolation.py` (the Zig-targeted variant) are not applicable to the TypeScript output here. The Vitest suite is the verification target.
