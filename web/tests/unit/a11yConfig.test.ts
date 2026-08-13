/**
 * Unit tests — GRD-UI-06 §3.2: a11yConfig
 *
 *   TC-AC-01: a11yConfig has no disabled rules
 *   TC-AC-02: tags include wcag2a/2aa/21a/21aa
 *   TC-AC-03: 30s rule timeout
 */

import { describe, it, expect } from 'vitest'
import { a11yConfig, a11yTags, a11yRuleTimeoutMs } from '../a11y/a11yConfig'

describe('a11yConfig — axe baseline config', () => {
  it('TC-AC-01: a11yConfig has no disabled rules', () => {
    // a11yConfig.rules is an empty object — no rules disabled.
    expect(Object.keys(a11yConfig.rules).length).toBe(0)
    // Explicitly verify color-contrast is NOT disabled.
    expect('color-contrast' in a11yConfig.rules).toBe(false)
  })

  it('TC-AC-02: tags include the WCAG 2.1 A + AA tag set', () => {
    expect(a11yTags).toEqual(
      expect.arrayContaining(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']),
    )
  })

  it('TC-AC-03: rule timeout is 30 seconds', () => {
    expect(a11yRuleTimeoutMs).toBe(30_000)
  })
})