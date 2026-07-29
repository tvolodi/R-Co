> **Extends:** API-10, surfacing platform rate limiting as a bounded client-side wait rather than a bare error.

> The `rate-limit` state SHALL render `web/src/components/ui/RateLimitBackpressure.tsx` with the `retryAfter` value taken from the `Retry-After` response header. The component SHALL count down at one-second intervals inside an `aria-live="polite"` region and SHALL fire `refetch()` exactly once when the countdown reaches zero. It SHALL NOT retry a second time without a user action. A 429 without `Retry-After` SHALL classify as `fetch-failure`.

**Acceptance Criteria:**
- GIVEN a Playwright E2E issues requests to `GET /api/v1/instances` past the tenant's real rate limit, WHEN the real 429 with `Retry-After` arrives, THEN `RateLimitBackpressure` renders showing the header value in seconds; no HTTP mocking is used.
- GIVEN the countdown is running, WHEN the live region is read in that E2E at one-second intervals, THEN the announced value decreases by one each second and the region carries `aria-live="polite"`.
- GIVEN the countdown reaches zero, WHEN the network log for that page is inspected, THEN exactly one refetch request was issued.
- GIVEN the refetch also returns 429, WHEN the second response is classified, THEN a new countdown starts from the new `Retry-After` value and no request is issued before it reaches zero.
- GIVEN the rate limiter returns 429 with the `Retry-After` header stripped, WHEN `classifyError()` runs, THEN the state is `fetch-failure` and `FetchError` renders with its user-driven Retry action.

**See:** RND-UI-01, RND-UI-03, API-10, IN-UI-05
