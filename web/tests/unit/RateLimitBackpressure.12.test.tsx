// @vitest-environment jsdom
/**
 * Unit tests — RND-UI-05 §12.1: error-mode regression suite
 *
 *   TC-RLB-07: unmount during countdown at t=2 with 5s timer -> no onRetry
 *   TC-RLB-08: countdown reaching zero while user navigates away -> no onRetry
 *   TC-RLB-09: multiple zero-ticks still fire exactly one onRetry (firedRef guard)
 *   TC-RLB-10: zero retryAfter is treated as fallback to 60s default
 *   TC-RLB-11: negative retryAfter is treated as fallback to 60s default
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, act } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)
import { RateLimitBackpressure } from '@/components/ui/RateLimitBackpressure'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.useRealTimers()
})

describe('RND-UI-05 §12.1 — error-mode regressions', () => {
  it('TC-RLB-07: §12.1 mode 3 — unmount at t=2 of 5s countdown; no onRetry fires', () => {
    vi.useFakeTimers()
    const onRetry = vi.fn()
    const { unmount } = render(
      <RateLimitBackpressure retryAfter={5} onRetry={onRetry} />,
    )
    act(() => {
      vi.advanceTimersByTime(2000)
    })
    // Component must have ticked down (text was 'Retry in 5s' -> 'Retry in 3s').
    expect(screen.getByTestId('retry-countdown')).toHaveTextContent('Retry in 3s')

    unmount()
    act(() => {
      // 10s of fake time after unmount — interval was cleared in cleanup.
      vi.advanceTimersByTime(10_000)
    })
    expect(onRetry).not.toHaveBeenCalled()
  })

  it('TC-RLB-08: §12.1 mode 4 — countdown at zero during unmount; cleanup wins', () => {
    vi.useFakeTimers()
    const onRetry = vi.fn()
    const { unmount } = render(
      <RateLimitBackpressure retryAfter={2} onRetry={onRetry} />,
    )
    act(() => {
      vi.advanceTimersByTime(1000)
    })
    unmount() // Before the 2nd tick — no fire.
    act(() => {
      vi.advanceTimersByTime(5_000)
    })
    expect(onRetry).not.toHaveBeenCalled()
  })

  it('TC-RLB-09: §12.1 mode 5 — two ticks both observing secondsRemaining=0 fire onRetry exactly once', () => {
    vi.useFakeTimers()
    const onRetry = vi.fn()
    render(<RateLimitBackpressure retryAfter={2} onRetry={onRetry} />)
    act(() => {
      vi.advanceTimersByTime(2_000)
    })
    // Force a second interval tick to verify the firedRef guard.
    act(() => {
      vi.advanceTimersByTime(1_000)
    })
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('TC-RLB-10: §12.1 mode 6 — retryAfter=0 falls back to 60s default', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    render(<RateLimitBackpressure retryAfter={0} onRetry={() => undefined} />)
    expect(screen.getByTestId('retry-countdown')).toHaveTextContent('Retry in 60s')
    expect(warnSpy).toHaveBeenCalled()
  })

  it('TC-RLB-11: §12.1 mode 6 — negative retryAfter falls back to 60s default', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    render(<RateLimitBackpressure retryAfter={-5} onRetry={() => undefined} />)
    expect(screen.getByTestId('retry-countdown')).toHaveTextContent('Retry in 60s')
    expect(warnSpy).toHaveBeenCalled()
  })
})
