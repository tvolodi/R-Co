// @vitest-environment jsdom
/**
 * Unit tests — RND-UI-06: ConflictResolver
 *
 *   TC-CR-01: portal mounting — three data-testid buttons present
 *   TC-CR-02: Merge disabled when conflictVersion is null
 *   TC-CR-03: Merge enabled when conflictVersion is set
 *   TC-CR-04: Discard opens ConfirmDialog
 *   TC-CR-05: Confirm fires onDiscardConfirmed; Cancel does not
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)
import { ConflictResolver } from '@/components/ui/ConflictResolver'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('RND-UI-06 — ConflictResolver', () => {
  it('TC-CR-01: three actions mount with correct data-testid attributes', () => {
    render(
      <ConflictResolver
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        conflictVersion="v2"
        onRefetch={() => undefined}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={() => undefined}
      />,
    )
    expect(screen.getByTestId('conflict-resolver')).toBeVisible()
    expect(screen.getByTestId('conflict-refetch')).toBeVisible()
    expect(screen.getByTestId('conflict-merge')).toBeVisible()
    expect(screen.getByTestId('conflict-discard')).toBeVisible()
  })

  it('TC-CR-02: Merge is disabled when conflictVersion is null; others enabled', () => {
    render(
      <ConflictResolver
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        conflictVersion={null}
        onRefetch={() => undefined}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={() => undefined}
      />,
    )
    expect(screen.getByTestId('conflict-merge')).toBeDisabled()
    expect(screen.getByTestId('conflict-merge')).toHaveAttribute('aria-disabled', 'true')
    expect(screen.getByTestId('conflict-refetch')).toBeEnabled()
    expect(screen.getByTestId('conflict-discard')).toBeEnabled()
  })

  it('TC-CR-03: Merge enabled when conflictVersion is set', () => {
    render(
      <ConflictResolver
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        conflictVersion="v2"
        onRefetch={() => undefined}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={() => undefined}
      />,
    )
    expect(screen.getByTestId('conflict-merge')).toBeEnabled()
  })

  it('TC-CR-04: Refetch fires onRefetch immediately', () => {
    const onRefetch = vi.fn()
    render(
      <ConflictResolver
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        conflictVersion="v2"
        onRefetch={onRefetch}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={() => undefined}
      />,
    )
    fireEvent.click(screen.getByTestId('conflict-refetch'))
    expect(onRefetch).toHaveBeenCalledTimes(1)
  })

  it('TC-CR-05: Discard opens ConfirmDialog; Cancel does not fire onDiscardConfirmed', () => {
    const onDiscardConfirmed = vi.fn()
    render(
      <ConflictResolver
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        conflictVersion="v2"
        onRefetch={() => undefined}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={onDiscardConfirmed}
      />,
    )
    fireEvent.click(screen.getByTestId('conflict-discard'))
    expect(screen.getByTestId('confirm-dialog')).toBeVisible()
    fireEvent.click(screen.getByTestId('confirm-dialog-cancel'))
    expect(onDiscardConfirmed).not.toHaveBeenCalled()
  })

  it('TC-CR-06: Discard confirm fires onDiscardConfirmed', () => {
    const onDiscardConfirmed = vi.fn()
    render(
      <ConflictResolver
        serverPayload={{ a: 1 }}
        localDraft={{ a: 2 }}
        conflictVersion="v2"
        onRefetch={() => undefined}
        onSaveMerged={() => undefined}
        onDiscardConfirmed={onDiscardConfirmed}
      />,
    )
    fireEvent.click(screen.getByTestId('conflict-discard'))
    fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
    expect(onDiscardConfirmed).toHaveBeenCalledTimes(1)
  })

  it('TC-CR-07: Merge panel Save fires onSaveMerged with merged body + version', () => {
    const onSaveMerged = vi.fn()
    render(
      <ConflictResolver
        serverPayload={{ a: 1, b: 'server' }}
        localDraft={{ a: 2, b: 'local' }}
        conflictVersion="v42"
        onRefetch={() => undefined}
        onSaveMerged={onSaveMerged}
        onDiscardConfirmed={() => undefined}
      />,
    )
    fireEvent.click(screen.getByTestId('conflict-merge'))
    expect(screen.getByTestId('conflict-merge-panel')).toBeVisible()
    fireEvent.click(screen.getByTestId('conflict-merge-save'))
    expect(onSaveMerged).toHaveBeenCalledTimes(1)
    const [mergedBody, version] = onSaveMerged.mock.calls[0] as [
      Record<string, unknown>,
      string,
    ]
    expect(version).toBe('v42')
    // Default choice is 'local', so merged body should match localDraft.
    expect(mergedBody['a']).toBe(2)
    expect(mergedBody['b']).toBe('local')
  })
})
