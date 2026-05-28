/**
 * Unit tests for tokenUtils.ts — pure function tests, no backend required.
 * Covers SH-01 (decodeTokenPayload) and SH-04 (resolveDisplayName).
 * Test cases: TC-SH01-U01..U07, TC-SH04-U01..U05
 */

import { describe, expect, it } from 'vitest'
import { decodeTokenPayload, resolveDisplayName } from '../tokenUtils'
import type { JwtPayload } from '@/types/api'

/**
 * Creates a valid-looking fake JWT using standard base64 encoding.
 * The decode path in decodeTokenPayload uses atob, which accepts standard base64,
 * so tokens built with btoa will decode correctly.
 */
function makeTestJwt(payload: object): string {
  const header = btoa(JSON.stringify({ alg: 'none', typ: 'JWT' })).replace(/=+$/, '')
  const body = btoa(JSON.stringify(payload)).replace(/=+$/, '')
  return `${header}.${body}.fake-sig`
}

// ── decodeTokenPayload ────────────────────────────────────────────────────────

describe('decodeTokenPayload', () => {
  it('TC-SH01-U01: decodes a well-formed JWT and returns the payload object', () => {
    const jwt = makeTestJwt({ sub: 'user-1', roles: ['TASK_WORKER'], display_name: 'Alice' })
    const result = decodeTokenPayload(jwt)
    expect(result).not.toBeNull()
    expect(result?.sub).toBe('user-1')
    expect(result?.roles).toEqual(['TASK_WORKER'])
    expect(result?.display_name).toBe('Alice')
  })

  it('TC-SH01-U02: returns null for a token with fewer than 3 segments (two-segment)', () => {
    const result = decodeTokenPayload('only.twosegments')
    expect(result).toBeNull()
  })

  it('TC-SH01-U03: returns null for a token with more than 3 segments (four-segment)', () => {
    const result = decodeTokenPayload('a.b.c.d')
    expect(result).toBeNull()
  })

  it('TC-SH01-U04: returns null when payload segment is invalid base64 (does not throw)', () => {
    const result = decodeTokenPayload('header.!!!invalid_base64!!!.sig')
    expect(result).toBeNull()
  })

  it('TC-SH01-U05: returns null when payload is valid base64 but not JSON', () => {
    const notJsonB64 = btoa('not valid { json').replace(/=+$/, '')
    const result = decodeTokenPayload(`header.${notJsonB64}.sig`)
    expect(result).toBeNull()
  })

  it('TC-SH01-U06: returns null for an empty string', () => {
    const result = decodeTokenPayload('')
    expect(result).toBeNull()
  })

  it('TC-SH01-U07: correctly handles a payload whose base64 length requires padding (length % 4 !== 0)', () => {
    // Use a payload whose JSON will produce a base64 string not divisible by 4
    const jwt = makeTestJwt({ sub: 'u', roles: ['PLATFORM_ADMIN'] })
    const result = decodeTokenPayload(jwt)
    expect(result).not.toBeNull()
    expect(result?.roles).toEqual(['PLATFORM_ADMIN'])
  })
})

// ── resolveDisplayName ────────────────────────────────────────────────────────

describe('resolveDisplayName', () => {
  it('TC-SH04-U01: returns display_name when present (highest priority)', () => {
    const p: JwtPayload = {
      sub: 'u1',
      roles: [],
      display_name: 'Alice Bob',
      name: 'Alice',
      preferred_username: 'abob',
    }
    expect(resolveDisplayName(p)).toBe('Alice Bob')
  })

  it('TC-SH04-U02: falls back to name when display_name is absent', () => {
    const p: JwtPayload = { sub: 'u2', roles: [], name: 'Bob' }
    expect(resolveDisplayName(p)).toBe('Bob')
  })

  it('TC-SH04-U03: falls back to preferred_username when display_name and name are absent', () => {
    const p: JwtPayload = { sub: 'u3', roles: [], preferred_username: 'bsmith' }
    expect(resolveDisplayName(p)).toBe('bsmith')
  })

  it('TC-SH04-U04: falls back to sub when only sub and roles are present', () => {
    const p: JwtPayload = { sub: 'user-uuid-001', roles: [] }
    expect(resolveDisplayName(p)).toBe('user-uuid-001')
  })

  it('TC-SH04-U05: returns "Unknown User" when all name fields are absent', () => {
    // Cast to bypass required fields — testing the runtime fallback
    const p = {} as JwtPayload
    expect(resolveDisplayName(p)).toBe('Unknown User')
  })
})
