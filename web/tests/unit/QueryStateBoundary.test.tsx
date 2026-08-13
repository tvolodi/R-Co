// @vitest-environment jsdom
/**
 * Unit tests — RND-UI-01: QueryStateBoundary state rendering
 *
 *   TC-QSB-00: never arm exhaustiveness check via @ts-expect-error
 *   TC-QSB-01: loading → SkeletonLayout (aria-busy="true")
 *   TC-QSB-02: success → children rendered
 *   TC-QSB-03: fetch-failure → FetchError (role="alert")
 *   TC-QSB-04: permission-denied → PermissionDenied content
 *   TC-QSB-05: stale-version → role="alert" with Refresh button
 *   TC-QSB-06: rate-limit → role="alert" with Try again button
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import React from 'react'
expect.extend(jestDomMatchers)
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import type { RendererState } from '@/utils/classifyError'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('RND-UI-01 — QueryStateBoundary', () => {
  it('TC-QSB-00: never arm is unreachable — RendererState union is exhaustive', () => {
    // Compile-time exhaustiveness check: TS rejects any non-member value.
    // @ts-expect-error 'invalid-state' is not assignable to RendererState — proves union is closed
    const _: RendererState = 'invalid-state'
    void _
    // Runtime: default: never branch returns null for unknown states
    const { container } = render(
      <MemoryRouter>
        <QueryStateBoundary state={'not-a-valid-state' as RendererState}><span /></QueryStateBoundary>
      </MemoryRouter>,
    )
    expect(container.firstChild).toBeNull()
  })

  it('TC-QSB-01: loading state renders SkeletonLayout with aria-busy="true"', () => {
    render(
      <MemoryRouter>
        <QueryStateBoundary state="loading"><div>content</div></QueryStateBoundary>
      </MemoryRouter>,
    )
    expect(screen.getByLabelText('Loading content')).toHaveAttribute('aria-busy', 'true')
  })

  it('TC-QSB-02: success state renders children', () => {
    render(
      <MemoryRouter>
        <QueryStateBoundary state="success"><div data-testid="child-content">hello</div></QueryStateBoundary>
      </MemoryRouter>,
    )
    expect(screen.getByTestId('child-content')).toBeVisible()
  })

  it('TC-QSB-03: fetch-failure state renders FetchError (role="alert")', () => {
    render(
      <MemoryRouter>
        <QueryStateBoundary state="fetch-failure"><div>content</div></QueryStateBoundary>
      </MemoryRouter>,
    )
    expect(screen.getByRole('alert')).toBeVisible()
  })

  it('TC-QSB-04: permission-denied state renders PermissionDenied content', () => {
    render(
      <MemoryRouter>
        <QueryStateBoundary state="permission-denied"><div>content</div></QueryStateBoundary>
      </MemoryRouter>,
    )
    expect(screen.getByText(/You do not have access/)).toBeVisible()
  })

  it('TC-QSB-05: stale-version state renders alert with Refresh button that fires onRetry', () => {
    const onRetry = vi.fn()
    render(
      <MemoryRouter>
        <QueryStateBoundary state="stale-version" onRetry={onRetry}><div>content</div></QueryStateBoundary>
      </MemoryRouter>,
    )
    expect(screen.getByRole('alert')).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('TC-QSB-06: rate-limit state renders alert with Try again button that fires onRetry', () => {
    const onRetry = vi.fn()
    render(
      <MemoryRouter>
        <QueryStateBoundary state="rate-limit" onRetry={onRetry}><div>content</div></QueryStateBoundary>
      </MemoryRouter>,
    )
    expect(screen.getByRole('alert')).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })
})
