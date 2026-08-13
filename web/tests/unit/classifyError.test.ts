// @vitest-environment node
/**
 * Unit tests — RND-UI-01: classifyError HTTP status mapping
 *
 *   TC-CE-01: 401 → permission-denied
 *   TC-CE-02: 403 → permission-denied
 *   TC-CE-03: 409 → stale-version
 *   TC-CE-04: 429 with retryAfter → rate-limit
 *   TC-CE-05: 429 without retryAfter → fetch-failure
 *   TC-CE-06: 5xx → fetch-failure
 *   TC-CE-07: network error (no status) → fetch-failure
 */

import { describe, it, expect } from 'vitest'
import { classifyError } from '@/utils/classifyError'

describe('RND-UI-01 — classifyError', () => {
  it('TC-CE-01: 401 → permission-denied', () => {
    expect(classifyError({ status: 401, message: 'Unauthorized', code: 'UNAUTHORIZED' })).toBe('permission-denied')
  })

  it('TC-CE-02: 403 → permission-denied', () => {
    expect(classifyError({ status: 403, message: 'Forbidden', code: 'FORBIDDEN' })).toBe('permission-denied')
  })

  it('TC-CE-03: 409 → stale-version', () => {
    expect(classifyError({ status: 409, message: 'Conflict', code: 'CONFLICT' })).toBe('stale-version')
  })

  it('TC-CE-04: 429 with retryAfter present → rate-limit', () => {
    expect(
      classifyError({ status: 429, message: 'Too Many Requests', code: 'RATE_LIMITED', details: { retryAfter: 30 } }),
    ).toBe('rate-limit')
  })

  it('TC-CE-05: 429 without retryAfter → fetch-failure', () => {
    expect(classifyError({ status: 429, message: 'Too Many Requests', code: 'RATE_LIMITED' })).toBe('fetch-failure')
  })

  it('TC-CE-06: 500 server error → fetch-failure', () => {
    expect(classifyError({ status: 500, message: 'Internal Server Error', code: 'INTERNAL' })).toBe('fetch-failure')
  })

  it('TC-CE-07: network error (no status field) → fetch-failure', () => {
    expect(classifyError(new Error('Network request failed'))).toBe('fetch-failure')
  })
})
