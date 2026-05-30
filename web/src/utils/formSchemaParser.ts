/** Parse JSON Schema to TaskFormField tree (TK-UI-03) */

import type { TaskFormField } from '@/types/forms'

export function parseFormSchema(jsonSchema: unknown): TaskFormField {
  if (!jsonSchema || typeof jsonSchema !== 'object') {
    return {
      name: 'root',
      type: 'object',
      required: false,
      properties: {},
    }
  }

  const schema = jsonSchema as Record<string, unknown>

  // If it's a property with no properties, treat as single field
  if (schema.type && typeof schema.type === 'string' && schema.type !== 'object') {
    return parseField('root', schema)
  }

  // Parse as object with properties
  if (schema.type === 'object' || schema.properties) {
    return parseField('root', schema)
  }

  // Default to object type
  return parseField('root', schema)
}

function parseField(name: string, schema: Record<string, unknown>): TaskFormField {
  const type = normalizeType(schema.type as string | undefined)
  const required = Boolean(schema.required)

  const field: TaskFormField = {
    name,
    type,
    required,
    title: schema.title as string | undefined,
    description: schema.description as string | undefined,
    placeholder: schema.placeholder as string | undefined,
    widget: schema.widget as 'textarea' | 'code-editor' | 'rich-text' | undefined,
  }

  // Type-specific constraints
  if (type === 'string') {
    field.minLength = schema.minLength as number | undefined
    field.maxLength = schema.maxLength as number | undefined
    field.pattern = schema.pattern as string | undefined
    field.format = schema.format as 'date' | 'date-time' | 'time' | 'email' | 'uri' | undefined

    // If enum is specified, promote to select
    if (schema.enum) {
      field.enum = schema.enum as string[]
    }
  } else if (type === 'number') {
    field.minimum = schema.minimum as number | undefined
    field.maximum = schema.maximum as number | undefined
    field.multipleOf = schema.multipleOf as number | undefined

    if (schema.enum) {
      field.enum = schema.enum as number[]
    }
  } else if (type === 'select') {
    if (schema.enum && Array.isArray(schema.enum)) {
      field.enum = schema.enum.map(v => typeof v === 'number' ? String(v) : v) as string[]
    } else {
      field.enum = undefined
    }
  } else if (type === 'object') {
    field.additionalProperties = schema.additionalProperties as boolean | undefined
    const properties = schema.properties as Record<string, unknown> | undefined
    if (properties) {
      const requiredFields = new Set(schema.required as string[] | undefined)
      field.properties = {}
      for (const [key, propSchema] of Object.entries(properties)) {
        field.properties[key] = parseField(key, propSchema as Record<string, unknown>)
        if (requiredFields.has(key)) {
          field.properties[key].required = true
        }
      }
    }
  } else if (type === 'array') {
    const items = schema.items as Record<string, unknown> | undefined
    if (items) {
      field.items = parseField('item', items)
    }
  }

  return field
}

function normalizeType(type: string | undefined): TaskFormField['type'] {
  switch (type) {
    case 'string':
      return 'string'
    case 'number':
    case 'integer':
      return 'number'
    case 'boolean':
      return 'boolean'
    case 'object':
      return 'object'
    case 'array':
      return 'array'
    case 'select':
      return 'select'
    case 'date':
      return 'date'
    default:
      return 'string'
  }
}
