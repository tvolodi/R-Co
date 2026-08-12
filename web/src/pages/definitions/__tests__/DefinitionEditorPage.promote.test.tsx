// @vitest-environment jsdom
/**
 * Unit tests — ENV-04: DefinitionEditorPage — Promote to Production button visibility
 *
 * TC-ENV04-06: button visible when tenantType='test' AND def.status='ACTIVE' AND designer role
 * TC-ENV04-07: button hidden when tenantType='production'
 *
 * Heavy child components (canvas, palette, etc.) are mocked to null so tests
 * only exercise the toolbar condition logic.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)

// ── Mock heavy dependencies before importing the component ────────────────────

vi.mock('@xyflow/react', () => ({
  ReactFlowProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

vi.mock('@/components/canvas/ProcessCanvas', () => ({ default: () => null }))
vi.mock('@/components/canvas/NodePalette', () => ({ default: () => null }))
vi.mock('@/components/canvas/PropertyPanel', () => ({ default: () => null }))
vi.mock('@/components/canvas/ValidationSummaryBar', () => ({ default: () => null }))

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useParams: vi.fn(),
    useBlocker: vi.fn(() => ({ state: 'unblocked' as const })),
  }
})

vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual('@tanstack/react-query')
  return {
    ...(actual as object),
    useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
  }
})

vi.mock('@/hooks/useDefinitions', () => ({
  useDefinition: vi.fn(),
  useCreateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/auth/useTenantContext', () => ({
  useTenantContext: vi.fn(),
}))

vi.mock('@/api/definitions', () => ({
  definitionsApi: {
    promote: vi.fn(),
    exportJson: vi.fn(),
    update: vi.fn(),
  },
}))

vi.mock('@/stores/canvasHistoryStore', () => ({
  useCanvasHistoryStore: Object.assign(vi.fn(() => undefined), {
    getState: vi.fn(() => ({ clear: vi.fn() })),
  }),
}))

// ── Imports after mocks ───────────────────────────────────────────────────────

import { useParams } from 'react-router-dom'
import { useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { useTenantContext } from '@/auth/useTenantContext'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'

const mockUseParams = vi.mocked(useParams)
const mockUseDefinition = vi.mocked(useDefinition)
const mockUseAuth = vi.mocked(useAuth)
const mockUseTenantContext = vi.mocked(useTenantContext)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const ACTIVE_DEFINITION = {
  id: 'def-123',
  name: 'Onboarding Flow',
  version: '1.0.0',
  description: null,
  status: 'ACTIVE' as const,
  graph: {
    nodes: [
      { id: 'start', node_type: 'START', label: null, attributes: null },
      { id: 'end', node_type: 'END', label: null, attributes: null },
    ],
    edges: [{ id: 'e1', source: 'start', target: 'end' }],
  },
}

const DESIGNER_SESSION = {
  token: 'tok',
  display_name: 'Alice',
  roles: ['PROCESS_DESIGNER'],
  loginSource: null as null,
  tenant_slug: 'acme-test',
  tenant_display_name: 'Acme Test',
  tenant_id: 'tid-001',
  tenant_type: 'test' as const,
  production_tenant_display_name: 'Acme Production',
}

const AUTH_VALUE_BASE = {
  isAuthenticated: true,
  isLoading: false,
  loginSource: null as null,
  login: vi.fn(),
  logout: vi.fn(),
  setSession: vi.fn(),
}

// ── Tests ─────────────────────────────────────────────────────────────────────

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ENV-04 — DefinitionEditorPage promote button', () => {
  it('TC-ENV04-06: Promote to Production button shown when test tenant with ACTIVE definition and designer role', () => {
    mockUseParams.mockReturnValue({ id: 'def-123' })
    mockUseDefinition.mockReturnValue({ data: ACTIVE_DEFINITION, isLoading: false } as ReturnType<typeof useDefinition>)
    mockUseAuth.mockReturnValue({ ...AUTH_VALUE_BASE, session: DESIGNER_SESSION })
    mockUseTenantContext.mockReturnValue({
      tenantType: 'test',
      productionDisplayName: 'Acme Production',
      tenantSlug: 'acme-test',
      tenantId: 'tid-001',
      tenantDisplayName: 'Acme Test',
      isUnknown: false,
    })

    render(<DefinitionEditorPage />)

    // VERDICT: Screen shows Promote to Production button for test tenant with ACTIVE definition
    expect(screen.getByTestId('promote-to-production-btn')).toBeInTheDocument()
    expect(screen.getByTestId('promote-to-production-btn')).toHaveTextContent('Promote to Production')
  })

  it('TC-ENV04-07: Promote to Production button absent when tenantType is production', () => {
    mockUseParams.mockReturnValue({ id: 'def-123' })
    mockUseDefinition.mockReturnValue({ data: ACTIVE_DEFINITION, isLoading: false } as ReturnType<typeof useDefinition>)
    mockUseAuth.mockReturnValue({
      ...AUTH_VALUE_BASE,
      session: {
        ...DESIGNER_SESSION,
        tenant_type: 'production' as const,
        production_tenant_display_name: null,
      },
    })
    mockUseTenantContext.mockReturnValue({
      tenantType: 'production',
      productionDisplayName: null,
      tenantSlug: 'acme-prod',
      tenantId: 'tid-002',
      tenantDisplayName: 'Acme Production',
      isUnknown: false,
    })

    render(<DefinitionEditorPage />)

    // VERDICT: Promote to Production button is absent for production tenant
    expect(screen.queryByTestId('promote-to-production-btn')).not.toBeInTheDocument()
  })

  it('TC-ENV04-07b: Promote to Production button absent when definition status is DRAFT (test tenant)', () => {
    const DRAFT_DEFINITION = { ...ACTIVE_DEFINITION, status: 'DRAFT' as const }
    mockUseParams.mockReturnValue({ id: 'def-123' })
    mockUseDefinition.mockReturnValue({ data: DRAFT_DEFINITION, isLoading: false } as ReturnType<typeof useDefinition>)
    mockUseAuth.mockReturnValue({ ...AUTH_VALUE_BASE, session: DESIGNER_SESSION })
    mockUseTenantContext.mockReturnValue({
      tenantType: 'test',
      productionDisplayName: 'Acme Production',
      tenantSlug: 'acme-test',
      tenantId: 'tid-001',
      tenantDisplayName: 'Acme Test',
      isUnknown: false,
    })

    render(<DefinitionEditorPage />)

    // VERDICT: DRAFT definitions must not show the Promote button even on a test tenant
    expect(screen.queryByTestId('promote-to-production-btn')).not.toBeInTheDocument()
  })
})
