// @vitest-environment jsdom
/**
 * Unit tests — GRD-UI-07 §4.2: aria-validator dangling-reference detector
 *
 *   TC-AV-01: empty DOM -> []
 *   TC-AV-02: aria-invalid without aria-errormessage -> dangling (no target)
 *   TC-AV-03: aria-invalid + aria-errormessage="missing" -> dangling
 *   TC-AV-04: aria-invalid + valid aria-errormessage target -> ok (not in list)
 *   TC-AV-05: multiple dangling references returned in order
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { detectDanglingAriaReferences } from '../a11y/aria-validator'

beforeEach(() => {
  document.body.innerHTML = ''
})

describe('aria-validator — dangling-reference detector', () => {
  it('TC-AV-01: empty DOM returns empty list', () => {
    expect(detectDanglingAriaReferences(document.body)).toEqual([])
  })

  it('TC-AV-02: aria-invalid without aria-errormessage is dangling', () => {
    document.body.innerHTML = `
      <div data-field-key="x">
        <input id="x" aria-invalid="true" />
      </div>
    `
    const result = detectDanglingAriaReferences(document.body)
    expect(result).toHaveLength(1)
    expect(result[0]?.fieldKey).toBe('x')
    expect(result[0]?.ariaErrorMessage).toBe('')
  })

  it('TC-AV-03: aria-invalid + aria-errormessage referencing missing id is dangling', () => {
    document.body.innerHTML = `
      <div data-field-key="x">
        <input id="x" aria-invalid="true" aria-errormessage="x-error" />
      </div>
    `
    const result = detectDanglingAriaReferences(document.body)
    expect(result).toHaveLength(1)
    expect(result[0]?.ariaErrorMessage).toBe('x-error')
  })

  it('TC-AV-04: aria-invalid + valid aria-errormessage target is NOT dangling', () => {
    document.body.innerHTML = `
      <div data-field-key="x">
        <input id="x" aria-invalid="true" aria-errormessage="x-error" />
        <div id="x-error" role="alert">x is bad</div>
      </div>
    `
    expect(detectDanglingAriaReferences(document.body)).toEqual([])
  })

  it('TC-AV-05: returns multiple dangling references in order', () => {
    document.body.innerHTML = `
      <input id="a" aria-invalid="true" aria-errormessage="a-error" />
      <input id="b" aria-invalid="true" aria-errormessage="b-error" />
      <div id="b-error"></div>
    `
    const result = detectDanglingAriaReferences(document.body)
    expect(result).toHaveLength(1)
    expect(result[0]?.fieldKey).toBe('a')
  })
})