// @vitest-environment node
/**
 * GRD-UI-03: Bundle scan — scan dist/assets/*.js after a clean vite build.
 *
 * Phase 1: Clean web/dist
 * Phase 2: Run npm run build (cwd: web/)
 * Phase 3: Discover dist/assets/*.js — fail if none found
 * Phase 4: Apply bundle-applicable patterns; fail if any violations found
 * Timeout: 180 000 ms.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { execSync } from 'node:child_process'
import fg from 'fast-glob'
import { PATTERNS } from './forbidlist'
import { writeViolations, assertRedacted, type Violation } from './reporter'

const WEB_DIR = join(__dirname, '..', '..')
const DIST_DIR = join(WEB_DIR, 'dist')

function isAllowed(filePath: string, allowedPaths: string[]): boolean {
  const lc = filePath.toLowerCase()
  return allowedPaths.some(a => lc.startsWith(a.toLowerCase()))
}

describe('bundle-scan', () => {
  it(
    'built bundle contains no guard violations',
    () => {
      // Phase 1: Clean
      rmSync(DIST_DIR, { recursive: true, force: true })

      // Phase 2: Build
      execSync('npm run build', { cwd: WEB_DIR, stdio: 'inherit' })

      // Phase 3: Discover assets
      const assetFiles = fg.sync('dist/assets/*.js', { cwd: WEB_DIR })
      expect(assetFiles.length, 'no build assets found — vite build produced no JS chunks').toBeGreaterThan(0)

      const bundlePatterns = PATTERNS.filter(p => p.appliesTo === 'bundle' || p.appliesTo === 'both')
      const evaluatedPatterns = bundlePatterns.map(p => p.name)

      // Phase 4: Scan
      const violations: Violation[] = []

      for (const relFile of assetFiles) {
        const wsPath = 'web/' + relFile.split('\\').join('/')
        const absPath = join(WEB_DIR, relFile)
        const content = readFileSync(absPath, 'utf8')

        for (const pattern of bundlePatterns) {
          if (isAllowed(wsPath, pattern.allowedPaths)) continue

          pattern.regex.lastIndex = 0
          if (pattern.regex.test(content)) {
            // Bundle assets are minified — report line 0 (not applicable)
            violations.push({ file: wsPath, line: 0, patternName: pattern.name })
          }
        }
      }

      const ts = new Date().toISOString().slice(0, 19).split(':').join('-')
      const runId = process.env.GUARD_RUN_ID ?? ts
      assertRedacted(violations)
      writeViolations(violations, evaluatedPatterns, runId)

      if (violations.length > 0) {
        const summary = violations
          .map(v => `  ${v.patternName} @ ${v.file}`)
          .join('\n')
        expect.fail(`Bundle scan found ${violations.length} violation(s):\n${summary}`)
      }

      expect(violations).toHaveLength(0)
    },
    180_000,
  )
})
