/**
 * Pipeline testing helpers.
 *
 * Pipeline tests are multi-step workflows where each step's output is the
 * next step's input. Unlike island tests (setup → test → teardown per case),
 * pipeline tests accumulate real system state across steps. A failure at step N
 * intentionally aborts steps N+1..end — testing a broken precondition is noise.
 *
 * Usage pattern:
 *   const pl = createPipeline('admin-user-lifecycle', { page, request })
 *   await pl.step('create role', async (state) => {
 *     // ... UI actions ...
 *     state.roleId = extractIdFromUrl(page.url())
 *   })
 *   await pl.step('assign role to user', async (state) => {
 *     // state.roleId is available here
 *   })
 *   await pl.cleanup(async (state) => { ... })
 */

import * as fs from 'fs'
import * as path from 'path'
import type { Page, APIRequestContext } from '@playwright/test'
import { test, expect } from '@playwright/test'

const STATE_DIR = path.resolve('tests/e2e/.pipeline-state')
const KEYCLOAK_BASE_URL = (process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081').replace(/\/$/, '')
const KEYCLOAK_TOKEN_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`
const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'

// ─── Token helpers ────────────────────────────────────────────────────────────

export async function getKeycloakToken(
  request: APIRequestContext,
  username = 'admin-user',
  password = 'admin-pass',
): Promise<string> {
  const response = await request.post(KEYCLOAK_TOKEN_URL, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: { client_id: KEYCLOAK_CLIENT_ID, username, password, grant_type: 'password' },
  })
  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Keycloak token request failed (${response.status()}): ${body}`)
  }
  const body = await response.json() as { access_token: string }
  return body.access_token
}

function decodeJwtPayload(token: string): { sub: string; exp: number; roles?: string[]; preferred_username?: string; name?: string; email?: string } {
  return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf-8'))
}

export function jwtSubject(token: string): string {
  return decodeJwtPayload(token).sub
}

