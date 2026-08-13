// @vitest-environment jsdom
/**
 * Unit tests — RND-UI-05: RateLimitBackpressure
 *
 *   TC-RLB-01: countdown decreases by 1 each second (fake timers)
 *   TC-RLB-02: wrapper has role=status and aria-live=polite
 *   TC-RLB-03: onRetry fires exactly once at zero
 *   TC-RLB-04: unmount during countdown: cleanup clears interval; no fire
 *   TC-RLB-05: multiple zero-ticks: still exactly one onRetry
 *   TC-RLB-06: non-finite Retry-After falls back to 60s
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)
import { RateLimitBackpressure } from '@/components/ui/RateLimitBackpressure'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.useRealTimers()
})

describe('RND-UI-05 — RateLimitBackpressure', () => {
  it('TC-RLB-02: wrapper has role="status", aria-live="polite", aria-atomic="true"', () => {
    render(<RateLimitBackpressure retryAfter={30} onRetry={() => undefined} />)
    const wrapper = screen.getByTestId('rate-limit-backpressure')
    expect(wrapper).toHaveAttribute('role', 'status')
    expect(wrapper).toHaveAttribute('aria-live', 'polite')
    expect(wrapper).toHaveAttribute('aria-atomic', 'true')
  })

  it('TC-RLB-01: countdown text decreases by one each tick', () => {
    vi.useFakeTimers()
    render(<RateLimitBackpressure retryAfter={5} onRetry={() => undefined} />)
    expect(screen.getByTestId('retry-countdown')).toHaveTextContent('Retry in 5s')
    act(() => {
      vi.advanceTimersByTime(1000)
    })
    expect(screen.getByTestId('retry-countdown')).toHaveTextContent('Retry in 4s')
    act(() => {
      vi.advanceTimersByTime(2000)
    })
    expect(screen.getByTestId('retry-countdown')).toHaveTextContent('Retry in 2s')
  })

  it('TC-RLB-03: onRetry fires exactly once when countdown reaches zero', () => {
    vi.useFakeTimers()
    const onRetry = vi.fn()
    render(<RateLimitBackpressure retryAfter={3} onRetry={onRetry} />)
    act(() => {
      vi.advanceTimersByTime(3000)
    })
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('TC-RLB-04: unmount during countdown clears interval; onRetry not called', () => {
    vi.useFakeTimers()
    const onRetry = vi.fn()
    const { unmount } = render(<RateLimitBackpressure retryAfter={5} onRetry={onRetry} />)
    act(() => {
      vi.advanceTimersByTime(2000)
    })
    unmount()
    act(() => {
      vi.advanceTimersByTime(5000)
    })
    expect(onRetry).not.toHaveBeenCalled()
  })

  it('TC-RLB-05: clicking Retry-now fires onRetry exactly once even if countdown is also firing', () => {
    vi.useFakeTimers()
    const onRetry = vi.fn()
    render(<RateLimitBackpressure retryAfter={3} onRetry={onRetry} />)
    fireEvent.click(screen.getByTestId('rate-limit-retry-now'))
    act(() => {
      vi.advanceTimersByTime(3000)
    })
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('TC-RLB-06: non-finite Retry-After falls back to 60s default', () => {
    // Number('Wed, 21 Oct 2026 07:28:00 GMT') -> NaN
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    render(<RateLimitBackpressure retryAfter={Number('not-a-date')} onRetry={() => undefined} />)
    expect(screen.getByTestId('retry-countdown')).toHaveTextContent('Retry in 60s')
    expect(warnSpy).toHaveBeenCalled()
  })

  it('TC-RLB-07: surfaceLabel appears in the rendered alert text', () => {
    render(
      <RateLimitBackpressure
        retryAfter={10}
        onRetry={() => undefined}
        surfaceLabel="Task Inbox"
      />,
    )
    expect(screen.getByText(/Task Inbox/)).toBeVisible()
  })
})
