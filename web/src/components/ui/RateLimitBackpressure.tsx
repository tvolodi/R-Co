/** RateLimitBackpressure — RND-UI-05
 *
 *  Renders a 429 backpressure surface with a one-per-second countdown that
 *  announces the remaining seconds via aria-live="polite", and fires the
 *  caller-supplied onRetry() EXACTLY ONCE when the countdown reaches zero.
 *
 *  Invariants (see src/design/pw13-pw16-batch19-20260813.md §1.1, §12.1):
 *   - The setInterval is cleared in the useEffect cleanup; unmount before
 *     zero NEVER fires onRetry (mode 3, mode 4).
 *   - The firedRef flag guarantees exactly one onRetry even under React
 *     strict-mode double-invocation or two ticks both observing zero (mode 5).
 *   - A non-finite Retry-After (HTTP-date, malformed) falls back to a
 *     60-second default (mode 6) and emits a console.warn.
 *   - The component is purely presentational; the caller owns the query
 *     lifecycle and binds onRetry to refetch().
 */

import { useEffect, useRef, useState } from 'react'

export interface RateLimitBackpressureProps {
  /** The numeric Retry-After value, in seconds, taken from the 429 response header. */
  retryAfter: number
  /** Bound the displayed countdown — defaults to Math.ceil(retryAfter). */
  initialSeconds?: number
  /** Called exactly once when the countdown reaches zero. */
  onRetry: () => void
  /** Optional: a label explaining what surface is being rate-limited. */
  surfaceLabel?: string
}

const FALLBACK_SECONDS = 60

function sanitizeSeconds(raw: number): number {
  if (!Number.isFinite(raw) || raw <= 0) return FALLBACK_SECONDS
  return Math.ceil(raw)
}

export function RateLimitBackpressure(props: RateLimitBackpressureProps): React.ReactElement {
  const { retryAfter, onRetry, surfaceLabel } = props
  const fallbackInitial = sanitizeSeconds(retryAfter)

  if (!Number.isFinite(retryAfter) || retryAfter <= 0) {
    // §12.1 mode 6 — non-integer/HTTP-date Retry-After
    console.warn(
      `[RateLimitBackpressure] Retry-After header was non-finite (${String(retryAfter)}); ` +
        `falling back to ${FALLBACK_SECONDS}s default.`,
    )
  }

  const [secondsRemaining, setSecondsRemaining] = useState<number>(fallbackInitial)
  const firedRef = useRef<boolean>(false)

  useEffect(() => {
    if (secondsRemaining <= 0) return
    const intervalId = window.setInterval(() => {
      setSecondsRemaining((prev) => {
        if (prev <= 1) {
          // The actual fire happens in a separate effect below so that the
          // firedRef guard sees the zero value but the interval is already
          // cleared (no second tick can fire it).
          return 0
        }
        return prev - 1
      })
    }, 1000)
    return () => {
      window.clearInterval(intervalId)
    }
  }, [secondsRemaining])

  useEffect(() => {
    if (secondsRemaining !== 0) return
    if (firedRef.current) return
    firedRef.current = true
    onRetry()
  }, [secondsRemaining, onRetry])

  return (
    <div
      data-testid="rate-limit-backpressure"
      role="status"
      aria-live="polite"
      aria-atomic="true"
      style={{
        padding: '1.5rem',
        border: '1px solid #fde68a',
        background: '#fffbeb',
        borderRadius: '6px',
        color: '#92400e',
      }}
    >
      <p style={{ marginBottom: '.75rem', fontWeight: 500 }}>
        {surfaceLabel
          ? `Rate limit reached while loading ${surfaceLabel}.`
          : 'Rate limit reached.'}
      </p>
      <p
        data-testid="retry-countdown"
        style={{ margin: 0, fontSize: '.95rem' }}
      >
        {secondsRemaining > 0
          ? `Retry in ${secondsRemaining}s`
          : 'Retrying…'}
      </p>
      <button
        type="button"
        data-testid="rate-limit-retry-now"
        onClick={() => {
          if (firedRef.current) return
          firedRef.current = true
          onRetry()
        }}
        style={{
          marginTop: '.75rem',
          padding: '.4rem .9rem',
          border: '1px solid #d97706',
          borderRadius: '4px',
          background: '#fff',
          color: '#92400e',
          cursor: 'pointer',
          fontSize: '.85rem',
        }}
      >
        Retry now
      </button>
    </div>
  )
}