export function authHeaders(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}`, 'x-bpm-user-id': jwtSubject(token) }
}

/** Refresh the token if it expires within 60 seconds. */
export async function refreshTokenIfNeeded(
  request: APIRequestContext,
  token: string,
  username = 'admin-user',
  password = 'admin-pass',
): Promise<string> {
  const { exp } = decodeJwtPayload(token)
  if (exp - Math.floor(Date.now() / 1000) < 60) {
    return getKeycloakToken(request, username, password)
  }
  return token
}

// ─── Session injection ────────────────────────────────────────────────────────

/** Inject a Keycloak token into the app via sessionStorage before page.goto(). */
export async function loginWithToken(page: Page, token: string): Promise<void> {
  const payload = decodeJwtPayload(token)
  const displayName = payload.preferred_username ?? payload.name ?? payload.email ?? payload.sub
  await page.addInitScript(
    (args: { token: string; displayName: string; roles: string[] }) => {
      sessionStorage.setItem('__e2e_session', JSON.stringify({
        token: args.token,
        display_name: args.displayName,
        roles: args.roles,
        loginSource: 'oidc' as const,
      }))
    },
    { token, displayName, roles: payload.roles ?? [] },
  )
  await page.goto('/', { waitUntil: 'domcontentloaded' })
  await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 }).catch(() => {})
}

// ─── SPA navigation ───────────────────────────────────────────────────────────

export async function navigateSpa(page: Page, targetPath: string): Promise<void> {
  await page.evaluate((nextPath) => {
    window.history.pushState({}, '', nextPath)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

// ─── ID extraction ────────────────────────────────────────────────────────────

/** Extract the last path segment from a URL (strips query string and hash). */
export function extractIdFromUrl(url: string, afterSegment?: string): string {
  const pathname = new URL(url, 'http://localhost').pathname
  if (afterSegment) {
    const idx = pathname.indexOf(`/${afterSegment}/`)
    if (idx !== -1) return pathname.slice(idx + afterSegment.length + 2).split('/')[0]
  }
  const parts = pathname.split('/').filter(Boolean)
  return parts[parts.length - 1] ?? ''
}

// ─── Checkpoint persistence ───────────────────────────────────────────────────

function statePath(name: string): string {
  fs.mkdirSync(STATE_DIR, { recursive: true })
  return path.join(STATE_DIR, `${name}.json`)
}

export function loadCheckpoint<T extends object>(name: string): Partial<T> {
  const p = statePath(name)
  if (fs.existsSync(p)) {
    try { return JSON.parse(fs.readFileSync(p, 'utf-8')) as Partial<T> } catch { /* ignore */ }
  }
  return {}
}

export function saveCheckpoint<T extends object>(name: string, state: T): void {
  fs.writeFileSync(statePath(name), JSON.stringify(state, null, 2))
}

export function clearCheckpoint(name: string): void {
  const p = statePath(name)
  if (fs.existsSync(p)) fs.unlinkSync(p)
}

// ─── Screenshots ──────────────────────────────────────────────────────────────

const SCREENSHOTS_DIR = 'tests/screenshots/pipelines'

export async function shot(page: Page, pipelineName: string, stepName: string): Promise<void> {
  fs.mkdirSync(path.resolve(SCREENSHOTS_DIR), { recursive: true })
  const safeName = stepName.replace(/[^a-z0-9]/gi, '-').toLowerCase()
  await page.screenshot({
    path: path.join(SCREENSHOTS_DIR, `${pipelineName}-${safeName}.png`),
    fullPage: true,
  })
}

// ─── Pipeline runner ──────────────────────────────────────────────────────────

export interface PipelineContext {
  page: Page
  request: APIRequestContext
}

export interface PipelineOptions {
  /** Load a previously saved checkpoint instead of starting from scratch. */
  resumeFrom?: string
}

/**
 * Creates a pipeline runner for a named workflow.
 *
 * Steps are named sub-steps via test.step(). State flows forward through
 * a plain object — each step can read values written by earlier steps.
 * A hard expect() failure in any step aborts all remaining steps.
 *
 * Example:
 *   const pl = createPipeline('role-user-lifecycle', ctx)
 *   await pl.step('create role', async (s) => { s.roleId = ... })
 *   await pl.step('assign role', async (s) => { console.log(s.roleId) })
 *   await pl.cleanup(async (s) => { ... api cleanup using s.roleId ... })
 */
export function createPipeline<TState extends object>(
  name: string,
  ctx: PipelineContext,
  opts: PipelineOptions = {},
) {
  // State accumulates forward; load checkpoint if resuming
  const state: TState = (opts.resumeFrom
    ? loadCheckpoint<TState>(opts.resumeFrom)
    : {}) as TState

  let aborted = false
  let cleanupFn: ((s: TState) => Promise<void>) | null = null

  const runner = {
    state,

    async step(stepName: string, fn: (state: TState) => Promise<void>): Promise<void> {
      if (aborted) return
      await test.step(stepName, async () => {
        await fn(state)
        saveCheckpoint(name, state)
        await shot(ctx.page, name, stepName)
      }).catch((err: unknown) => {
        aborted = true
        throw err
      })
    },

    /** Register a cleanup function. Called in afterAll/finally — always runs even if chain aborted. */
    onCleanup(fn: (state: TState) => Promise<void>): void {
      cleanupFn = fn
    },

    async runCleanup(): Promise<void> {
      if (cleanupFn) {
        await cleanupFn(state).catch((err: unknown) => {
          console.warn(`[pipeline:${name}] cleanup error:`, err)
        })
      }
      clearCheckpoint(name)
    },

    screenshot(stepName: string): Promise<void> {
      return shot(ctx.page, name, stepName)
    },

    /** Hard gate: fails the step (and aborts the chain) if condition is false. */
    gate(condition: boolean | string, message: string): void {
      expect(condition, message).toBeTruthy()
    },
  }

  return runner
}
