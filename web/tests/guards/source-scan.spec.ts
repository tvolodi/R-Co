// @vitest-environment node
/**
 * GRD-UI-02: Static source scan — web/src/** /*.{ts,tsx,css}
 *
 * Applies every source-applicable pattern from PATTERNS to all files under
 * web/src/. Violations are written to tests/reports/. Fails if any are found.
 * Timeout: 30 000 ms.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import fg from 'fast-glob'
import { PATTERNS } from './forbidlist'
import { writeViolations, assertRedacted, type Violation } from './reporter'

const WEB_PREFIX = 'web/'

function toForwardSlash(p: string): string {
  return p.split('\\').join('/')
}

function normToWsPath(relFile: string): string {
  return WEB_PREFIX + toForwardSlash(relFile)
}

function isAllowed(filePath: string, allowedPaths: string[]): boolean {
  const lc = filePath.toLowerCase()
  return allowedPaths.some(a => lc.startsWith(a.toLowerCase()))
}

function findViolationInFile(
  content: string,
  lines: string[],
  pattern: { name: string; regex: RegExp; allowedPaths: string[] },
  filePath: string,
): Violation | null {
  // Test whole-file content — required for multi-line patterns (e.g. missing-query-state-boundary)
  pattern.regex.lastIndex = 0
  if (!pattern.regex.test(content)) return null

  // Violation confirmed — find the first line that individually matches for accurate line number
  for (let i = 0; i < lines.length; i++) {
    pattern.regex.lastIndex = 0
    if (pattern.regex.test(lines[i])) {
      return { file: filePath, line: i + 1, patternName: pattern.name }
    }
  }

  // Multi-line pattern: no single line matches — report line 1
  return { file: filePath, line: 1, patternName: pattern.name }
}

describe('source-scan', () => {
  it(
    'web/src/**/*.{ts,tsx,css} has no guard violations',
    async () => {
      const sourcePatterns = PATTERNS.filter(p => p.appliesTo === 'source' || p.appliesTo === 'both')
      const evaluatedPatterns = sourcePatterns.map(p => p.name)

      // Glob relative to web/ directory
      const files = await fg('src/**/*.{ts,tsx,css}', { cwd: join(__dirname, '..', '..') })

      const violations: Violation[] = []

      for (const relFile of files) {
        const wsPath = normToWsPath(relFile)
        const absPath = join(__dirname, '..', '..', relFile)
        const content = readFileSync(absPath, 'utf8')
        const lines = content.split('\n')

        for (const pattern of sourcePatterns) {
          if (isAllowed(wsPath, pattern.allowedPaths)) continue

          const violation = findViolationInFile(content, lines, pattern, wsPath)
          if (violation) {
            violations.push(violation)
          }
        }
      }

      const ts = new Date().toISOString().slice(0, 19).split(':').join('-')
      const runId = process.env.GUARD_RUN_ID ?? ts
      assertRedacted(violations)
      writeViolations(violations, evaluatedPatterns, runId)

      if (violations.length > 0) {
        const summary = violations
          .slice(0, 10)
          .map(v => `  ${v.patternName} @ ${v.file}:${v.line}`)
          .join('\n')
        const more = violations.length > 10 ? `\n  ... and ${violations.length - 10} more` : ''
        expect.fail(
          `Source scan found ${violations.length} violation(s):\n${summary}${more}`,
        )
      }

      expect(violations).toHaveLength(0)
    },
    30_000,
  )
})
