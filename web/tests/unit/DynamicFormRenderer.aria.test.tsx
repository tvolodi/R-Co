// @vitest-environment jsdom
/**
 * Unit tests — GRD-UI-07 + RND-UI-06: DynamicFormRenderer
 *
 *   TC-DFR-01: idle form has aria-busy="false"
 *   TC-DFR-02: while saving, aria-busy="true" toggles
 *   TC-DFR-03: aria-busy clears in finally even on throw
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)
import { DynamicFormRenderer } from '@/components/forms/DynamicFormRenderer'

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

const formSchema = {
  type: 'object',
  required: ['title'],
  properties: {
    title: { type: 'string', title: 'Title', minLength: 1 },
  },
} as unknown as Record<string, unknown>

function renderForm({
  onSubmit,
}: {
  onSubmit: (data: Record<string, unknown>) => Promise<void> | void
}): { form: HTMLFormElement } {
  function Wrapper(): React.ReactElement {
    return (
      <DynamicFormRenderer
        formSchema={formSchema}
        onSubmit={onSubmit}
        submitLabel="Submit"
      />
    )
  }
  render(<Wrapper />)
  return {
    form: screen.getByTestId('task-form') as HTMLFormElement,
  }
}

describe('DynamicFormRenderer — ARIA + submit lifecycle', () => {
  it('TC-DFR-01: idle form has aria-busy="false"', () => {
    const { form } = renderForm({ onSubmit: () => undefined })
    expect(form).toHaveAttribute('aria-busy', 'false')
  })

  it('TC-DFR-02: while saving, aria-busy flips to "true" and back to "false"', async () => {
    let resolveFn!: (value: void | PromiseLike<void>) => void
    const onSubmit = vi.fn(() => new Promise<void>((r) => (resolveFn = r)))
    const { form } = renderForm({ onSubmit })
    fireEvent.input(screen.getByLabelText(/Title/), { target: { value: 'x' } })
    fireEvent.click(screen.getByTestId('task-submit-btn'))
    await waitFor(() => expect(form).toHaveAttribute('aria-busy', 'true'))
    resolveFn()
    await waitFor(() => expect(form).toHaveAttribute('aria-busy', 'false'))
  })

  it('TC-DFR-03: aria-busy clears back to "false" when onSubmit throws', async () => {
    const onSubmit = vi.fn(async () => {
      throw new Error('boom')
    })
    const { form } = renderForm({ onSubmit })
    fireEvent.input(screen.getByLabelText(/Title/), { target: { value: 'x' } })
    fireEvent.click(screen.getByTestId('task-submit-btn'))
    await waitFor(() => expect(onSubmit).toHaveBeenCalled())
    await new Promise((r) => setTimeout(r, 0))
    expect(form).toHaveAttribute('aria-busy', 'false')
  })
})