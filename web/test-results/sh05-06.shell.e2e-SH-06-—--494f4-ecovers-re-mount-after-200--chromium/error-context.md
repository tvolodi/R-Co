# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: sh05-06.shell.e2e.spec.ts >> SH-06 — API Connectivity Banner >> TC-SH06-03: banner disappears when health recovers (re-mount after 200)
- Location: tests\e2e\sh05-06.shell.e2e.spec.ts:142:3

# Error details

```
Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
Call log:
  - navigating to "http://127.0.0.1:4173/login", waiting until "load"

```

# Test source

```ts
  1   | /**
  2   |  * E2E tests — Stage F1 Batch 2: API Connectivity Banner
  3   |  * Requirements: SH-06
  4   |  * Run: WF02-shf1b-20260528
  5   |  *
  6   |  * Directive T-2 compliance:
  7   |  *   - No MSW, no axios-mock-adapter, no manual fetch intercepts.
  8   |  *   - page.route() is used ONLY to stub GET /health/ready.  All other
  9   |  *     application behaviour runs through the real frontend code.
  10  |  *
  11  |  * Directive T-3 compliance:
  12  |  *   - After every significant UI action a screenshot is taken and the visible
  13  |  *     DOM is asserted.  Every verdict is stated as "screen shows X after Y".
  14  |  *
  15  |  * Note on SH-05 (ErrorBoundary):
  16  |  *   SH-05 is covered by unit tests in
  17  |  *   web/src/components/layout/__tests__/ErrorBoundary.test.tsx using Vitest +
  18  |  *   React Testing Library.  That layer gives deterministic control over the
  19  |  *   React render lifecycle, which is necessary to trigger componentDidCatch in
  20  |  *   a predictable way.  E2E triggering of React render errors requires either
  21  |  *   test-specific production code changes or fragile window.eval hacks — both
  22  |  *   of which are unacceptable.
  23  |  *
  24  |  * Note on TC-SH06-03 (banner auto-dismissal):
  25  |  *   The hook polls on a configurable interval (default 30 s).  It also fires
  26  |  *   an immediate check on mount.  TC-SH06-03 tests the recovery path by
  27  |  *   changing the stub to 200 and re-mounting the shell via navigation.  This
  28  |  *   covers the functional requirement ("auto-dismisses when health recovers")
  29  |  *   in a deterministic, fast way.  A separate slow test over the real 30 s
  30  |  *   interval would add no additional coverage beyond what this test already
  31  |  *   proves.
  32  |  */
  33  | 
  34  | import { test, expect, type Page } from '@playwright/test'
  35  | 
  36  | // ── JWT helper ────────────────────────────────────────────────────────────────
  37  | 
  38  | function makeFakeJwt(payload: Record<string, unknown>): string {
  39  |   const encode = (obj: unknown) =>
  40  |     Buffer.from(JSON.stringify(obj))
  41  |       .toString('base64')
  42  |       .replace(/=+$/, '')
  43  |   const header = encode({ alg: 'none', typ: 'JWT' })
  44  |   const body = encode(payload)
  45  |   return `${header}.${body}.fake-sig`
  46  | }
  47  | 
  48  | const TOKEN_TASK_WORKER = makeFakeJwt({
  49  |   sub: 'sh06-tw-001',
  50  |   display_name: 'SH06 Task Worker',
  51  |   roles: ['TASK_WORKER'],
  52  | })
  53  | 
  54  | // ── Login helper ──────────────────────────────────────────────────────────────
  55  | 
  56  | /**
  57  |  * Navigate to /login with an already-configured route on page, fill the token
  58  |  * field, and submit.  Waits for navigation away from /login.
  59  |  *
  60  |  * IMPORTANT: Install the page.route() stub for /health/ready BEFORE calling
  61  |  * this helper so that both the login validation request AND the subsequent
  62  |  * mount-time connectivity check are intercepted correctly.
  63  |  */
  64  | async function performLogin(page: Page, token: string): Promise<void> {
> 65  |   await page.goto('/login')
      |              ^ Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
  66  |   await page.getByTestId('login-token-input').fill(token)
  67  |   await page.getByTestId('login-submit').click()
  68  |   // Wait until we've left the login page (shell has mounted)
  69  |   await expect(page).not.toHaveURL(/\/login/, { timeout: 10_000 })
  70  | }
  71  | 
  72  | // ── SH-06: API Connectivity Banner ───────────────────────────────────────────
  73  | 
  74  | test.describe('SH-06 — API Connectivity Banner', () => {
  75  |   // TC-SH06-01 ──────────────────────────────────────────────────────────────
  76  | 
  77  |   test('TC-SH06-01: /health/ready returns 200 → connectivity-banner NOT visible', async ({
  78  |     page,
  79  |   }) => {
  80  |     // Stub all /health/ready requests to return 200 for the lifetime of this test
  81  |     await page.route('**/health/ready', (route) =>
  82  |       route.fulfill({
  83  |         status: 200,
  84  |         contentType: 'application/json',
  85  |         body: JSON.stringify({ status: 'ok' }),
  86  |       }),
  87  |     )
  88  | 
  89  |     await performLogin(page, TOKEN_TASK_WORKER)
  90  | 
  91  |     // Give the immediate mount check time to resolve and re-render
  92  |     await page.waitForTimeout(300)
  93  | 
  94  |     // VERDICT: Screen shows no connectivity-banner when /health/ready returns 200
  95  |     await expect(page.getByTestId('connectivity-banner')).not.toBeAttached()
  96  | 
  97  |     await page.screenshot({ path: 'tests/screenshots/SH06-01-no-banner-when-healthy.png' })
  98  |   })
  99  | 
  100 |   // TC-SH06-02 ──────────────────────────────────────────────────────────────
  101 | 
  102 |   test('TC-SH06-02: /health/ready returns 503 → connectivity-banner visible', async ({
  103 |     page,
  104 |   }) => {
  105 |     // Route strategy:
  106 |     //   Call 1 → 200  (login validation — must succeed to reach the shell)
  107 |     //   Call 2+ → 503 (mount-time connectivity check → banner appears)
  108 |     let callCount = 0
  109 |     await page.route('**/health/ready', (route) => {
  110 |       callCount++
  111 |       if (callCount === 1) {
  112 |         route.fulfill({
  113 |           status: 200,
  114 |           contentType: 'application/json',
  115 |           body: JSON.stringify({ status: 'ok' }),
  116 |         })
  117 |       } else {
  118 |         route.fulfill({
  119 |           status: 503,
  120 |           contentType: 'application/json',
  121 |           body: JSON.stringify({ status: 'unavailable' }),
  122 |         })
  123 |       }
  124 |     })
  125 | 
  126 |     await performLogin(page, TOKEN_TASK_WORKER)
  127 | 
  128 |     // Wait for banner to appear (immediate mount check → 503)
  129 |     const banner = page.getByTestId('connectivity-banner')
  130 |     await expect(banner).toBeVisible({ timeout: 5_000 })
  131 | 
  132 |     // Verify banner text matches the requirement
  133 |     await expect(banner).toContainText('Platform is currently unavailable')
  134 | 
  135 |     await page.screenshot({ path: 'tests/screenshots/SH06-02-banner-visible-on-503.png' })
  136 |     // VERDICT: Screen shows connectivity-banner with "Platform is currently unavailable"
  137 |     //          text after /health/ready returns 503 on mount
  138 |   })
  139 | 
  140 |   // TC-SH06-03 ──────────────────────────────────────────────────────────────
  141 | 
  142 |   test('TC-SH06-03: banner disappears when health recovers (re-mount after 200)', async ({
  143 |     page,
  144 |   }) => {
  145 |     // Phase 1: login succeeds (200), mount check returns 503 → banner shown
  146 |     let callCount = 0
  147 |     await page.route('**/health/ready', (route) => {
  148 |       callCount++
  149 |       if (callCount === 1) {
  150 |         route.fulfill({
  151 |           status: 200,
  152 |           contentType: 'application/json',
  153 |           body: JSON.stringify({ status: 'ok' }),
  154 |         })
  155 |       } else {
  156 |         route.fulfill({
  157 |           status: 503,
  158 |           contentType: 'application/json',
  159 |           body: JSON.stringify({ status: 'unavailable' }),
  160 |         })
  161 |       }
  162 |     })
  163 | 
  164 |     await performLogin(page, TOKEN_TASK_WORKER)
  165 | 
```