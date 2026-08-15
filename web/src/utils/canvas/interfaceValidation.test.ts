import { describe, expect, it } from 'vitest'
import {
  MAX_ENTRIES_PER_DIRECTION,
  MAX_SCHEMA_DEPTH,
  isWellFormedSchema,
  parseSubProcessInterface,
  validateSubProcessInterface,
} from './interfaceValidation'
import type { SubProcessInterface } from '@/types/api'

/**
 * SPC-02 client-side mirror tests. The rules asserted here mirror the backend
 * (`src/definition/sub_process_interface.zig` `collectInterfaceViolations` and
 * `src/tools/json_schema.zig` `validateSchemaShape`) so the process designer
 * canvas flags the same malformed interfaces the backend rejects with HTTP 422.
 */

describe('validateSubProcessInterface — shape', () => {
  it('treats an absent interface as valid (EXT-05 no-contract path)', () => {
    expect(validateSubProcessInterface(undefined)).toEqual([])
    expect(validateSubProcessInterface(null)).toEqual([])
  })

  it('flags a non-object interface as NOT_OBJECT', () => {
    const stringIssue = validateSubProcessInterface('{"inputs":[]}')
    expect(stringIssue).toHaveLength(1)
    expect(stringIssue[0].code).toBe('SUB_PROCESS_INTERFACE_NOT_OBJECT')
    expect(stringIssue[0].pointer).toBe('/interface')

    expect(validateSubProcessInterface(42)[0].code).toBe('SUB_PROCESS_INTERFACE_NOT_OBJECT')
    expect(validateSubProcessInterface(true)[0].code).toBe('SUB_PROCESS_INTERFACE_NOT_OBJECT')
    expect(validateSubProcessInterface([])[0].code).toBe('SUB_PROCESS_INTERFACE_NOT_OBJECT')
  })

  it('accepts an empty object and an object with no direction keys', () => {
    expect(validateSubProcessInterface({})).toEqual([])
    expect(validateSubProcessInterface({ inputs: [], outputs: [] })).toEqual([])
  })

  it('flags inputs present but not an array', () => {
    const issues = validateSubProcessInterface({ inputs: { name: 'x', json_schema: {} } })
    expect(issues).toHaveLength(1)
    expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY')
    expect(issues[0].direction).toBe('inputs')
  })

  it('flags outputs present but not an array', () => {
    const issues = validateSubProcessInterface({ outputs: 'nope' })
    expect(issues).toHaveLength(1)
    expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY')
    expect(issues[0].direction).toBe('outputs')
  })

  it('flags too many entries per direction', () => {
    const many = Array.from({ length: MAX_ENTRIES_PER_DIRECTION + 1 }, (_, i) => ({
      name: `v${i}`,
      json_schema: { type: 'string' },
    }))
    const issues = validateSubProcessInterface({ inputs: many })
    expect(issues).toHaveLength(1)
    expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_ENTRY_INVALID')
  })
})

describe('validateSubProcessInterface — entry shape', () => {
  const validEntry = { name: 'customer_id', json_schema: { type: 'string' }, required: true }

  it('accepts a fully formed valid interface', () => {
    const iface: SubProcessInterface = {
      inputs: [validEntry, { name: 'amount', json_schema: { type: 'number' }, required: false }],
      outputs: [{ name: 'order_id', json_schema: { type: 'string' } }],
    }
    expect(validateSubProcessInterface(iface)).toEqual([])
  })

  it('accepts an entry without the optional required flag (defaults to false)', () => {
    expect(validateSubProcessInterface({ inputs: [{ name: 'a', json_schema: {} }] })).toEqual([])
  })

  it('flags an entry that is not an object', () => {
    const issues = validateSubProcessInterface({ inputs: ['a', validEntry] })
    expect(issues).toHaveLength(1)
    expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_ENTRY_INVALID')
    expect(issues[0].pointer).toBe('/interface/inputs/0')
  })

  it('flags a missing name', () => {
    const issues = validateSubProcessInterface({ inputs: [{ json_schema: {} }] })
    expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_ENTRY_INVALID')
  })

  it('flags an empty or non-string name', () => {
    expect(
      validateSubProcessInterface({ inputs: [{ name: '', json_schema: {} }] })[0].code,
    ).toBe('SUB_PROCESS_INTERFACE_ENTRY_INVALID')
    expect(
      validateSubProcessInterface({ inputs: [{ name: 42, json_schema: {} }] })[0].code,
    ).toBe('SUB_PROCESS_INTERFACE_ENTRY_INVALID')
  })

  it('flags a duplicate name within a direction', () => {
    const issues = validateSubProcessInterface({
      inputs: [validEntry, { name: 'customer_id', json_schema: {} }],
    })
    expect(issues).toHaveLength(1)
    expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_DUPLICATE_NAME')
    expect(issues[0].name).toBe('customer_id')
  })

  it('allows the same name in inputs and outputs (only intra-direction uniqueness)', () => {
    expect(
      validateSubProcessInterface({
        inputs: [validEntry],
        outputs: [{ name: 'customer_id', json_schema: {} }],
      }),
    ).toEqual([])
  })

  it('flags a non-boolean required flag', () => {
    const issues = validateSubProcessInterface({
      inputs: [{ name: 'a', json_schema: {}, required: 'yes' }],
    })
    expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_ENTRY_INVALID')
  })

  it('flags an entry missing json_schema', () => {
    const issues = validateSubProcessInterface({ inputs: [{ name: 'a' }] })
    expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_ENTRY_INVALID')
  })
})

