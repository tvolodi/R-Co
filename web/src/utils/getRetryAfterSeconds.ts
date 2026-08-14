/** getRetryAfterSeconds — RND-UI-05 helper
 *
 *  Reads the parsed `Retry-After` value from an ApiError-shaped object and
 *  returns it as a number (or undefined when missing / non-finite). Pages
 *  pipe this into the QueryStateBoundary's `rateLimitRetryAfter` prop.
 *
 *  Accepts any error-like object (Error | ApiError | null). The helper
 *  uses a loose lookup so that TanStack's `useQuery().error` (typed
 *  `Error | null`) and ApiError (`{ details?: { retryAfter? } }`) are
 *  both acceptable.
 */

export function getRetryAfterSeconds(
  error: unknown,
): number | undefined {
  if (!error || typeof error !== 'object') return undefined
  const e = error as { details?: { retryAfter?: string | number | null | undefined } }
  const raw = e.details?.retryAfter
  if (raw == null) return undefined
  const n = Number(raw)
  if (!Number.isFinite(n) || n <= 0) return undefined
  return n
}
