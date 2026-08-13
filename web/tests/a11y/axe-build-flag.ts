/** axe-build-flag — GRD-UI-06 §5.3 (synthetic violations)
 *
 *  Helpers for the test-only build flag that injects a synthetic
 *  `role="img"` without `aria-label` on the Task Inbox page (or any
 *  other surface). Not a mock — the page is rebuilt with a debug
 *  component that emits the violation, then axe runs against the real
 *  rendered DOM.
 */

export interface BuildFlagEnv {
  /** When true, the page renders a debug element that emits a specific axe violation. */
  DEBUG_AXE_VIOLATION?: 'missing-aria-label' | 'color-contrast-fail' | 'moderate'
}

export function readBuildFlag(): BuildFlagEnv {
  // Tests can set BPM_TEST_AXE_VIOLATION=... in the env; the page's
  // debug component reads it via this helper.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const env = (globalThis as any).process?.env ?? {}
  return {
    DEBUG_AXE_VIOLATION: env['BPM_TEST_AXE_VIOLATION'] as BuildFlagEnv['DEBUG_AXE_VIOLATION'],
  }
}
