/**
 * E2E — GRD-UI-06 + GRD-UI-07: axe accessibility gate (no-mock contract)
 *
 *  Per design §0, every E2E hits the real backend. No HTTP mocking,
 *  no page.route() interception of API or auth endpoints. The axe
 *  runner is dynamically imported so unit tests don't fail to compile
 *  when @axe-core/playwright is absent.
 */

import {
  test,
  expect,
  type Page,
  type TestInfo,
  type APIRequestContext,
} from '@playwright/test'
import {
  runA11yGate,
  verifyBackendReachable,
  type AxeViolationLite,
} from '../a11y/a11yGate'
import { getKeycloakToken, loginWithToken } from './helpers'

const SURFACES: Array<{ name: string; path: string }> = [
  { name: 'task-inbox', path: '/tasks/inbox' },
  { name: 'instance-list', path: '/instances/board' },
  { name: 'definition-list', path: '/definitions' },
  { name: 'process-designer', path: '/definitions' /* editor opens on click */ },
  { name: 'login', path: '/' },
]

async function loginAsWorker(page: Page, request: APIRequestContext): Promise<void> {
  const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
  await loginWithToken(page, token)
}

/**
 * Lazily load @axe-core/playwright. Returns null when unavailable;
 * the caller must then `test.skip(true, …)`.
 */
async function loadAxe(): Promise<
  ((page: Page) => Promise<AxeViolationLite[]>) | null
> {
  try {
    const mod = (await import('@axe-core/playwright')) as {
      default: new (page: Page) => { analyze(): Promise<{ violations: Array<{
        id: string
        impact: 'minor' | 'moderate' | 'serious' | 'critical' | null
        nodes: Array<{ target: unknown }>
        help: string
        helpUrl: string
      }> }> }
    }
    const AxeBuilder = mod.default
    return async (page: Page) => {
      const builder = new AxeBuilder(page)
      const results = await builder.analyze()
      return results.violations.map((v) => ({
        ruleId: v.id,
        impact: v.impact,
        target:
          (v.nodes[0]?.target as unknown as string[] | undefined)?.join(' ') ?? '',
        help: v.help,
        helpUrl: v.helpUrl,
      }))
    }
  } catch {
    return null
  }
}

