// @vitest-environment node
/**
 * GRD-UI-05: Reporter unit tests — violation redaction and assertRedacted.
 *
 * TC-GR-01: writeViolations() YAML report contains exactly { file, line, patternName } per violation
 * TC-GR-02: writeViolations() YAML report does not contain the matched substring
 * TC-GR-03: assertRedacted() passes for a clean violation array
 * TC-GR-04: assertRedacted() passes for an empty violation array
 * TC-GR-05: assertRedacted() throws when violation carries extra key with /sk-/ credential value
 * TC-GR-06: assertRedacted() throws when violation carries extra key with /password/i credential value
 * TC-GR-07: assertRedacted() throws when violation carries extra key with /token/i credential value
 * TC-GR-08: assertRedacted() throws when violation is missing a required key
 * TC-GR-09: PATTERNS — every entry has name (string), regex (RegExp), appliesTo fields
 * TC-GR-10: PATTERNS — every entry has a non-empty rationale field
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { load } from 'js-yaml'
import { writeViolations, assertRedacted, type Violation } from '../guards/reporter'
import { PATTERNS } from '../guards/forbidlist'

const TEST_RUN_ID = 'unit-grd-ui-05'
const date = new Date().toISOString().slice(0, 10)
const REPORT_FILE = join(process.cwd(), 'tests', 'reports', `report-${date}-${TEST_RUN_ID}.yaml`)

beforeAll(() => {
  process.env.GUARD_RUN_ID = TEST_RUN_ID
})

afterAll(() => {
  delete process.env.GUARD_RUN_ID
  if (existsSync(REPORT_FILE)) {
    rmSync(REPORT_FILE)
  }
})

describe('GRD-UI-05 — writeViolations() output format', () => {
  it('TC-GR-01: YAML report contains exactly { file, line, patternName } per violation — no extra keys', () => {
    const violations: Violation[] = [
      { file: 'web/src/foo.ts', line: 42, patternName: 'msw-import' },
      { file: 'web/src/bar.tsx', line: 7, patternName: 'native-confirm' },
    ]
    writeViolations(violations, ['msw-import', 'native-confirm'], TEST_RUN_ID)

    const raw = readFileSync(REPORT_FILE, 'utf8')
    const parsed = load(raw) as { violations: unknown[] }

    expect(parsed.violations).toHaveLength(2)
    for (const v of parsed.violations as Record<string, unknown>[]) {
      expect(Object.keys(v).sort()).toEqual(['file', 'line', 'patternName'])
    }
  })

  it('TC-GR-02: YAML report does not contain matched source content — only file, line, patternName', () => {
    // Simulate: pattern matched credential in a file; violation carries only the redacted fields.
    const MATCHED_CONTENT = 'sk-live-0123456789abcdef'
    const violations: Violation[] = [
      { file: 'web/src/config.ts', line: 12, patternName: 'credential-leak' },
    ]
    writeViolations(violations, ['credential-leak'], TEST_RUN_ID)

    const raw = readFileSync(REPORT_FILE, 'utf8')
    expect(raw).not.toContain(MATCHED_CONTENT)
    expect(raw).toContain('web/src/config.ts')
    expect(raw).toContain('credential-leak')
  })
})

describe('GRD-UI-05 — assertRedacted()', () => {
  it('TC-GR-03: passes for a clean violation array', () => {
    const violations: Violation[] = [
      { file: 'web/src/foo.ts', line: 1, patternName: 'msw-import' },
    ]
    expect(() => assertRedacted(violations)).not.toThrow()
  })

  it('TC-GR-04: passes for an empty violation array', () => {
    expect(() => assertRedacted([])).not.toThrow()
  })

  it('TC-GR-05: throws when violation carries extra key containing credential matching /sk-/', () => {
    const violations = [
      {
        file: 'web/src/api.ts',
        line: 1,
        patternName: 'cred-pattern',
        matched: 'sk-live-0123456789abcdef',
      },
    ] as unknown as Violation[]
    expect(() => assertRedacted(violations)).toThrow()
  })

  it('TC-GR-06: throws when violation carries extra key containing credential matching /password/i', () => {
    const violations = [
      {
        file: 'web/src/auth.ts',
        line: 3,
        patternName: 'cred-pattern',
        content: 'password=hunter2',
      },
    ] as unknown as Violation[]
    expect(() => assertRedacted(violations)).toThrow()
  })

  it('TC-GR-07: throws when violation carries extra key containing credential matching /token/i', () => {
    const violations = [
      {
        file: 'web/src/config.ts',
        line: 10,
        patternName: 'cred-pattern',
        raw: 'Authorization: Bearer secret-token-abc',
      },
    ] as unknown as Violation[]
    expect(() => assertRedacted(violations)).toThrow()
  })

  it('TC-GR-08: throws when violation is missing the required "file" key', () => {
    const violations = [{ line: 1, patternName: 'test' }] as unknown as Violation[]
    expect(() => assertRedacted(violations)).toThrow(/missing required key/)
  })
})

describe('GRD-UI-05 — PATTERNS array structure', () => {
  it('TC-GR-09: every PATTERNS entry has name (string), regex (RegExp), and appliesTo fields', () => {
    expect(PATTERNS.length).toBeGreaterThan(0)
    for (const p of PATTERNS) {
      expect(typeof p.name, `${p.name}: name must be a string`).toBe('string')
      expect(p.name.length, `${p.name}: name must be non-empty`).toBeGreaterThan(0)
      expect(p.regex, `${p.name}: regex must be a RegExp`).toBeInstanceOf(RegExp)
      expect(['source', 'bundle', 'both'], `${p.name}: appliesTo must be source|bundle|both`).toContain(p.appliesTo)
    }
  })

  it('TC-GR-10: every PATTERNS entry has a non-empty rationale field', () => {
    for (const p of PATTERNS) {
      expect(typeof p.rationale, `${p.name}: rationale must be a string`).toBe('string')
      expect(p.rationale.length, `${p.name}: rationale must be non-empty`).toBeGreaterThan(0)
    }
  })
})
