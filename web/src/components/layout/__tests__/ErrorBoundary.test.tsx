// @vitest-environment jsdom
/**
 * Unit tests — SH-05: Global Error Boundary
 * Requirement: An unhandled runtime error in any view SHALL be caught and render
 * a recoverable error panel with a "reload this view" action, without crashing
 * the entire application.
 * Priority: MUST
 *
 * Test cases covered:
 *   TC-SH05-01 — child throws → error-boundary-panel visible
 *   TC-SH05-02 — clicking error-boundary-reset → panel gone, normal content visible
 *   TC-SH05-03 — after reset, child throws again → panel shown again
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import React, { useState } from 'react'

// Extend Vitest expect with jest-dom matchers (toBeVisible, toBeInTheDocument, etc.)
expect.extend(jestDomMatchers)
import { ErrorBoundary } from '../ErrorBoundary'

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * A child component that throws when `shouldThrow` is true.
 * Controlled via a ref so the parent can trigger/clear the throw state
 * without re-mounting the boundary.
 */
function ThrowingChild({ shouldThrow }: { shouldThrow: boolean }): React.ReactElement {
  if (shouldThrow) {
    throw new Error('Test render error from ThrowingChild')
  }
  return <div data-testid="normal-content">Normal child content</div>
}

/**
 * Wrapper that lets a test toggle the throw state on the child
 * without resetting the ErrorBoundary.
 */
function ToggleThrowWrapper(): React.ReactElement {
  const [throwing, setThrowing] = useState(false)
  return (
    <div>
      <button data-testid="trigger-throw" onClick={() => setThrowing(true)}>
        Throw
      </button>
      <button data-testid="clear-throw" onClick={() => setThrowing(false)}>
        Clear
      </button>
      <ErrorBoundary>
        <ThrowingChild shouldThrow={throwing} />
      </ErrorBoundary>
    </div>
  )
}

// ── Setup ─────────────────────────────────────────────────────────────────────

// React logs caught errors to console.error during tests — suppress them
// to keep test output clean.  This is expected behaviour from componentDidCatch.
let consoleErrorSpy: ReturnType<typeof vi.spyOn>

beforeEach(() => {
  consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
})

afterEach(() => {
  consoleErrorSpy.mockRestore()
  cleanup()
})

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('SH-05 — ErrorBoundary', () => {
  // TC-SH05-01
  it('TC-SH05-01: shows error-boundary-panel when child throws during render', () => {
    render(
      <ErrorBoundary>
        <ThrowingChild shouldThrow={true} />
      </ErrorBoundary>,
    )

    // VERDICT: Screen shows error-boundary-panel when child throws
    expect(screen.getByTestId('error-boundary-panel')).toBeVisible()
    expect(screen.queryByTestId('normal-content')).not.toBeInTheDocument()
  })

  // TC-SH05-02 (variant with non-throwing state after reset)
  it('TC-SH05-02b: after reset with non-throwing child, normal content is visible', () => {
    // Start with non-throwing child — no error panel
    render(
      <ErrorBoundary>
        <ThrowingChild shouldThrow={false} />
      </ErrorBoundary>,
    )

    // VERDICT: Normal content rendered when child does not throw
    expect(screen.getByTestId('normal-content')).toBeVisible()
    expect(screen.queryByTestId('error-boundary-panel')).not.toBeInTheDocument()
  })

  // TC-SH05-02 (toggle scenario: throw, reset, verify panel is cleared)
  it('TC-SH05-02c: error-boundary-reset clears the error state', () => {
    // Render a wrapper where the throw state is toggled externally
    render(<ToggleThrowWrapper />)

    // Initially no error
    expect(screen.getByTestId('normal-content')).toBeVisible()

    // Trigger throw
    fireEvent.click(screen.getByTestId('trigger-throw'))

    // VERDICT: Screen shows error-boundary-panel after child throws
    expect(screen.getByTestId('error-boundary-panel')).toBeVisible()
    expect(screen.queryByTestId('normal-content')).not.toBeInTheDocument()

    // Click the reset button on the boundary — clear throwing state BEFORE reset
    // so that after reset the child renders without throwing
    fireEvent.click(screen.getByTestId('clear-throw'))
    fireEvent.click(screen.getByTestId('error-boundary-reset'))

    // VERDICT: Screen shows normal-content after error-boundary-reset; panel gone
    expect(screen.queryByTestId('error-boundary-panel')).not.toBeInTheDocument()
    expect(screen.getByTestId('normal-content')).toBeVisible()
  })

  // TC-SH05-03
  it('TC-SH05-03: after reset, a second throw in the same child shows the panel again', () => {
    render(<ToggleThrowWrapper />)

    // First throw cycle
    fireEvent.click(screen.getByTestId('trigger-throw'))
    expect(screen.getByTestId('error-boundary-panel')).toBeVisible()

    // Reset (clear the throw flag first so the child renders after reset)
    fireEvent.click(screen.getByTestId('clear-throw'))
    fireEvent.click(screen.getByTestId('error-boundary-reset'))
    expect(screen.queryByTestId('error-boundary-panel')).not.toBeInTheDocument()

    // Second throw cycle
    fireEvent.click(screen.getByTestId('trigger-throw'))

    // VERDICT: Screen shows error-boundary-panel again after second throw
    expect(screen.getByTestId('error-boundary-panel')).toBeVisible()
    expect(screen.queryByTestId('normal-content')).not.toBeInTheDocument()
  })
})
