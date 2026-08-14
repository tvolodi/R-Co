/** a11yGate — GRD-UI-06 §3.3, §3.6, §3.8
 *
 *  Decision-matrix gate: serious|critical -> FAIL; moderate|minor|null ->
 *  record-only MINOR. Throws with ruleId+impact+target on a failure.
 *
 *  The actual axe call is dynamically imported so unit tests don't need
 *  @axe-core/playwright at the dependency layer. The E2E runner must
 *  have @axe-core/playwright installed (it is the only new dev dep
 *  called out in the design §7.2).
 */

import type { Page, TestInfo } from '@playwright/test'
import {
  type A11ySeverity,
  type A11yViolation,
  type A11yRunReport,
  writeReport,
  utcDateStamp,
} from './reportWriter'

export type { A11yViolation, A11ySeverity, A11yRunReport } from './reportWriter'
export { a11yConfig, a11yTags, a11yRuleTimeoutMs } from './a11yConfig'

export interface AxeViolationLite {
  ruleId: string
  impact: 'minor' | 'moderate' | 'serious' | 'critical' | null
  target: string
  help: string
  helpUrl: string
}

export interface A11yRunOptions {
  runId: string
  date?: string
  surface: string
}

export function impactToSeverity(impact: AxeViolationLite['impact']): A11ySeverity {
  if (impact === 'serious' || impact === 'critical') return 'CRITICAL'
  // moderate, minor, null -> record-only MINOR
  return 'MINOR'
}

export function classifyViolations(
  surface: string,
  violations: AxeViolationLite[],
): A11yViolation[] {
  return violations.map((v) => ({
    surface,
    ruleId: v.ruleId,
    impact: v.impact,
    target: v.target,
    help: v.help,
    helpUrl: v.helpUrl,
    severity: impactToSeverity(v.impact),
  }))
}

export function aggregateBlockingViolations(
  perSurfaceViolations: A11yViolation[],
): A11yViolation[] {
  return perSurfaceViolations.filter((v) => v.severity === 'CRITICAL')
}

export async function verifyBackendReachable(
  options: { apiBase?: string; idpBase?: string; dbUrl?: string } = {},
): Promise<void> {
  const apiBase = options.apiBase ?? process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
  const idpBase = options.idpBase ?? process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081'
  const dbUrl = options.dbUrl ?? process.env.BPM_TEST_DB_URL

  const probes: Array<Promise<{ name: string; ok: boolean; err?: string }>> = [
    fetch(`${apiBase}/health`)
      .then((r) => ({ name: 'BPM-API', ok: r.ok }))
      .catch((e: unknown) => ({ name: 'BPM-API', ok: false, err: String(e) })),
    fetch(`${idpBase}/realms/bpm-default`)
      .then((r) => ({ name: 'Keycloak', ok: r.ok }))
      .catch((e: unknown) => ({ name: 'Keycloak', ok: false, err: String(e) })),
  ]

  if (dbUrl) {
    // We don't want to require a Postgres client to be loaded just for the
    // probe — a TCP connect attempt is sufficient as a coarse-grained
    // reachability check.
    try {
      const u = new URL(dbUrl)
      probes.push(
        (async () => {
          // Lazy dynamic import — no top-level dependency on node:net
          // for unit tests.
          const net = (await import('node:net')) as typeof import('node:net')
          return new Promise<{ name: string; ok: boolean; err?: string }>((resolve) => {
            const sock = net.connect({ host: u.hostname, port: Number(u.port) }, () => {
              sock.end()
              resolve({ name: 'PostgreSQL', ok: true })
            })
            sock.on('error', (e: Error) => {
              resolve({ name: 'PostgreSQL', ok: false, err: e.message })
            })
          })
        })(),
      )
    } catch {
      /* malformed URL — skip probe */
    }
  }

  const results = await Promise.all(probes)
  const failed = results.filter((r) => !r.ok)
  if (failed.length > 0) {
    const names = failed.map((f) => f.name).join(', ')
    throw new Error(
      `A11Y GATE BLOCKER: ${names} unreachable — no surface scanned`,
    )
  }
}

export interface A11yGateRunResult {
  surface: string
  violations: A11yViolation[]
  elapsedMs: number
}

/**
 * Run the axe-core gate against a single page. The function is generic
 * over the axe API — callers pass a `runAxe` thunk that uses
 * `@axe-core/playwright` (or any other compatible runner). This avoids
 * forcing a hard dependency on the package at the gate module level.
 */
export async function runA11yGate(
  page: Page,
  _testInfo: TestInfo,
  options: A11yRunOptions,
  runAxe: () => Promise<AxeViolationLite[]>,
  reportSink?: (report: A11yRunReport) => Promise<string>,
): Promise<A11yGateRunResult> {
  const start = Date.now()
  await verifyBackendReachable()

  const raw = await runAxe()
  const elapsedMs = Date.now() - start
  const violations = classifyViolations(options.surface, raw)

  const blocking = aggregateBlockingViolations(violations)
  if (blocking.length > 0) {
    const detail = blocking
      .map((v) => `${v.ruleId} [${v.impact}] at ${v.target}`)
      .join('; ')
    throw new Error(
      `A11Y GATE FAIL on surface '${options.surface}': ${blocking.length} blocking violation(s): ${detail}`,
    )
  }

  if (reportSink) {
    await reportSink({
      runId: options.runId,
      date: options.date ?? utcDateStamp(),
      evaluatedSurfaces: [options.surface],
      violations,
    })
  } else {
    await writeReport({
      runId: options.runId,
      date: options.date ?? utcDateStamp(),
      evaluatedSurfaces: [options.surface],
      violations,
    })
  }

  return { surface: options.surface, violations, elapsedMs }
}
