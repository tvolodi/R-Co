/** reportWriter — GRD-UI-06 §3.4
 *
 *  Writes a YAML report to tests/reports/report-<UTC-date>-<run_id>.yaml.
 *  The file format mirrors the GRD-UI-05 RunReport shape. Write is
 *  atomic: open('w'), write the buffer, fsync, close. On failure the
 *  gate throws BLOCKER.
 */

import { promises as fs } from 'node:fs'
import * as path from 'node:path'

export type A11ySeverity = 'BLOCKER' | 'CRITICAL' | 'MAJOR' | 'MINOR'

export interface A11yViolation {
  surface: string
  ruleId: string
  impact: 'minor' | 'moderate' | 'serious' | 'critical' | null
  target: string
  help: string
  helpUrl: string
  severity: A11ySeverity
}

export interface A11yRunReport {
  runId: string
  date: string // YYYY-MM-DD UTC
  evaluatedSurfaces: string[]
  violations: A11yViolation[]
}

function escapeYamlString(value: string): string {
  return value.replace(/"/g, '\\"')
}

function yamlString(value: string): string {
  return `"${escapeYamlString(value)}"`
}

export function renderYamlReport(report: A11yRunReport): string {
  const lines: string[] = []
  lines.push(`runId: ${yamlString(report.runId)}`)
  lines.push(`date: ${yamlString(report.date)}`)
  lines.push('evaluatedSurfaces:')
  for (const s of report.evaluatedSurfaces) {
    lines.push(`  - ${s}`)
  }
  lines.push('violations:')
  if (report.violations.length === 0) {
    // Empty list — emit nothing (YAML null-equivalent). The file still
    // validates as a valid report.
  } else {
    for (const v of report.violations) {
      lines.push(`  - surface: ${yamlString(v.surface)}`)
      lines.push(`    ruleId: ${yamlString(v.ruleId)}`)
      lines.push(`    impact: ${yamlString(v.impact ?? 'unknown')}`)
      lines.push(`    target: ${yamlString(v.target)}`)
      lines.push(`    severity: ${yamlString(v.severity)}`)
      lines.push(`    help: ${yamlString(v.help)}`)
      lines.push(`    helpUrl: ${yamlString(v.helpUrl)}`)
    }
  }
  lines.push('')
  return lines.join('\n')
}

export async function writeReport(
  report: A11yRunReport,
  outputDir: string = path.resolve(process.cwd(), 'web/tests/reports'),
): Promise<string> {
  const filename = `report-${report.date}-${report.runId}.yaml`
  const targetPath = path.join(outputDir, filename)
  const body = renderYamlReport(report)
  try {
    await fs.mkdir(outputDir, { recursive: true })
    await fs.writeFile(targetPath, body, { encoding: 'utf-8', flag: 'w' })
    // Best-effort fsync — not all platforms support it on regular files.
    const fh = await fs.open(targetPath, 'r+')
    try {
      await fh.sync()
    } catch {
      /* ignore — fsync not supported on this fs */
    } finally {
      await fh.close()
    }
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : String(e)
    throw new Error(
      `A11Y GATE BLOCKER: cannot write report to ${targetPath} — ${message}`,
    )
  }
  return targetPath
}

export function utcDateStamp(d: Date = new Date()): string {
  const yyyy = d.getUTCFullYear()
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0')
  const dd = String(d.getUTCDate()).padStart(2, '0')
  return `${yyyy}-${mm}-${dd}`
}
