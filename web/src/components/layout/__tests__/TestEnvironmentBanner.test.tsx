// @vitest-environment jsdom
/**
 * Unit tests — ENV-04: TestEnvironmentBanner component
 *
 * TC-ENV04-01: renders TEST ENVIRONMENT banner and production tenant name when tenant_type is test
 * TC-ENV04-02: does NOT render banner when tenant_type is production
 * TC-ENV04-03: shows "(unknown)" fallback when production_tenant_display_name is null
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

vi.mock('@/auth/useTenantContext')

import { TestEnvironmentBanner } from '../TestEnvironmentBanner'
import { useTenantContext } from '@/auth/useTenantContext'

const mockUseTenantContext = vi.mocked(useTenantContext)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ENV-04 — TestEnvironmentBanner', () => {
  it('TC-ENV04-01: renders TEST ENVIRONMENT banner with production tenant name when tenantType is test', () => {
    mockUseTenantContext.mockReturnValue({
      tenantType: 'test',
      productionDisplayName: 'Acme Production',
      tenantSlug: 'acme-test',
      tenantId: 'tid-001',
      tenantDisplayName: 'Acme Test',
      isUnknown: false,
    })

    render(<TestEnvironmentBanner />)

    // VERDICT: Screen shows TEST ENVIRONMENT banner with paired production name
    expect(screen.getByTestId('test-environment-banner')).toBeInTheDocument()
    expect(screen.getByText('TEST ENVIRONMENT')).toBeVisible()
    expect(screen.getByText('Paired with production: Acme Production')).toBeVisible()
  })

  it('TC-ENV04-02: does NOT render banner when tenantType is production', () => {
    mockUseTenantContext.mockReturnValue({
      tenantType: 'production',
      productionDisplayName: null,
      tenantSlug: 'acme-prod',
      tenantId: 'tid-002',
      tenantDisplayName: 'Acme',
      isUnknown: false,
    })

    const { container } = render(<TestEnvironmentBanner />)

    // VERDICT: Component renders nothing for production tenant — banner absent
    expect(container).toBeEmptyDOMElement()
    expect(screen.queryByTestId('test-environment-banner')).not.toBeInTheDocument()
  })

  it('TC-ENV04-03: shows "(unknown)" fallback when productionDisplayName is null on a test tenant', () => {
    mockUseTenantContext.mockReturnValue({
      tenantType: 'test',
      productionDisplayName: null,
      tenantSlug: 'orphan-test',
      tenantId: 'tid-003',
      tenantDisplayName: 'Orphan Test',
      isUnknown: false,
    })

    render(<TestEnvironmentBanner />)

    // VERDICT: Screen shows (unknown) fallback text in the paired-with span
    expect(screen.getByTestId('test-environment-banner')).toBeInTheDocument()
    expect(screen.getByText('Paired with production: (unknown)')).toBeVisible()
  })
})