test.describe('GRD-UI-06 — a11y gate (no mocks)', () => {
  test('TC-GRD-UI-06-E2E-PROBE: backend reachability probe passes', async () => {
    await expect(verifyBackendReachable()).resolves.toBeUndefined()
  })

  test('TC-GRD-UI-06-E2E-BLOCKER: BLOCKER if BPM-API unreachable', async () => {
    await expect(
      verifyBackendReachable({ apiBase: 'http://127.0.0.1:1' }),
    ).rejects.toThrow(/A11Y GATE BLOCKER/)
  })

  for (const surface of SURFACES) {
    test(`TC-GRD-UI-06-E2E-SURFACE-${surface.name}: gate passes (no serious/critical)`, async ({
      page,
      request,
    }, testInfo: TestInfo) => {
      test.setTimeout(30_000)
      if (surface.name === 'login') {
        await page.goto('/')
      } else {
        await loginAsWorker(page, request)
        await page.goto(surface.path)
      }
      const runAxe = await loadAxe()
      if (!runAxe) {
        testInfo.skip(true, '@axe-core/playwright not installed — skip the gate scan')
        return
      }
      const result = await runA11yGate(
        page,
        testInfo,
        { runId: `a11y-${surface.name}`, surface: surface.name },
        () => runAxe(page),
      )
      expect(result.violations.filter((v) => v.severity === 'CRITICAL')).toHaveLength(0)
    })
  }

  test('TC-GRD-UI-06-E2E-FAIL: serious violation fails the gate with ruleId + impact + target', async ({
    page,
    request,
  }, testInfo) => {
    test.setTimeout(30_000)
    await loginAsWorker(page, request)
    await page.goto('/tasks/inbox')
    const fakeViolations: AxeViolationLite[] = [
      {
        ruleId: 'aria-valid-attr-value',
        impact: 'serious',
        target: '[data-testid="task-row"]',
        help: 'ARIA attributes must conform to valid values',
        helpUrl: 'https://dequeuniversity.com/rules/axe/4.7/aria-valid-attr-value',
      },
    ]
    await expect(
      runA11yGate(
        page,
        testInfo,
        { runId: 'a11y-fail', surface: 'task-inbox' },
        () => Promise.resolve(fakeViolations),
      ),
    ).rejects.toThrow(/aria-valid-attr-value/)
  })

  test('TC-GRD-UI-06-E2E-MINOR: moderate impact recorded-only; YAML has severity MINOR', async ({
    page,
    request,
  }, testInfo) => {
    test.setTimeout(30_000)
    await loginAsWorker(page, request)
    await page.goto('/tasks/inbox')
    const result = await runA11yGate(
      page,
      testInfo,
      { runId: 'a11y-minor', surface: 'task-inbox' },
      () =>
        Promise.resolve([
          {
            ruleId: 'synthetic-moderate',
            impact: 'moderate' as const,
            target: '[data-testid="task-row"]',
            help: 'synthetic moderate',
            helpUrl: 'https://example.test/synthetic',
          },
        ]),
    )
    const minors = result.violations.filter((v) => v.severity === 'MINOR')
    expect(minors.length).toBeGreaterThanOrEqual(1)
  })

  test('TC-GRD-UI-06-E2E-CONTRAST: Task Inbox brand-override contrast (axe + computed style)', async ({
    page,
    request,
  }, testInfo) => {
    test.setTimeout(30_000)
    await loginAsWorker(page, request)
    await page.goto('/tasks/inbox')
    const runAxe = await loadAxe()
    if (!runAxe) {
      testInfo.skip(true, '@axe-core/playwright not installed — skip the contrast scan')
      return
    }
    const result = await runA11yGate(
      page,
      testInfo,
      { runId: 'a11y-contrast', surface: 'task-inbox' },
      () => runAxe(page),
    )
    const contrastBlocking = result.violations.filter(
      (v) => v.ruleId === 'color-contrast' && v.severity === 'CRITICAL',
    )
    expect(contrastBlocking).toHaveLength(0)

    // Belt-and-braces computed-style check (WCAG AA = 4.5:1 for normal text).
    const ratio = await page.evaluate(() => {
      const row = document.querySelector('[data-testid="task-row"]') as HTMLElement | null
      if (!row) return null
      const bg = window.getComputedStyle(row).backgroundColor
      // Walk the first text node and read its computed colour.
      const text = row.querySelector('p, span, td, div') as HTMLElement | null
      const fg = text ? window.getComputedStyle(text).color : 'rgb(0,0,0)'
      const parseRgb = (s: string): [number, number, number] => {
        const m = s.match(/rgba?\(([^)]+)\)/)
        if (!m || !m[1]) return [255, 255, 255]
        const parts = m[1].split(',').map((x) => Number(x.trim()))
        return [parts[0] ?? 255, parts[1] ?? 255, parts[2] ?? 255]
      }
      const lum = (rgb: [number, number, number]): number => {
        const a = rgb.map((v) => {
          const c = v / 255
          return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
        }) as [number, number, number]
        return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]
      }
      const bgRgb = parseRgb(bg)
      const fgRgb = parseRgb(fg)
      const l1 = lum(bgRgb)
      const l2 = lum(fgRgb)
      const lighter = Math.max(l1, l2)
      const darker = Math.min(l1, l2)
      return (lighter + 0.05) / (darker + 0.05)
    })
    if (ratio !== null) {
      expect(ratio).toBeGreaterThanOrEqual(4.5)
    }
  })

  test('TC-GRD-UI-06-E2E-BUDGET: per-surface runtime is bounded to 30s', async ({
    page,
    request,
  }) => {
    test.setTimeout(30_000)
    await loginAsWorker(page, request)
    const start = Date.now()
    await page.goto('/tasks/inbox')
    const elapsed = Date.now() - start
    expect(elapsed).toBeLessThan(30_000)
  })

  test('TC-GRD-UI-06-E2E-UNKNOWN-RULE: unknown rule ID is reported verbatim', async ({
    page,
    request,
  }, testInfo) => {
    test.setTimeout(30_000)
    await loginAsWorker(page, request)
    await page.goto('/tasks/inbox')
    const fakeViolations: AxeViolationLite[] = [
      {
        ruleId: 'unknown-rule-2099-future',
        impact: 'critical',
        target: '[data-testid="task-row"]',
        help: 'unknown',
        helpUrl: 'https://example.test/unknown',
      },
    ]
    await expect(
      runA11yGate(
        page,
        testInfo,
        { runId: 'a11y-unknown', surface: 'task-inbox' },
        () => Promise.resolve(fakeViolations),
      ),
    ).rejects.toThrow(/unknown-rule-2099-future/)
  })
})
