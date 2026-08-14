/** a11yConfig — GRD-UI-06 §3.2
 *
 *  Axe configuration. color-contrast is INTENTIONALLY NOT in the disabled
 *  rules map — GRD-UI-06 AC-2 requires it. The unit test
 *  (web/tests/unit/a11yConfig.test.ts) asserts this on every CI run.
 */

import type { Spec } from 'axe-core'

export interface AxeRulesConfig {
  rules: Record<string, { enabled: boolean }>
}

export const a11yConfig: AxeRulesConfig = {
  rules: {
    // Explicitly empty: no rules are disabled. The unit test asserts that
    // `color-contrast` is NOT added here. Future contributors must opt
    // into rule-by-rule disabling with a justification comment.
  },
}

export const a11yTags: string[] = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']

export const a11yRuleTimeoutMs: number = 30_000

// Re-export `Spec` so callers can type their custom rules without importing
// axe-core directly. Tests that don't depend on axe-core (unit tests of
// fixtures) can ignore this type alias.
export type { Spec as AxeSpec }
