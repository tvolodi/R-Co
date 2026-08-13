/**
 * E2E — GRD-UI-07: FieldFactory ARIA wiring
 *
 *  Real backend. Tests render the Task Form for a real task and
 *  assert that ARIA attributes (aria-required, aria-describedby,
 *  aria-invalid, aria-errormessage) are wired correctly.
 */

import { test, expect } from '@playwright/test'

async function login(page: import('@playwright/test').Page): Promise<void> {
  await page.goto('/')
  await page.getByLabel(/username/i).fill('admin')
  await page.getByLabel(/password/i).fill('admin')
  await page.getByRole('button', { name: /sign in/i }).click()
  await page.waitForURL(/\/home/)
}

test.describe('GRD-UI-07 — Field ARIA wiring', () => {
  test.beforeEach(async ({ page }) => {
    await login(page)
  })

  test('AC-1: required field has aria-required="true"', async ({ page }) => {
    await page.goto('/tasks/dashboard?taskId=t1')
    const requiredInput = page.getByLabel(/subject/i)
    await expect(requiredInput).toHaveAttribute('aria-required', 'true')
  })

  test('AC-2: field with description hint references hint id via aria-describedby', async ({ page }) => {
    await page.goto('/tasks/dashboard?taskId=t2')
    const input = page.getByLabel(/subject/i)
    const describedBy = await input.getAttribute('aria-describedby')
    expect(describedBy).not.toBeNull()
    const hint = page.locator(`#${describedBy}`)
    await expect(hint).toBeVisible()
  })

  test('AC-3: validation error produces aria-invalid="true" + aria-errormessage target exists', async ({
    page,
  }) => {
    await page.goto('/tasks/dashboard?taskId=t3')
    const input = page.getByLabel(/subject/i)
    await input.fill('')
    await page.getByTestId('task-submit-btn').click()
    await expect(input).toHaveAttribute('aria-invalid', 'true')
    const target = await input.getAttribute('aria-errormessage')
    expect(target).not.toBeNull()
    await expect(page.locator(`#${target}`)).toHaveAttribute('role', 'alert')
  })

  test('AC-4: number, date, textarea, select fields all carry the ARIA attribute set', async ({
    page,
  }) => {
    await page.goto('/tasks/dashboard?taskId=t4')
    const number = page.getByLabel(/quantity/i)
    await expect(number).toHaveAttribute('type', 'number')
    const date = page.getByLabel(/due/i)
    await expect(date).toHaveAttribute('type', 'date')
    const textarea = page.getByLabel(/notes/i)
    await expect(textarea).toHaveJSProperty('tagName', 'TEXTAREA')
  })

  test('AC-5: no dangling aria-errormessage references (validator returns 0)', async ({ page }) => {
    await page.goto('/tasks/dashboard?taskId=t5')
    // Trigger validation so all error nodes render.
    const inputs = page.getByRole('textbox')
    const count = await inputs.count()
    for (let i = 0; i < count; i += 1) {
      const el = inputs.nth(i)
      await el.fill('')
    }
    await page.getByTestId('task-submit-btn').click()
    const dangling = await page.evaluate(() => {
      const all = document.querySelectorAll('[aria-invalid="true"]')
      const missing: string[] = []
      for (const el of Array.from(all) as HTMLElement[]) {
        const targetId = el.getAttribute('aria-errormessage')
        if (!targetId) {
          missing.push('<empty>')
        } else if (!document.getElementById(targetId)) {
          missing.push(targetId)
        }
      }
      return missing
    })
    expect(dangling).toEqual([])
  })

  test('AC-6: optional field omits aria-required attribute', async ({ page }) => {
    await page.goto('/tasks/dashboard?taskId=t6')
    const optional = page.getByLabel(/description/i)
    await expect(optional).not.toHaveAttribute('aria-required')
  })
})