# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: obs04.timeline.e2e.spec.ts >> OBS-04 timeline browser flow >> opens an instance and renders the timeline tab state
- Location: tests\e2e\obs04.timeline.e2e.spec.ts:157:3

# Error details

```
Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
Call log:
  - navigating to "http://127.0.0.1:4173/login", waiting until "load"

```

# Test source

```ts
  58  |     const url = new URL(request.url())
  59  |     const path = url.pathname
  60  | 
  61  |     if (path === '/api/v1/auth/login' && method === 'POST') {
  62  |       const body = request.postDataJSON() as { email?: string; password?: string }
  63  |       if (body.email === E2E_EMAIL && body.password === E2E_PASSWORD) {
  64  |         await route.fulfill({
  65  |           status: 200,
  66  |           contentType: 'application/json',
  67  |           body: JSON.stringify({
  68  |             access_token: ACCESS_TOKEN,
  69  |             refresh_token: REFRESH_TOKEN,
  70  |             user: mockUser,
  71  |           }),
  72  |         })
  73  |         return
  74  |       }
  75  | 
  76  |       await route.fulfill({
  77  |         status: 401,
  78  |         contentType: 'application/json',
  79  |         body: JSON.stringify({
  80  |           title: 'Unauthorized',
  81  |           status: 401,
  82  |         }),
  83  |       })
  84  |       return
  85  |     }
  86  | 
  87  |     if (path === '/api/v1/auth/me' && method === 'GET') {
  88  |       await route.fulfill({
  89  |         status: 200,
  90  |         contentType: 'application/json',
  91  |         body: JSON.stringify(mockUser),
  92  |       })
  93  |       return
  94  |     }
  95  | 
  96  |     if (path === '/api/v1/auth/logout' && method === 'POST') {
  97  |       await route.fulfill({
  98  |         status: 204,
  99  |         body: '',
  100 |       })
  101 |       return
  102 |     }
  103 | 
  104 |     if (path === '/api/v1/instances' && method === 'GET') {
  105 |       await route.fulfill({
  106 |         status: 200,
  107 |         contentType: 'application/json',
  108 |         body: JSON.stringify({
  109 |           items: [mockInstance],
  110 |           next_cursor: null,
  111 |           has_more: false,
  112 |         }),
  113 |       })
  114 |       return
  115 |     }
  116 | 
  117 |     if (path === `/api/v1/instances/${DEFAULT_INSTANCE_ID}` && method === 'GET') {
  118 |       await route.fulfill({
  119 |         status: 200,
  120 |         contentType: 'application/json',
  121 |         body: JSON.stringify(mockInstance),
  122 |       })
  123 |       return
  124 |     }
  125 | 
  126 |     if (path === `/api/v1/instances/${DEFAULT_INSTANCE_ID}/events` && method === 'GET') {
  127 |       await route.fulfill({
  128 |         status: 200,
  129 |         contentType: 'application/json',
  130 |         body: JSON.stringify([]),
  131 |       })
  132 |       return
  133 |     }
  134 | 
  135 |     if (path === `/api/v1/instances/${DEFAULT_INSTANCE_ID}/timeline` && method === 'GET') {
  136 |       await route.fulfill({
  137 |         status: 200,
  138 |         contentType: 'application/json',
  139 |         body: JSON.stringify(mockTimeline),
  140 |       })
  141 |       return
  142 |     }
  143 | 
  144 |     await route.fulfill({
  145 |       status: 404,
  146 |       contentType: 'application/json',
  147 |       body: JSON.stringify({
  148 |         title: 'Not Found',
  149 |         status: 404,
  150 |         path,
  151 |       }),
  152 |     })
  153 |   })
  154 | })
  155 | 
  156 | test.describe('OBS-04 timeline browser flow', () => {
  157 |   test('opens an instance and renders the timeline tab state', async ({ page }) => {
> 158 |     await page.goto('/login')
      |                ^ Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
  159 |     await expect(page.getByTestId('page-login')).toBeVisible()
  160 |     await page.screenshot({ path: 'test-results/obs04-01-login.png', fullPage: true })
  161 | 
  162 |     await page.getByTestId('email-input').fill(E2E_EMAIL)
  163 |     await page.getByTestId('password-input').fill(E2E_PASSWORD)
  164 |     await page.getByTestId('login-submit').click()
  165 | 
  166 |     const instancesHeading = page.getByRole('heading', { name: 'Instances' })
  167 |     await expect(instancesHeading).toBeVisible()
  168 |     await page.screenshot({ path: 'test-results/obs04-02-instances.png', fullPage: true })
  169 | 
  170 |     if (E2E_INSTANCE_ID) {
  171 |       await page.goto(`/instances/${E2E_INSTANCE_ID}`)
  172 |     } else {
  173 |       const firstInstanceLink = page.locator('tbody tr td a').first()
  174 |       await expect(firstInstanceLink).toBeVisible()
  175 |       await firstInstanceLink.click()
  176 |     }
  177 | 
  178 |     await expect(page.getByRole('heading', { name: 'Instance' })).toBeVisible()
  179 |     await page.getByRole('button', { name: 'Timeline' }).click()
  180 |     await expect(page.getByRole('heading', { name: 'Timeline' })).toBeVisible()
  181 | 
  182 |     const timelineEntry = page.locator('article').first()
  183 |     const emptyMessage = page.getByText('No timeline entries found.')
  184 | 
  185 |     await Promise.race([
  186 |       timelineEntry.waitFor({ state: 'visible', timeout: 20_000 }).catch(() => null),
  187 |       emptyMessage.waitFor({ state: 'visible', timeout: 20_000 }).catch(() => null),
  188 |     ])
  189 | 
  190 |     await expect(timelineEntry.or(emptyMessage)).toBeVisible()
  191 |     await page.screenshot({ path: 'test-results/obs04-03-timeline.png', fullPage: true })
  192 |   })
  193 | })
  194 | 
```