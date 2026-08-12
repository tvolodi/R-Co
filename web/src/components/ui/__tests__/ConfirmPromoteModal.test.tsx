// @vitest-environment jsdom
/**
 * Unit tests — ENV-04: ConfirmPromoteModal component
 *
 * TC-ENV04-04: modal shows exact prescribed heading and body text; onConfirm called on click
 * TC-ENV04-05: cancel button calls onCancel and does NOT call onConfirm
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { ConfirmPromoteModal } from '../ConfirmPromoteModal'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ENV-04 — ConfirmPromoteModal', () => {
  it('TC-ENV04-04: renders prescribed heading and body text; onConfirm called when Confirm clicked', () => {
    const onConfirm = vi.fn()
    const onCancel = vi.fn()

    render(
      <ConfirmPromoteModal
        definitionName="Onboarding Flow"
        productionDisplayName="Acme Production"
        onConfirm={onConfirm}
        onCancel={onCancel}
        isLoading={false}
      />,
    )

    // VERDICT: Screen shows exact prescribed heading
    expect(screen.getByRole('heading', { name: 'Promote to Production' })).toBeVisible()
    // VERDICT: Screen shows exact prescribed body text
    expect(
      screen.getByText(
        "You are about to promote 'Onboarding Flow' to production tenant 'Acme Production'. " +
        "This will create a DRAFT version that requires separate activation. Confirm?",
      ),
    ).toBeVisible()

    fireEvent.click(screen.getByTestId('promote-confirm-btn'))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it('TC-ENV04-05: cancel button calls onCancel and does NOT call onConfirm', () => {
    const onConfirm = vi.fn()
    const onCancel = vi.fn()

    render(
      <ConfirmPromoteModal
        definitionName="Onboarding Flow"
        productionDisplayName="Acme Production"
        onConfirm={onConfirm}
        onCancel={onCancel}
        isLoading={false}
      />,
    )

    fireEvent.click(screen.getByTestId('promote-cancel-btn'))

    // VERDICT: onCancel invoked once; onConfirm not invoked after cancel
    expect(onCancel).toHaveBeenCalledTimes(1)
    expect(onConfirm).not.toHaveBeenCalled()
  })
})
