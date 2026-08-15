/**
 * interfaceValidation — client-side mirror of SPC-02 (definition-time contract
 * validation for the optional SUB_PROCESS `interface` attribute).
 *
 * Mirrors the structural rules implemented in
 * `src/definition/sub_process_interface.zig` (`collectInterfaceViolations`) and
 * `src/tools/json_schema.zig` (`validateSchemaShape`): overall shape, entry
 * shape, JSON Schema well-formedness, and duplicate-name checks. A node that
 * omits `interface` (or declares none) is valid — the EXT-05 no-contract path
 * is preserved unchanged.
 *
 * Pure module: no I/O, no React, no API dependency. Safe for unit testing.
 */

import type { SubProcessInterface, SubProcessInterfaceEntry } from '@/types/api'

/** One SPC-02 definition-time interface violation (client-side mirror). */
export interface InterfaceValidationIssue {
  /** One of the SPC-02 HTTP 422 error codes (mirrors the backend taxonomy). */
  code: string
  /** `inputs` | `outputs` — the offending direction, when entry-scoped. */
  direction?: 'inputs' | 'outputs'
  /** Entry name, when the violation is entry-scoped. */
  name?: string
  /** RFC 6901 pointer to the offending field within `interface`. */
  pointer: string
  /** Human-readable detail. */
  message: string
}

/** Maximum declared entries per direction (mirrors the backend bound). */
export const MAX_ENTRIES_PER_DIRECTION = 256

/** Maximum `properties`/`items` nesting depth accepted by schema well-formedness. */
export const MAX_SCHEMA_DEPTH = 32

const SUPPORTED_TYPE_NAMES = new Set([
  'string',
  'number',
  'integer',
  'boolean',
  'object',
  'array',
  'null',
])

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isJsonNumber(value: unknown): boolean {
  return typeof value === 'number' && Number.isFinite(value)
}

function isNonNegativeInteger(value: unknown): boolean {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0
}

/** `type` keyword is well-formed iff a supported name, or a non-empty array of them. */
function typeKeywordWellFormed(value: unknown): boolean {
  if (typeof value === 'string') return SUPPORTED_TYPE_NAMES.has(value)
  if (Array.isArray(value)) {
    return (
      value.length > 0 &&
      value.every((t) => typeof t === 'string' && SUPPORTED_TYPE_NAMES.has(t))
    )
  }
  return false
}

/**
 * SPC-02 schema-of-schemas well-formedness check. Returns true when `schema`
 * is a well-formed JSON Schema object per the platform's supported keyword set:
 * - An empty object `{}` is well-formed (fully permissive).
 * - Unknown keywords (`$ref`, `allOf`/`anyOf`/`oneOf`/`not`, `pattern`,
 *   `format`, `description`, …) are permitted and inert.
 * - `properties`/`items` nesting is capped at `MAX_SCHEMA_DEPTH`.
 */
export function isWellFormedSchema(schema: unknown, depth = 0): boolean {
  if (!isPlainObject(schema)) return false
  if (depth > MAX_SCHEMA_DEPTH) return false

  if ('type' in schema && !typeKeywordWellFormed(schema['type'])) return false

  if ('minimum' in schema && !isJsonNumber(schema['minimum'])) return false
  if ('maximum' in schema && !isJsonNumber(schema['maximum'])) return false

  if ('minLength' in schema && !isNonNegativeInteger(schema['minLength'])) return false
  if ('maxLength' in schema && !isNonNegativeInteger(schema['maxLength'])) return false

  if ('enum' in schema && !Array.isArray(schema['enum'])) return false

  if ('required' in schema) {
    const required = schema['required']
    if (!Array.isArray(required)) return false
    for (const item of required) {
      if (typeof item !== 'string' || item.length === 0) return false
    }
  }

  if ('properties' in schema) {
    const props = schema['properties']
    if (!isPlainObject(props)) return false
    for (const key of Object.keys(props)) {
      if (!isWellFormedSchema(props[key], depth + 1)) return false
    }
  }

  if ('items' in schema) {
    if (!isWellFormedSchema(schema['items'], depth + 1)) return false
  }

  if ('additionalProperties' in schema && typeof schema['additionalProperties'] !== 'boolean') {
    return false
  }

  return true
}

function pushDirectionIssue(
  issues: InterfaceValidationIssue[],
  code: string,
  direction: 'inputs' | 'outputs' | undefined,
  name: string | undefined,
  pointer: string,
  message: string,
): void {
  const issue: InterfaceValidationIssue = { code, pointer, message }
  if (direction !== undefined) issue.direction = direction
  if (name !== undefined) issue.name = name
  issues.push(issue)
}

