// @vitest-environment jsdom
/**
 * Unit tests — ENV-04: TenantsPage — [TEST] badge for test-type tenants
 *
 * TC-ENV04-08: [TEST] badge rendered for test tenant; absent for production tenant
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({
    mutate: vi.fn(),
    isPending: false,
    isError: false,
  })),
  useQueryClient: vi.fn(() => ({
    invalidateQueries: vi.fn(),
  })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/api/queryKeys', () => ({
  queryKeys: {
    admin: {
      tenants: vi.fn(() => ['admin', 'tenants']),
    },
  },
}))

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import TenantsPage from '@/pages/admin/tenants/TenantsPage'
import type { TenantListResponse } from '@/api/tenants'

const mockUseQuery = vi.mocked(useQuery)
const mockUseAuth = vi.mocked(useAuth)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Admin',
  roles: ['PLATFORM_ADMIN'],
  loginSource: null as null,
  tenant_slug: 'platform',
  tenant_display_name: 'Platform',
  tenant_id: 'tid-platform',
  tenant_type: 'production' as const,
  production_tenant_display_name: null,
}

const TENANT_LIST: TenantListResponse = {
  items: [
    {
      slug: 'acme-test',
      display_name: 'Acme',
      idp_realm_id: 'acme-test-realm',
      status: 'ACTIVE',
      created_at: '2026-01-01T00:00:00Z',
      tenant_type: 'test',
      production_tenant_id: 'tid-acme-prod',
      production_tenant_display_name: 'Acme Production',
    },
    {
      slug: 'beta-prod',
      display_name: 'Beta Corp',
      idp_realm_id: 'beta-realm',
      status: 'ACTIVE',
      created_at: '2026-01-02T00:00:00Z',
      tenant_type: 'production',
      production_tenant_id: null,
      production_tenant_display_name: null,
    },
  ],
  total: 2,
  limit: 20,
  offset: 0,
}

// ── Tests ─────────────────────────────────────────────────────────────────────

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ENV-04 — TenantsPage [TEST] badge', () => {
  it('TC-ENV04-08: TEST badge shown for test-type tenant and absent for production tenant', () => {
    mockUseAuth.mockReturnValue({
      session: ADMIN_SESSION,
      isAuthenticated: true,
      isLoading: false,
      loginSource: null,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    })
    mockUseQuery.mockReturnValue({
      data: TENANT_LIST,
      isLoading: false,
      isError: false,
    } as ReturnType<typeof useQuery>)

    render(
      <MemoryRouter>
        <TenantsPage />
      </MemoryRouter>,
    )

    // VERDICT: Screen shows TEST badge for test-type tenant row
    expect(screen.getByTestId('tenant-type-badge-acme-test')).toBeInTheDocument()
    expect(screen.getByTestId('tenant-type-badge-acme-test')).toHaveTextContent('TEST')

    // VERDICT: Production tenant row has no TEST badge
    expect(screen.queryByTestId('tenant-type-badge-beta-prod')).not.toBeInTheDocument()

    // VERDICT: Test tenant display name shows [TEST] suffix in the table cell
    expect(screen.getByText('Acme [TEST]')).toBeInTheDocument()
  })
})
