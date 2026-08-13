// @vitest-environment jsdom
/**
 * Unit tests — RND-UI-03: FetchError fetch-failure component
 *
 *   TC-FE-01: role="alert" is present
 *   TC-FE-02: onRetry is called exactly once when Retry button is clicked
 *   TC-FE-03: component renders without crashing (smoke test)
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)
import { FetchError } from '@/components/ui/FetchError'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('RND-UI-03 — FetchError', () => {
  it('TC-FE-01: role="alert" is present', () => {
    render(<FetchError onRetry={vi.fn()} />)
    expect(screen.getByRole('alert')).toBeVisible()
  })

  it('TC-FE-02: onRetry is called exactly once when Retry button is clicked', () => {
    const onRetry = vi.fn()
    render(<FetchError onRetry={onRetry} />)
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('TC-FE-03: component renders without crashing (smoke test)', () => {
    const { container } = render(<FetchError onRetry={vi.fn()} />)
    expect(container.firstChild).not.toBeNull()
  })
})
