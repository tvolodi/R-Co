/** ariaHints — GRD-UI-07
 *
 *  Pure helpers for generating the `${fieldName}-hint` and
 *  `${fieldName}-error` IDs used by FieldFactory's ARIA wiring. No React
 *  deps so it can be unit-tested in isolation.
 */

/** Hint node id for a given field name. */
export function hintId(fieldName: string): string {
  return `${fieldName}-hint`
}

/** Error node id for a given field name. */
export function errorId(fieldName: string): string {
  return `${fieldName}-error`
}

/**
 * Join multiple hint ids into a single space-separated `aria-describedby`
 * value (WAI-ARIA 1.2 §6.6.3). The first hint must be the primary
 * description; constraint hints follow in order.
 */
export function joinHintIds(hints: Array<string | null | undefined>): string | undefined {
  const filtered = hints.filter((h): h is string => Boolean(h) && typeof h === 'string')
  if (filtered.length === 0) return undefined
  return filtered.join(' ')
}
