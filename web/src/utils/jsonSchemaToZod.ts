/** Compile TaskFormField to Zod validation schema (TK-UI-03) */

import { z } from 'zod'
import type { TaskFormField } from '@/types/forms'

export function compileFormSchemaToZod(field: TaskFormField): z.ZodSchema {
  try {
    return fieldToZod(field)
  } catch (err) {
    throw new Error(`Failed to compile form schema: ${err instanceof Error ? err.message : String(err)}`)
  }
}

function fieldToZod(field: TaskFormField): z.ZodSchema {
  let schema: z.ZodSchema

  switch (field.type) {
    case 'string':
      schema = z.string()
      if (field.minLength !== undefined) {
        schema = (schema as z.ZodString).min(field.minLength)
      }
      if (field.maxLength !== undefined) {
        schema = (schema as z.ZodString).max(field.maxLength)
      }
      if (field.pattern !== undefined) {
        schema = (schema as z.ZodString).regex(new RegExp(field.pattern))
      }
      if (field.format === 'email') {
        schema = (schema as z.ZodString).email()
      } else if (field.format === 'uri') {
        schema = (schema as z.ZodString).url()
      }
      if (field.enum && field.enum.length > 0) {
        schema = z.enum(field.enum as [string, ...string[]])
      }
      break

    case 'number':
      schema = z.number()
      if (field.minimum !== undefined) {
        schema = (schema as z.ZodNumber).min(field.minimum)
      }
      if (field.maximum !== undefined) {
        schema = (schema as z.ZodNumber).max(field.maximum)
      }
      if (field.multipleOf !== undefined) {
        schema = (schema as z.ZodNumber).multipleOf(field.multipleOf)
      }
      break

    case 'boolean':
      schema = z.boolean()
      break

    case 'date':
      schema = z.coerce.date()
      break

    case 'select':
      if (field.enum && field.enum.length > 0) {
        const enumVals = field.enum.map(String)
        schema = z.enum(enumVals as [string, ...string[]])
      } else {
        schema = z.string()
      }
      break

    case 'object':
      if (field.properties) {
        const propSchemas: Record<string, z.ZodSchema> = {}
        for (const [key, propField] of Object.entries(field.properties)) {
          propSchemas[key] = fieldToZod(propField)
        }
        schema = z.object(propSchemas)
      } else {
        schema = z.object({})
      }
      break

    case 'array':
      if (field.items) {
        schema = z.array(fieldToZod(field.items))
      } else {
        schema = z.array(z.unknown())
      }
      break

    default:
      schema = z.string()
  }

  // Apply required constraint
  if (!field.required) {
    schema = schema.optional()
  }

  return schema
}
