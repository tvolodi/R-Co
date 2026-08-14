// @vitest-environment jsdom
/**
 * Unit tests — RND-UI-06: StaleVersionError
 *
 *   TC-SVE-01: mounts ConflictResolver when error is provided
 *   TC-SVE-02: conflictVersion is read from error.details.xResourceVersion
 *   TC-SVE-03: refetch error surfaces FetchError above the resolver
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)
import { StaleVersionError } from '@/components/ui/StaleVersionError'
import type { ApiError } from '@/types/api'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const baseError: ApiError = {
  status: 409,
  message: 'Conflict',
  code: 'STALE_VERSION',
  details: { xResourceVersion: 'v42' },
}

describe('RND-UI-06 — StaleVersionError', () => {
  it('TC-SVE-01: mounts ConflictResolver with three data-testid buttons', () => {
    render(
      <StaleVersionError
        error={baseError}
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        onRefetch={() => undefined}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={() => undefined}
      />,
    )
    expect(screen.getByTestId('conflict-resolver')).toBeVisible()
    expect(screen.getByTestId('conflict-refetch')).toBeEnabled()
    expect(screen.getByTestId('conflict-merge')).toBeEnabled()
    expect(screen.getByTestId('conflict-discard')).toBeEnabled()
  })

  it('TC-SVE-02: missing xResourceVersion disables Merge', () => {
    render(
      <StaleVersionError
        error={{ ...baseError, details: { xResourceVersion: null } }}
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        onRefetch={() => undefined}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={() => undefined}
      />,
    )
    expect(screen.getByTestId('conflict-merge')).toBeDisabled()
  })

  it('TC-SVE-03: onRefetch throwing surfaces FetchError above the resolver', () => {
    const onRefetch = vi.fn(() => {
      throw new Error('Network down')
    })
    render(
      <StaleVersionError
        error={baseError}
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        onRefetch={onRefetch}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={() => undefined}
      />,
    )
    // Top "updated by another user" alert is always rendered.
    expect(screen.getAllByRole('alert').length).toBeGreaterThanOrEqual(1)
    fireEvent.click(screen.getByTestId('conflict-refetch'))
    // After the throw, the FetchError banner should appear above the
    // resolver (the second alert surface).
    expect(screen.getAllByRole('alert').length).toBeGreaterThanOrEqual(2)
  })
})
