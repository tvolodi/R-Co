// @vitest-environment jsdom
/**
 * Unit tests — RND-UI-02: SkeletonLayout loading skeleton
 *
 *   TC-SK-01: aria-busy="true" present unconditionally
 *   TC-SK-02: default rowCount=5 renders 5 rows
 *   TC-SK-03: custom rowCount is respected
 *   TC-SK-04: column widths match widthPercent values
 */

import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)
import { SkeletonLayout } from '@/components/ui/SkeletonLayout'

const DEFAULT_COLS = [
  { widthPercent: 20 },
  { widthPercent: 35 },
  { widthPercent: 25 },
  { widthPercent: 20 },
]

afterEach(cleanup)

describe('RND-UI-02 — SkeletonLayout', () => {
  it('TC-SK-01: aria-busy="true" is present unconditionally', () => {
    const { container } = render(<SkeletonLayout columns={DEFAULT_COLS} />)
    expect(container.querySelector('[aria-busy="true"]')).not.toBeNull()
  })

  it('TC-SK-02: default rowCount=5 renders exactly 5 rows', () => {
    const { container } = render(<SkeletonLayout columns={DEFAULT_COLS} />)
    const wrapper = container.querySelector('[aria-busy="true"]')!
    expect(wrapper.children).toHaveLength(5)
  })

  it('TC-SK-03: custom rowCount is respected', () => {
    const { container } = render(<SkeletonLayout columns={DEFAULT_COLS} rowCount={3} />)
    const wrapper = container.querySelector('[aria-busy="true"]')!
    expect(wrapper.children).toHaveLength(3)
  })

  it('TC-SK-04: column widths match widthPercent values', () => {
    const cols = [{ widthPercent: 40 }, { widthPercent: 60 }]
    const { container } = render(<SkeletonLayout columns={cols} rowCount={1} />)
    const row = container.querySelector('[aria-busy="true"]')!.children[0]
    const cells = Array.from(row.children) as HTMLElement[]
    expect(cells[0].style.width).toBe('40%')
    expect(cells[1].style.width).toBe('60%')
  })
})
