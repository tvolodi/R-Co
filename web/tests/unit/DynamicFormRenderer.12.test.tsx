// @vitest-environment jsdom
/**
 * Unit tests — GRD-UI-07 §12.4 mode 3: error-mode regression suite
 *
 *   TC-DFR-04: aria-busy cleared in finally block when onSubmit rejects
 *   TC-DFR-05: aria-busy cleared in finally block when onSubmit rejects synchronously
 *   TC-DFR-06: aria-busy cleared in finally block when onSubmit returns a rejected promise
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

describe('DynamicFormRenderer §12.4 mode 3 — finally invariants', () => {
  it('TC-DFR-04: aria-busy is false after a rejecting async onSubmit', async () => {
    const onSubmit = vi.fn(async () => {
      throw new Error('boom')
    })
    const { form } = renderForm({ onSubmit })
    fireEvent.input(screen.getByLabelText(/Title/), { target: { value: 'x' } })
    fireEvent.click(screen.getByTestId('task-submit-btn'))
    await waitFor(() => expect(form).toHaveAttribute('aria-busy', 'true'))
    // Drain the microtask queue.
    await new Promise((r) => setTimeout(r, 10))
    await waitFor(() => expect(form).toHaveAttribute('aria-busy', 'false'))
  })

  it('TC-DFR-05: aria-busy is false after a synchronous onSubmit throw', async () => {
    const onSubmit = vi.fn(() => {
      throw new Error('sync boom')
    })
    const { form } = renderForm({ onSubmit })
    fireEvent.input(screen.getByLabelText(/Title/), { target: { value: 'x' } })
    fireEvent.click(screen.getByTestId('task-submit-btn'))
    await waitFor(() => expect(onSubmit).toHaveBeenCalled())
    // Even on synchronous throw, the finally block runs.
    await new Promise((r) => setTimeout(r, 10))
    expect(form).toHaveAttribute('aria-busy', 'false')
  })

  it('TC-DFR-06: aria-busy is false after a Promise.reject from onSubmit', async () => {
    const onSubmit = vi.fn(() => Promise.reject(new Error('reject')))
    const { form } = renderForm({ onSubmit })
    fireEvent.input(screen.getByLabelText(/Title/), { target: { value: 'x' } })
    fireEvent.click(screen.getByTestId('task-submit-btn'))
    await waitFor(() => expect(form).toHaveAttribute('aria-busy', 'true'))
    // Drain the rejected promise's microtask.
    await new Promise((r) => setTimeout(r, 10))
    await waitFor(() => expect(form).toHaveAttribute('aria-busy', 'false'))
  })
})
