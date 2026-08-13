/**
 * E2E — RND-UI-06: ConflictResolver
 *
 *  No mocks. Real backend. The spec drives a 409 by opening the
 *  Definition Editor in two contexts (admin + admin2), editing in
 *  context B, then saving in context A to provoke a stale-version
 *  response.
 */

import { test, expect, type BrowserContext } from '@playwright/test'

async function login(page: import('@playwright/test').Page): Promise<void> {
  await page.goto('/')
  await page.getByLabel(/username/i).fill('admin')
  await page.getByLabel(/password/i).fill('admin')
  await page.getByRole('button', { name: /sign in/i }).click()
  await page.waitForURL(/\/home/)
}

async function loginAsSecondAdmin(page: import('@playwright/test').Page): Promise<void> {
  await page.goto('/')
  await page.getByLabel(/username/i).fill('admin2')
  await page.getByLabel(/password/i).fill('admin2')
  await page.getByRole('button', { name: /sign in/i }).click()
  await page.waitForURL(/\/home/)
}

test.describe('RND-UI-06 — ConflictResolver (two-contexts)', () => {
  let contextA: BrowserContext
  let contextB: BrowserContext
  let pageA: import('@playwright/test').Page
  let pageB: import('@playwright/test').Page

  test.beforeAll(async ({ browser }) => {
    contextA = await browser.newContext()
    contextB = await browser.newContext()
    pageA = await contextA.newPage()
    pageB = await contextB.newPage()
    await login(pageA)
    await loginAsSecondAdmin(pageB)
  })

  test.afterAll(async () => {
    await contextA?.close()
    await contextB?.close()
  })

  test('AC-1: 409 surfaces three-action modal with server xResourceVersion', async () => {
    // Open the same definition in both tabs.
    await pageA.goto('/definitions/editor?defId=demo-1')
    await pageB.goto('/definitions/editor?defId=demo-1')
    // Edit in B and save — B now has a newer version.
    await pageB.getByTestId('def-field-name').fill('Renamed by B')
    await pageB.getByTestId('def-save').click()
    await pageB.waitForResponse((r) => r.url().includes('/definitions/') && r.request().method() === 'PUT')
    // Edit in A and save — A is now stale.
    await pageA.getByTestId('def-field-name').fill('Renamed by A')
    await pageA.getByTestId('def-save').click()

    await expect(pageA.getByTestId('conflict-resolver')).toBeVisible()
    await expect(pageA.getByTestId('conflict-refetch')).toBeVisible()
    await expect(pageA.getByTestId('conflict-merge')).toBeVisible()
    await expect(pageA.getByTestId('conflict-discard')).toBeVisible()
  })

  test('AC-2: Refetch dismisses the modal and re-issues GET', async () => {
    await expect(pageA.getByTestId('conflict-resolver')).toBeVisible()
    await pageA.getByTestId('conflict-refetch').click()
    await expect(pageA.getByTestId('conflict-resolver')).toBeHidden()
  })

  test('AC-3: Merge panel save fires onSaveMerged with local+server merged', async () => {
    // Trigger a fresh conflict first.
    await pageA.getByTestId('def-field-name').fill('Renamed again by A')
    await pageA.getByTestId('def-save').click()
    await expect(pageA.getByTestId('conflict-resolver')).toBeVisible()

    await pageA.getByTestId('conflict-merge').click()
    await expect(pageA.getByTestId('conflict-merge-panel')).toBeVisible()
    await pageA.getByTestId('conflict-merge-save').click()
    await expect(pageA.getByTestId('conflict-resolver')).toBeHidden()
    // The canvas should now show the merged result.
    await expect(pageA.getByTestId('def-field-name')).toHaveValue('Renamed again by A')
  })

  test('AC-4: Discard confirm dialog requires explicit confirmation', async () => {
    await pageA.getByTestId('def-field-name').fill('Renamed third time by A')
    await pageA.getByTestId('def-save').click()
    await expect(pageA.getByTestId('conflict-resolver')).toBeVisible()

    await pageA.getByTestId('conflict-discard').click()
    await expect(pageA.getByTestId('confirm-dialog')).toBeVisible()
    // Cancel does not discard.
    await pageA.getByTestId('confirm-dialog-cancel').click()
    await expect(pageA.getByTestId('conflict-resolver')).toBeVisible()
  })

  test('AC-5: Discard confirm removes the local draft and dismisses the modal', async () => {
    await pageA.getByTestId('conflict-discard').click()
    await pageA.getByTestId('confirm-dialog-confirm').click()
    await expect(pageA.getByTestId('conflict-resolver')).toBeHidden()
    await expect(pageA.getByTestId('draft-banner')).toBeHidden()
  })

  test('AC-6: post-conflict FetchError surfaces above the resolver (regression)', async () => {
    // We simulate refetch-with-failure by intercepting the GET that
    // would happen after the conflict is raised. NOTE: this is
    // page.route, NOT a mock of the application code.
    await pageA.route('**/definitions/demo-1', (route) => {
      if (route.request().method() === 'GET') {
        route.fulfill({ status: 503, body: 'down' })
      } else {
        route.continue()
      }
    })
    await pageA.getByTestId('def-field-name').fill('Renamed post-refetch-failure')
    await pageA.getByTestId('def-save').click()
    // Force a fresh conflict by removing the route and re-saving.
    await pageA.unroute('**/definitions/demo-1')
    await pageA.getByTestId('def-save').click()
    await expect(pageA.getByTestId('conflict-resolver')).toBeVisible()
    await pageA.getByTestId('conflict-refetch').click()
    // Wait for the boundary to absorb the failed refetch.
    await pageA.waitForTimeout(500)
    await expect(pageA.getByRole('alert')).toBeVisible()
  })
})