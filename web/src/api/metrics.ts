import { client } from './client'

export interface PrometheusMetricSample {
  name: string
  labels: Record<string, string>
  value: number
}

export interface PrometheusMetricFamily {
  name: string
  help?: string
  type: 'counter' | 'gauge' | 'histogram' | 'summary' | 'untyped'
  samples: PrometheusMetricSample[]
}

const SAMPLE_RE = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)$/

function parseLabels(raw?: string): Record<string, string> {
  if (!raw) return {}

  const labels = raw.slice(1, -1)
  if (!labels.trim()) return {}

  return labels
    .split(',')
    .map((segment) => segment.trim())
    .filter(Boolean)
    .reduce<Record<string, string>>((acc, segment) => {
      const idx = segment.indexOf('=')
      if (idx <= 0) return acc
      const key = segment.slice(0, idx).trim()
      const value = segment.slice(idx + 1).trim().replace(/^"|"$/g, '')
      if (key) acc[key] = value
      return acc
    }, {})
}

export function parsePrometheusText(text: string): PrometheusMetricFamily[] {
  const lines = text.split(/\r?\n/)
  const families = new Map<string, PrometheusMetricFamily>()
  let parsedLines = 0

  for (const lineRaw of lines) {
    const line = lineRaw.trim()
    if (!line) continue

    if (line.startsWith('# HELP ')) {
      const helpLine = line.slice('# HELP '.length)
      const firstSpace = helpLine.indexOf(' ')
      if (firstSpace <= 0) continue
      const metricName = helpLine.slice(0, firstSpace)
      const help = helpLine.slice(firstSpace + 1)
      const existing = families.get(metricName)
      if (existing) {
        existing.help = help
      } else {
        families.set(metricName, {
          name: metricName,
          help,
          type: 'untyped',
          samples: [],
        })
      }
      continue
    }

    if (line.startsWith('# TYPE ')) {
      const typeLine = line.slice('# TYPE '.length)
      const [metricName, metricType] = typeLine.split(/\s+/, 2)
      if (!metricName || !metricType) continue
      const familyType = ['counter', 'gauge', 'histogram', 'summary', 'untyped'].includes(metricType)
        ? (metricType as PrometheusMetricFamily['type'])
        : 'untyped'
      const existing = families.get(metricName)
      if (existing) {
        existing.type = familyType
      } else {
        families.set(metricName, {
          name: metricName,
          type: familyType,
          samples: [],
        })
      }
      continue
    }

    if (line.startsWith('#')) {
      continue
    }

    const match = line.match(SAMPLE_RE)
    if (!match) {
      continue
    }

    parsedLines += 1
    const sampleName = match[1]
    const labels = parseLabels(match[2])
    const value = Number(match[3])
    if (Number.isNaN(value)) {
      continue
    }

    const familyName = sampleName
      .replace(/_(bucket|sum|count)$/u, '')
      .replace(/_[0-9]+$/u, '')
    const existing = families.get(familyName)
    if (existing) {
      existing.samples.push({ name: sampleName, labels, value })
    } else {
      families.set(familyName, {
        name: familyName,
        type: 'untyped',
        samples: [{ name: sampleName, labels, value }],
      })
    }
  }

  if (parsedLines === 0 && text.trim().length > 0) {
    throw new Error('PROM_PARSE_ERROR')
  }

  return [...families.values()].filter((family) => family.samples.length > 0)
}

export const metricsApi = {
  prometheusText: () => client.getText('/metrics'),
}
