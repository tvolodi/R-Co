// @vitest-environment jsdom
/**
 * Unit test — ENV-04 AC-5: Instance list tenant isolation
 *
 * TC-ENV04-09: InstanceBoardPage calls useInstances without a tenant_id filter.
 * Tenant isolation is backend-enforced via the session JWT bearer token;
 * the component renders whatever the API returns without client-side
 * cross-tenant filtering.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)

// ── Mock dependencies before importing the component ─────────────────────────

vi.mock('@/hooks/useInstances', () => ({
  useInstances: vi.fn(),
  useStartInstance: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  instanceKeys: {
    all: ['instances'],
    list: (f: unknown) => ['instances', 'list', f],
    detail: (id: string) => ['instances', id],
    events: (id: string, f: unknown) => ['instances', id, 'events', f],
    timeline: (id: string, p: unknown) => ['instances', id, 'timeline', p],
  },
}))

vi.mock('@/hooks/useDefinitions', () => ({
  useDefinitions: vi.fn(() => ({ data: undefined })),
  useDefinition: vi.fn(() => ({ data: undefined, isLoading: false })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/hooks/usePolling', () => ({
  usePolling: vi.fn(() => ({ lastRefreshedAt: null, refreshNow: vi.fn(), refreshCount: 0 })),
}))

vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual('@tanstack/react-query')
  return { ...(actual as object), useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })) }
})

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useNavigate: vi.fn(() => vi.fn()),
    useSearchParams: vi.fn(() => [new URLSearchParams(), vi.fn()]),
    Link: ({ children, to }: { children: React.ReactNode; to: string }) =>
      React.createElement('a', { href: String(to) }, children),
  }
})

// ── Imports after mocks ───────────────────────────────────────────────────────

import { useInstances } from '@/hooks/useInstances'
import { useAuth } from '@/auth/AuthContext'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'

const mockUseInstances = vi.mocked(useInstances)
const mockUseAuth = vi.mocked(useAuth)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const TEST_SESSION = {
  token: 'tok',
  display_name: 'Alice',
  roles: ['PROCESS_OPERATOR'],
  loginSource: null as null,
  tenant_slug: 'acme-test',
  tenant_display_name: 'Acme Test',
  tenant_id: 'tid-test-001',
  tenant_type: 'test' as const,
  production_tenant_display_name: 'Acme Production',
}

const AUTH_VALUE = {
  isAuthenticated: true,
  isLoading: false,
  loginSource: null as null,
  login: vi.fn(),
  logout: vi.fn(),
  setSession: vi.fn(),
  session: TEST_SESSION,
}

// ── Tests ─────────────────────────────────────────────────────────────────────

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ENV-04 AC-5 — InstanceBoardPage tenant isolation', () => {
  it('TC-ENV04-09: useInstances called without tenant_id filter; component renders API-returned rows (backend-enforced isolation)', () => {
    const INSTANCE = {
      instance_id: 'aa000000-0000-0000-0000-000000000001',
      definition_id: 'def-111',
      definition_name: 'My Flow',
      definition_version: '1.0.0',
      status: 'ACTIVE' as const,
      current_nodes: [] as string[],
      variables: {},
      started_at: '2026-08-01T10:00:00Z',
    }

    mockUseInstances.mockReturnValue({
      data: { items: [INSTANCE], next_cursor: null },
      isLoading: false,
      error: null,
      isRefetching: false,
    } as ReturnType<typeof useInstances>)

    mockUseAuth.mockReturnValue(AUTH_VALUE)

    render(<InstanceBoardPage />)

    // VERDICT: component renders the instance row returned by the API
    expect(screen.getByText('My Flow v1.0.0')).toBeInTheDocument()

    // VERDICT: useInstances was NOT called with a tenant_id prop — isolation is backend-enforced
    // The instances endpoint /api/v1/instances scopes results to the session tenant via JWT
    const callArg = mockUseInstances.mock.calls[0]?.[0]
    expect(callArg).not.toHaveProperty('tenant_id')
  })
})
