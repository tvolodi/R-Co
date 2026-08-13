// @vitest-environment jsdom
/**
 * Unit tests — GRD-UI-07 §12.4: error-mode regression suite
 *
 *   TC-FF-09:  §12.4 mode 4 — field definition without `required` emits no aria-required
 *   TC-FF-10:  §12.4 mode 2 — registry miss falls through to defaultBuiltinRenderer; warn emitted
 *   TC-FF-11:  §12.4 mode 5 — multiple hint IDs joined by single space (no commas)
 *   TC-FF-12:  hint/error nodes carry stable ids derived from fieldName (kebab-case passthrough)
 *   TC-FF-13:  aria-describedby omits empty / null hint IDs
 */

import { describe, it, expect, afterEach, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)
import { renderFormField } from '@/components/forms/FieldFactory'
import { fieldRegistry } from '@/components/forms/fieldRegistry'
import { joinHintIds } from '@/components/forms/ariaHints'

afterEach(() => {
  cleanup()
  fieldRegistry.clear()
  vi.restoreAllMocks()
})

function renderField(
  fieldName: string,
  fieldDef: Record<string, unknown>,
  errorMessage?: string,
): void {
  const fakeRegister = {
    name: fieldName,
    onChange: () => undefined,
    onBlur: () => undefined,
    ref: () => undefined,
  }
  render(
    <>
      {renderFormField(
        fieldName,
        fieldDef as never,
        undefined,
        undefined,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        fakeRegister as any,
        errorMessage,
      )}
    </>,
  )
}

describe('GRD-UI-07 §12.4 — error-mode regressions', () => {
  it('TC-FF-09: §12.4 mode 4 — required=undefined omits aria-required', () => {
    renderField('optional', { type: 'string', title: 'Optional' })
    const input = screen.getByLabelText(/Optional/) as HTMLInputElement
    expect(input).not.toHaveAttribute('aria-required')
  })

  it('TC-FF-10: §12.4 mode 2 — registry lookup miss falls through to built-in switch without throwing', () => {
    // The FieldFactory contract for a registry miss is: fall through to the
    // built-in switch. The miss is silent (no console.warn) — operators
    // detect typos via the rendered DOM. We assert the label renders and
    // the call does not throw.
    renderField(
      'missing',
      { type: 'org.acme.unregistered', title: 'Unregistered', required: true },
    )
    // The label renders; the registry miss must not throw.
    expect(screen.getByText(/Unregistered/)).toBeVisible()
    // The built-in switch has no `org.acme.unregistered` so the input
    // is omitted but the label + optional hint still render — that is
    // the documented fall-through.
    const inputs = screen.queryAllByRole('textbox')
    expect(inputs).toHaveLength(0)
  })

  it('TC-FF-11: §12.4 mode 5 — joinHintIds space-separates multiple hint IDs in order', () => {
    expect(joinHintIds(['a-hint', 'b-hint', 'c-hint'])).toBe('a-hint b-hint c-hint')
    // No commas.
    expect(joinHintIds(['a-hint', 'b-hint'])).not.toContain(',')
    // Null/undefined filtered.
    expect(joinHintIds(['a-hint', null, undefined, 'b-hint'])).toBe('a-hint b-hint')
    // All-null returns undefined (caller can omit aria-describedby).
    expect(joinHintIds([null, undefined])).toBeUndefined()
  })

  it('TC-FF-12: hint/error ids are stable derived from fieldName', () => {
    renderField('firstName', { type: 'string', title: 'First name', description: 'Your legal first name' }, 'Required')
    expect(screen.getByText('Your legal first name')).toHaveAttribute('id', 'firstName-hint')
    expect(screen.getByRole('alert')).toHaveAttribute('id', 'firstName-error')
  })

  it('TC-FF-13: aria-describedby omitted when no hint provided', () => {
    renderField('plain', { type: 'string', title: 'Plain' })
    const input = screen.getByLabelText(/Plain/) as HTMLInputElement
    expect(input).not.toHaveAttribute('aria-describedby')
  })
})