describe('validateSubProcessInterface — json_schema well-formedness (SPC-02)', () => {
  it('accepts an empty object schema', () => {
    expect(isWellFormedSchema({})).toBe(true)
    expect(validateSubProcessInterface({ inputs: [{ name: 'a', json_schema: {} }] })).toEqual([])
  })

  it('flags a schema that is not an object', () => {
    for (const bad of [true, 'string', 42, []]) {
      const issues = validateSubProcessInterface({ inputs: [{ name: 'a', json_schema: bad }] })
      expect(issues).toHaveLength(1)
      expect(issues[0].code).toBe('SUB_PROCESS_INTERFACE_SCHEMA_INVALID')
    }
  })

  it('accepts all supported type names and rejects unknown ones', () => {
    for (const t of ['string', 'number', 'integer', 'boolean', 'object', 'array', 'null']) {
      expect(isWellFormedSchema({ type: t })).toBe(true)
    }
    expect(isWellFormedSchema({ type: 'date' })).toBe(false)
    expect(isWellFormedSchema({ type: 42 })).toBe(false)
  })

  it('accepts a non-empty type array and rejects empty/invalid arrays', () => {
    expect(isWellFormedSchema({ type: ['string', 'null'] })).toBe(true)
    expect(isWellFormedSchema({ type: [] })).toBe(false)
    expect(isWellFormedSchema({ type: ['string', 'date'] })).toBe(false)
  })

  it('rejects non-number minimum/maximum', () => {
    expect(isWellFormedSchema({ minimum: 'low' })).toBe(false)
    expect(isWellFormedSchema({ minimum: 5 })).toBe(true)
    expect(isWellFormedSchema({ maximum: -1 })).toBe(true) // any JSON number is fine
  })

  it('rejects non-integer or negative minLength/maxLength', () => {
    expect(isWellFormedSchema({ minLength: 2 })).toBe(true)
    expect(isWellFormedSchema({ minLength: 1.5 })).toBe(false)
    expect(isWellFormedSchema({ minLength: -1 })).toBe(false)
    expect(isWellFormedSchema({ maxLength: '10' })).toBe(false)
  })

  it('requires enum to be an array', () => {
    expect(isWellFormedSchema({ enum: ['a', 'b'] })).toBe(true)
    expect(isWellFormedSchema({ enum: 'a' })).toBe(false)
  })

  it('requires required to be an array of non-empty strings', () => {
    expect(isWellFormedSchema({ required: ['a'] })).toBe(true)
    expect(isWellFormedSchema({ required: [] })).toBe(true)
    expect(isWellFormedSchema({ required: 'a' })).toBe(false)
    expect(isWellFormedSchema({ required: [''] })).toBe(false)
    expect(isWellFormedSchema({ required: [1] })).toBe(false)
  })

  it('validates properties recursively', () => {
    expect(isWellFormedSchema({ properties: { a: { type: 'string' } } })).toBe(true)
    expect(isWellFormedSchema({ properties: { a: { type: 42 } } })).toBe(false)
    expect(isWellFormedSchema({ properties: 'nope' })).toBe(false)
  })

  it('validates items recursively', () => {
    expect(isWellFormedSchema({ items: { type: 'string' } })).toBe(true)
    expect(isWellFormedSchema({ items: 'nope' })).toBe(false)
  })

  it('requires additionalProperties to be a boolean', () => {
    expect(isWellFormedSchema({ additionalProperties: false })).toBe(true)
    expect(isWellFormedSchema({ additionalProperties: true })).toBe(true)
    expect(isWellFormedSchema({ additionalProperties: 'false' })).toBe(false)
  })

  it('permits unknown/inert keywords ($ref, format, description, allOf)', () => {
    expect(
      isWellFormedSchema({
        $ref: '#/definitions/a',
        format: 'uuid',
        description: 'ignored',
        allOf: [{ type: 'string' }],
        title: 'Also ignored',
      }),
    ).toBe(true)
  })

  it('enforces the recursion depth cap', () => {
    // Depth exactly at MAX_SCHEMA_DEPTH is accepted.
    let deep: unknown = {}
    for (let i = 0; i < MAX_SCHEMA_DEPTH; i++) deep = { properties: { a: deep } }
    expect(isWellFormedSchema(deep)).toBe(true)

    // One level beyond the cap is rejected.
    let tooDeep: unknown = {}
    for (let i = 0; i <= MAX_SCHEMA_DEPTH; i++) tooDeep = { properties: { a: tooDeep } }
    expect(isWellFormedSchema(tooDeep)).toBe(false)
  })
})

describe('parseSubProcessInterface', () => {
  it('returns undefined for absent or malformed values', () => {
    expect(parseSubProcessInterface(undefined)).toBeUndefined()
    expect(parseSubProcessInterface(null)).toBeUndefined()
    expect(parseSubProcessInterface('nope')).toBeUndefined()
  })

  it('coerces missing direction keys to empty arrays', () => {
    const parsed = parseSubProcessInterface({})
    expect(parsed).toEqual({ inputs: [], outputs: [] })
  })

  it('passes through a validated interface', () => {
    const value = {
      inputs: [{ name: 'customer_id', json_schema: { type: 'string' }, required: true }],
      outputs: [],
    }
    expect(parseSubProcessInterface(value)).toEqual(value)
  })
})
