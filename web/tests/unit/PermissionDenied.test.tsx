// @vitest-environment jsdom
/**
 * Unit tests — RND-UI-04: PermissionDenied permission surface (leak-free)
 *
 *   TC-PD-01: fixed copy text is present exactly
 *   TC-PD-02: Task Inbox link present
 *   TC-PD-03: no HTTP status numbers in rendered text
 *   TC-PD-04: no UUID-shaped strings in rendered text
 *   TC-PD-05: no numbers matching /40[13]/ in rendered text
 */

import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import React from 'react'
expect.extend(jestDomMatchers)
import { PermissionDenied } from '@/components/ui/PermissionDenied'

afterEach(cleanup)

describe('RND-UI-04 — PermissionDenied', () => {
  it('TC-PD-01: renders fixed copy text exactly', () => {
    render(<MemoryRouter><PermissionDenied /></MemoryRouter>)
    expect(
      screen.getByText('You do not have access to this area. Contact your tenant administrator.'),
    ).toBeVisible()
  })

  it('TC-PD-02: Task Inbox link is present', () => {
    render(<MemoryRouter><PermissionDenied /></MemoryRouter>)
    expect(screen.getByRole('link', { name: 'My Tasks' })).toBeVisible()
  })

  it('TC-PD-03: no HTTP status numbers appear in rendered text', () => {
    const { container } = render(<MemoryRouter><PermissionDenied /></MemoryRouter>)
    const text = container.textContent ?? ''
    expect(text).not.toMatch(/\b(400|401|403|404|500|503)\b/)
  })

  it('TC-PD-04: no UUID-shaped strings appear in rendered text', () => {
    const { container } = render(<MemoryRouter><PermissionDenied /></MemoryRouter>)
    const text = container.textContent ?? ''
    expect(text).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)
  })

  it('TC-PD-05: no numbers matching /40[13]/ appear in rendered text', () => {
    const { container } = render(<MemoryRouter><PermissionDenied /></MemoryRouter>)
    const text = container.textContent ?? ''
    expect(text).not.toMatch(/40[13]/)
  })
})