/** Validate one direction's entries: shape, name, required, schema, duplicates. */
function collectDirection(
  issues: InterfaceValidationIssue[],
  direction: 'inputs' | 'outputs',
  items: unknown,
  basePointer: string,
): void {
  if (!Array.isArray(items)) {
    pushDirectionIssue(
      issues,
      direction === 'inputs'
        ? 'SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY'
        : 'SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY',
      direction,
      undefined,
      basePointer,
      `interface.${direction} must be an array`,
    )
    return
  }
  if (items.length > MAX_ENTRIES_PER_DIRECTION) {
    pushDirectionIssue(
      issues,
      'SUB_PROCESS_INTERFACE_ENTRY_INVALID',
      direction,
      undefined,
      basePointer,
      `too many entries (max ${MAX_ENTRIES_PER_DIRECTION})`,
    )
    return
  }

  const seen = new Set<string>()
  items.forEach((entry, i) => {
    const pointer = `${basePointer}/${i}`
    if (!isPlainObject(entry)) {
      pushDirectionIssue(
        issues,
        'SUB_PROCESS_INTERFACE_ENTRY_INVALID',
        direction,
        undefined,
        pointer,
        'entry must be a JSON object',
      )
      return
    }

    const name = entry['name']
    if (typeof name !== 'string' || name.length === 0) {
      pushDirectionIssue(
        issues,
        'SUB_PROCESS_INTERFACE_ENTRY_INVALID',
        direction,
        undefined,
        pointer,
        "entry 'name' must be a non-empty string",
      )
      return
    }

    if (seen.has(name)) {
      pushDirectionIssue(
        issues,
        'SUB_PROCESS_INTERFACE_DUPLICATE_NAME',
        direction,
        name,
        pointer,
        `duplicate name '${name}' within ${direction}`,
      )
      return
    }
    seen.add(name)

    if ('required' in entry && typeof entry['required'] !== 'boolean') {
      pushDirectionIssue(
        issues,
        'SUB_PROCESS_INTERFACE_ENTRY_INVALID',
        direction,
        name,
        pointer,
        "'required' must be a boolean",
      )
      return
    }

    if (!('json_schema' in entry)) {
      pushDirectionIssue(
        issues,
        'SUB_PROCESS_INTERFACE_ENTRY_INVALID',
        direction,
        name,
        pointer,
        "entry is missing 'json_schema'",
      )
      return
    }

    if (!isWellFormedSchema(entry['json_schema'])) {
      pushDirectionIssue(
        issues,
        'SUB_PROCESS_INTERFACE_SCHEMA_INVALID',
        direction,
        name,
        pointer,
        'json_schema is not a well-formed JSON Schema object',
      )
      return
    }
  })
}

/**
 * SPC-02 structural validation for a SUB_PROCESS `interface` attribute value.
 *
 * Mirrors the backend's `collectInterfaceViolations`: an absent `interface`
 * (undefined/null) is valid (EXT-05 path); a non-object is a single
 * `SUB_PROCESS_INTERFACE_NOT_OBJECT` issue; an object's `inputs`/`outputs` are
 * each validated for array-ness, entry shape, duplicate names, and per-entry
 * `json_schema` well-formedness.
 *
 * Returns one issue per offending entry (all violations, not just the first).
 */
export function validateSubProcessInterface(value: unknown): InterfaceValidationIssue[] {
  const issues: InterfaceValidationIssue[] = []
  if (value === undefined || value === null) return issues

  if (!isPlainObject(value)) {
    pushDirectionIssue(
      issues,
      'SUB_PROCESS_INTERFACE_NOT_OBJECT',
      undefined,
      undefined,
      '/interface',
      'interface attribute must be a JSON object',
    )
    return issues
  }

  if ('inputs' in value) collectDirection(issues, 'inputs', value['inputs'], '/interface/inputs')
  if ('outputs' in value) collectDirection(issues, 'outputs', value['outputs'], '/interface/outputs')
  return issues
}

/**
 * Parse a validated `interface` value into the typed shape. Returns undefined
 * when `value` is absent (no declared interface — EXT-05 path). Callers should
 * run `validateSubProcessInterface` first and only treat the result as valid
 * when no issues are returned.
 */
export function parseSubProcessInterface(value: unknown): SubProcessInterface | undefined {
  if (value === undefined || value === null) return undefined
  if (!isPlainObject(value)) return undefined
  const inputs: SubProcessInterfaceEntry[] = Array.isArray(value['inputs'])
    ? (value['inputs'] as SubProcessInterfaceEntry[])
    : []
  const outputs: SubProcessInterfaceEntry[] = Array.isArray(value['outputs'])
    ? (value['outputs'] as SubProcessInterfaceEntry[])
    : []
  return { inputs, outputs }
}
