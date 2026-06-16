// @vitest-environment jsdom
/**
 * Unit tests for tenantConfig.ts — resolveRealmFromUrl pure-logic tests.
 *
 * Covers: OIDC-F-06
 * Test cases: TC-OIDC-F06-01, TC-OIDC-F06-02
 *
 * DIRECTIVE T-2 note: these tests cover a pure URL/sessionStorage utility function
 * with no HTTP calls. No backend is required and no HTTP mocking is used.
 *
 * Environment: jsdom (required for sessionStorage + window.location)
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { resolveRealmFromUrl } from './tenantConfig'

describe('resolveRealmFromUrl', () => {
  beforeEach(() => {
    // Clear sessionStorage before each test to ensure isolation.
    sessionStorage.clear()
    // Default: no realm in URL.
    vi.stubGlobal('location', { search: '' })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    sessionStorage.clear()
  })

  it('TC-OIDC-F06-01: returns slug from ?realm= URL param and writes to sessionStorage', () => {
    // Arrange: URL contains ?realm=swiftroute; sessionStorage is empty.
    vi.stubGlobal('location', { search: '?realm=swiftroute' })

    // Act
    const result = resolveRealmFromUrl()

    // Assert: slug returned and persisted
    expect(result).toBe('swiftroute')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('swiftroute')
  })

  it('TC-OIDC-F06-02: returns slug from sessionStorage when key is already set', () => {
    // Arrange: sessionStorage already has the slug from a previous page load.
    sessionStorage.setItem('bpm_realm_slug', 'meridian')
    // URL has no ?realm= param.
    vi.stubGlobal('location', { search: '' })

    // Act
    const result = resolveRealmFromUrl()

    // Assert: sessionStorage key wins; URL is not consulted.
    expect(result).toBe('meridian')
  })
})
