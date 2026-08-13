// GRD-UI-05: Redacted violation reporter and YAML writer.
// Violations are serialised as { file, line, patternName } only — no matched content.

import { writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { dump } from 'js-yaml'

export interface Violation {
  file: string
  line: number
  patternName: string
}

interface RunReport {
  runId: string
  date: string
  evaluatedPatterns: string[]
  violations: Violation[]
}

const REQUIRED_KEYS: (keyof Violation)[] = ['file', 'line', 'patternName']

/**
 * Assert that every entry in violations has exactly the keys: file, line, patternName.
 * Throws if any entry carries an additional key or is missing a required key.
 */
export function assertRedacted(violations: Violation[]): void {
  for (const v of violations) {
    const keys = Object.keys(v)
    for (const required of REQUIRED_KEYS) {
      if (!keys.includes(required)) {
        throw new Error(`Violation missing required key "${required}": ${JSON.stringify(v)}`)
      }
    }
    for (const key of keys) {
      if (!(REQUIRED_KEYS as string[]).includes(key)) {
        throw new Error(`Violation has forbidden key "${key}" (must only contain file, line, patternName): ${JSON.stringify(v)}`)
      }
    }
  }
}

/**
 * Write violations to tests/reports/report-<date>-<runId>.yaml.
 * Serialises RunReport as YAML. No matched content is written.
 */
export function writeViolations(
  violations: Violation[],
  evaluatedPatterns: string[],
  runId: string,
): void {
  const date = new Date().toISOString().slice(0, 10)
  const effectiveRunId = process.env.GUARD_RUN_ID ?? runId

  const report: RunReport = {
    runId: effectiveRunId,
    date,
    evaluatedPatterns,
    violations,
  }

  const reportsDir = join(process.cwd(), 'tests', 'reports')
  mkdirSync(reportsDir, { recursive: true })

  const fileName = `report-${date}-${effectiveRunId}.yaml`
  const filePath = join(reportsDir, fileName)
  writeFileSync(filePath, dump(report, { lineWidth: 120 }), 'utf8')
}
