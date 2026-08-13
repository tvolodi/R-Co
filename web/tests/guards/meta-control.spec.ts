// @vitest-environment node
/**
 * GRD-UI-04: Meta-control — two-sided fixture test for every pattern.
 *
 * For each pattern in PATTERNS:
 *   - offender fixture must exist and the regex must match its content
 *   - bystander fixture must exist and the regex must NOT match its content
 *
 * Also enforces the single-source invariant: no RegExp literals may appear
 * in source-scan.spec.ts or bundle-scan.spec.ts.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { PATTERNS } from './forbidlist'

const FIXTURES_DIR = join(__dirname, 'fixtures')

describe('meta-control: fixture coverage', () => {
  for (const pattern of PATTERNS) {
    const offenderPath = join(FIXTURES_DIR, 'offender', `${pattern.name}.txt`)
    const bystanderPath = join(FIXTURES_DIR, 'bystander', `${pattern.name}.txt`)

    describe(pattern.name, () => {
      it('offender fixture exists', () => {
        expect(() => readFileSync(offenderPath)).not.toThrow()
      })

      it('bystander fixture exists', () => {
        expect(() => readFileSync(bystanderPath)).not.toThrow()
      })

      it('regex matches offender', () => {
        const content = readFileSync(offenderPath, 'utf8')
        pattern.regex.lastIndex = 0
        expect(pattern.regex.test(content)).toBe(true)
      })

      it('regex does NOT match bystander', () => {
        const content = readFileSync(bystanderPath, 'utf8')
        pattern.regex.lastIndex = 0
        expect(pattern.regex.test(content)).toBe(false)
      })
    })
  }
})

describe('meta-control: single-source regex invariant', () => {
  const scanFiles = [
    join(__dirname, 'source-scan.spec.ts'),
    join(__dirname, 'bundle-scan.spec.ts'),
  ]

  for (const filePath of scanFiles) {
    const fileName = filePath.split(/[/\\]/).pop() ?? filePath

    it(`${fileName} contains no RegExp literals`, () => {
      const source = readFileSync(filePath, 'utf8')
      // Detects /pattern/ regex literals — skip the shebang comment line
      const lines = source.split('\n')
      for (const line of lines) {
        const trimmed = line.trim()
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue
        // Match a regex literal: / followed by at least one non-space char, closing /
        expect(trimmed).not.toMatch(/(?<![a-zA-Z0-9_$])\/.+\/[gimsuy]*(?=[^a-zA-Z0-9_$]|$)/)
      }
    })

    it(`${fileName} contains no new RegExp(`, () => {
      const source = readFileSync(filePath, 'utf8')
      expect(source).not.toContain('new RegExp(')
    })
  }
})
