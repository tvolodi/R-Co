// @vitest-environment jsdom
/**
 * Unit tests for buildRedirectArgs (oidcRedirectArgs.ts).
 *
 * Covers: OIDC-F-02
 * Spec: tests/specs/OIDC-F-02-callback-realm.md
 * Test cases: TC-OIDC-F02-01, TC-OIDC-F02-02, TC-OIDC-F02-03
 *
 * DIRECTIVE T-2 note: buildRedirectArgs is a pure utility with no HTTP calls.
 * No backend is required and no HTTP mocking is used.
 *
 * Environment: jsdom (required for window.location.origin)
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// Must be hoisted before the module-under-test is imported so that vi.mock
// intercepts the tenantConfig dependency.
vi.mock('@/auth/tenantConfig', () => ({
  resolveRealmFromUrl: vi.fn(),
}))

import { resolveRealmFromUrl } from '@/auth/tenantConfig'
import { buildRedirectArgs } from './oidcRedirectArgs'

const mockResolveRealmFromUrl = resolveRealmFromUrl as ReturnType<typeof vi.fn>

describe('buildRedirectArgs', () => {
  beforeEach(() => {
    vi.stubGlobal('location', {
      origin: 'https://app.example.com',
      search: '',
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.clearAllMocks()
  })

  it('TC-OIDC-F02-01: returns realm-qualified redirect_uri when slug is present', () => {
    // Arrange
    mockResolveRealmFromUrl.mockReturnValue('swiftroute')

    // Act
    const result = buildRedirectArgs()

    // Assert
    expect(result).toBeDefined()
    expect(result!.redirect_uri).toBe(
      'https://app.example.com/auth/callback?realm=swiftroute',
    )
  })

  it('TC-OIDC-F02-02: returns undefined when no realm slug is resolvable', () => {
    // Arrange
    mockResolveRealmFromUrl.mockReturnValue(null)

    // Act
    const result = buildRedirectArgs()

    // Assert: undefined so UserManager falls back to its configured redirect_uri
    expect(result).toBeUndefined()
  })

  it('TC-OIDC-F02-03: percent-encodes special characters in the realm slug', () => {
    // Arrange — slug contains a space and a forward slash
    mockResolveRealmFromUrl.mockReturnValue('my realm/test')

    // Act
    const result = buildRedirectArgs()

    // Assert
    expect(result).toBeDefined()
    expect(result!.redirect_uri).toContain('my%20realm%2Ftest')
    expect(result!.redirect_uri).toBe(
      'https://app.example.com/auth/callback?realm=my%20realm%2Ftest',
    )
  })
})
