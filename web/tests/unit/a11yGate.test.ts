/**
 * Unit tests — GRD-UI-06 §3.6: a11yGate impact->severity decision matrix
 *
 *   TC-AG-01: 'serious' impact -> CRITICAL
 *   TC-AG-02: 'critical' impact -> CRITICAL
 *   TC-AG-03: 'moderate' impact -> MINOR (record-only)
 *   TC-AG-04: 'minor' impact -> MINOR (record-only)
 *   TC-AG-05: null impact -> MINOR (record-only)
 *   TC-AG-06: classifyViolations applies the matrix to a list
 *   TC-AG-07: aggregateBlockingViolations returns only CRITICAL entries
 *   TC-AG-08: renderYamlReport — empty list, one entry, multiple entries
 *   TC-AG-09: writeReport throws BLOCKER on fs error (path is a directory)
 */

import { describe, it, expect, beforeEach } from 'vitest'
import {
  impactToSeverity,
  classifyViolations,
  aggregateBlockingViolations,
} from '../a11y/a11yGate'
import {
  renderYamlReport,
  writeReport,
  utcDateStamp,
} from '../a11y/reportWriter'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'

beforeEach(() => {
  // Reset any output dirs between tests.
})

describe('a11yGate — impact -> severity matrix', () => {
  it('TC-AG-01: serious -> CRITICAL', () => {
    expect(impactToSeverity('serious')).toBe('CRITICAL')
  })

  it('TC-AG-02: critical -> CRITICAL', () => {
    expect(impactToSeverity('critical')).toBe('CRITICAL')
  })

  it('TC-AG-03: moderate -> MINOR (record-only)', () => {
    expect(impactToSeverity('moderate')).toBe('MINOR')
  })

  it('TC-AG-04: minor -> MINOR (record-only)', () => {
    expect(impactToSeverity('minor')).toBe('MINOR')
  })

  it('TC-AG-05: null -> MINOR (record-only)', () => {
    expect(impactToSeverity(null)).toBe('MINOR')
  })

  it('TC-AG-06: classifyViolations maps impacts across a list', () => {
    const violations = classifyViolations('surface-1', [
      { ruleId: 'a', impact: 'serious', target: 't1', help: 'h', helpUrl: 'u' },
      { ruleId: 'b', impact: 'moderate', target: 't2', help: 'h', helpUrl: 'u' },
    ])
    expect(violations).toHaveLength(2)
    expect(violations[0]?.severity).toBe('CRITICAL')
    expect(violations[1]?.severity).toBe('MINOR')
  })

  it('TC-AG-07: aggregateBlockingViolations returns only CRITICAL entries', () => {
    const violations = classifyViolations('s', [
      { ruleId: 'a', impact: 'serious', target: 't1', help: 'h', helpUrl: 'u' },
      { ruleId: 'b', impact: 'moderate', target: 't2', help: 'h', helpUrl: 'u' },
    ])
    const blocking = aggregateBlockingViolations(violations)
    expect(blocking).toHaveLength(1)
    expect(blocking[0]?.ruleId).toBe('a')
  })
})

describe('reportWriter — YAML emission', () => {
  it('TC-AG-08a: empty violations list renders without entries', () => {
    const report = {
      runId: 'run-1',
      date: '2026-08-13',
      evaluatedSurfaces: ['s'],
      violations: [],
    }
    const out = renderYamlReport(report)
    expect(out).toContain('runId: "run-1"')
    expect(out).toContain('evaluatedSurfaces:')
    expect(out).not.toContain('ruleId:')
  })

  it('TC-AG-08b: one entry renders with severity', () => {
    const out = renderYamlReport({
      runId: 'run-1',
      date: '2026-08-13',
      evaluatedSurfaces: ['s'],
      violations: [
        {
          surface: 's',
          ruleId: 'r1',
          impact: 'serious',
          target: 't',
          help: 'h',
          helpUrl: 'u',
          severity: 'CRITICAL',
        },
      ],
    })
    expect(out).toContain('ruleId: "r1"')
    expect(out).toContain('severity: "CRITICAL"')
  })

  it('TC-AG-09: writeReport throws BLOCKER on directory collision', async () => {
    const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'a11y-test-'))
    // Pre-create a *directory* at the target path; fs.writeFile fails.
    const targetDir = path.join(tmpRoot, 'reports')
    fs.mkdirSync(targetDir, { recursive: true })
    const targetFile = path.join(targetDir, 'report-2026-08-13-run-X.yaml')
    fs.mkdirSync(targetFile) // path is a directory
    await expect(
      writeReport(
        { runId: 'run-X', date: '2026-08-13', evaluatedSurfaces: ['s'], violations: [] },
        targetDir,
      ),
    ).rejects.toThrow(/A11Y GATE BLOCKER/)
  })

  it('TC-AG-10: utcDateStamp returns YYYY-MM-DD in UTC', () => {
    const stamp = utcDateStamp(new Date(Date.UTC(2026, 0, 5)))
    expect(stamp).toBe('2026-01-05')
  })
})