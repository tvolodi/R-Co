/** Dynamic form renderer from JSON Schema (TK-UI-03) */

import { useEffect, useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import type { ApiError } from '@/types/api'
import type { DynamicFormValue, TaskFormField } from '@/types/forms'
import { parseFormSchema } from '@/utils/formSchemaParser'
import { compileFormSchemaToZod } from '@/utils/jsonSchemaToZod'
import type { ZodSchema } from 'zod'

export interface DynamicFormRendererProps {
  formSchema: Record<string, unknown> | null
  onSubmit: (values: DynamicFormValue) => Promise<void>
  submitLabel?: string
  isSubmitting?: boolean
  submitError?: ApiError
  isRequired?: boolean
  requirementsContext?: {
    instanceId: string
    variables: Record<string, unknown>
  }
}

export function DynamicFormRenderer(props: DynamicFormRendererProps) {
  const {
    formSchema,
    onSubmit,
    submitLabel = 'Complete Task',
    isSubmitting = false,
    submitError,
  } = props

  const [parseError, setParseError] = useState<string | null>(null)
  const [validationSchema, setValidationSchema] = useState<ZodSchema | null>(null)
  const [formFields, setFormFields] = useState<Record<string, TaskFormField>>({})

  const form = useForm<DynamicFormValue>({
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    resolver: validationSchema ? (zodResolver(validationSchema as any) as any) : undefined,
    mode: 'onChange',
  })

  // Parse and compile form schema on mount or change
  useEffect(() => {
    setParseError(null)
    try {
      if (!formSchema || typeof formSchema !== 'object') {
        setValidationSchema(null)
        setFormFields({})
        return
      }

      const parsed = parseFormSchema(formSchema)
      const compiled = compileFormSchemaToZod(parsed)
      setValidationSchema(compiled)
      const properties = (formSchema as Record<string, unknown>).properties as Record<string, TaskFormField> | undefined
      setFormFields(properties ?? {})
      form.reset({})
    } catch (err) {
      setParseError(err instanceof Error ? err.message : 'Failed to parse form schema')
      setValidationSchema(null)
    }
  }, [formSchema, form])

  if (parseError) {
    return (
      <div style={{ background: '#fee2e2', border: '1px solid #fecaca', borderRadius: '6px', padding: '1rem', marginBottom: '1.5rem' }}>
        <p style={{ color: '#991b1b', fontWeight: 600, margin: '0 0 0.5rem 0' }}>Unable to render form schema</p>
        <p style={{ color: '#7f1d1d', fontSize: '.9rem', margin: 0 }}>
          {parseError}
        </p>
      </div>
    )
  }

  const handleFormSubmit = async (values: DynamicFormValue) => {
    try {
      await onSubmit(values)
    } catch (err) {
      // Error handling done by parent
    }
  }

  const commonInputStyles = {
    width: '100%',
    padding: '.5rem .75rem',
    border: '1px solid #cbd5e1',
    borderRadius: '4px',
    fontSize: '.9rem',
    fontFamily: 'inherit',
    boxSizing: 'border-box' as const,
  }

  return (
    <form onSubmit={form.handleSubmit(handleFormSubmit)} style={{ overflow: 'hidden' }}>
      {submitError && (
        <div style={{ background: '#fee2e2', border: '1px solid #fecaca', borderRadius: '6px', padding: '1rem', marginBottom: '1rem' }}>
          <p style={{ color: '#991b1b', margin: 0, fontSize: '.9rem' }}>
            {submitError.message}
          </p>
        </div>
      )}

      {/* Render form fields from schema */}
      {Object.entries(formFields).map(([fieldName, fieldDef]: [string, TaskFormField]) => {
        const isRequired = fieldDef.required || false
        const title = fieldDef.title || fieldName
        const description = fieldDef.description
        const fieldType = fieldDef.type || 'string'
        const fieldError = form.formState.errors[fieldName]

        return (
          <div key={fieldName} style={{ marginBottom: '1rem' }}>
            <label
              htmlFor={fieldName}
              style={{
                display: 'block',
                marginBottom: '.5rem',
                fontWeight: 500,
                fontSize: '.9rem',
                color: '#1e293b',
              }}
            >
              {title}
              {isRequired && <span style={{ color: '#ef4444', marginLeft: '.25rem' }}>*</span>}
            </label>

            {description && (
              <p style={{ margin: '0.25rem 0 0.5rem 0', fontSize: '.85rem', color: '#64748b' }}>
                {description}
              </p>
            )}

            {fieldType === 'string' && !fieldDef.widget && !fieldDef.enum && (
              <input
                {...form.register(fieldName)}
                id={fieldName}
                type={fieldDef.format === 'email' ? 'email' : fieldDef.format === 'date' ? 'date' : 'text'}
                placeholder={fieldDef.placeholder || `Enter ${title.toLowerCase()}`}
                style={{
                  ...commonInputStyles,
                  borderColor: fieldError ? '#ef4444' : '#cbd5e1',
                } as React.CSSProperties}
              />
            )}

            {fieldType === 'string' && fieldDef.widget === 'textarea' && (
              <textarea
                {...form.register(fieldName)}
                id={fieldName}
                placeholder={fieldDef.placeholder || `Enter ${title.toLowerCase()}`}
                rows={4}
                style={{
                  ...commonInputStyles,
                  borderColor: fieldError ? '#ef4444' : '#cbd5e1',
                  resize: 'vertical',
                } as React.CSSProperties}
              />
            )}

            {fieldType === 'string' && fieldDef.enum && (
              <select
                {...form.register(fieldName)}
                id={fieldName}
                style={{
                  ...commonInputStyles,
                  borderColor: fieldError ? '#ef4444' : '#cbd5e1',
                } as React.CSSProperties}
              >
                <option value="">Select {title.toLowerCase()}</option>
                {fieldDef.enum.map((option: string | number) => (
                  <option key={option} value={option}>
                    {option}
                  </option>
                ))}
              </select>
            )}

            {fieldType === 'number' && (
              <input
                {...form.register(fieldName)}
                id={fieldName}
                type="number"
                placeholder={fieldDef.placeholder || `Enter ${title.toLowerCase()}`}
                style={{
                  ...commonInputStyles,
                  borderColor: fieldError ? '#ef4444' : '#cbd5e1',
                } as React.CSSProperties}
              />
            )}

            {fieldType === 'boolean' && (
              <div style={{ display: 'flex', alignItems: 'center', gap: '.5rem' }}>
                <input
                  {...form.register(fieldName)}
                  id={fieldName}
                  type="checkbox"
                  style={{
                    width: '1rem',
                    height: '1rem',
                    cursor: 'pointer',
                  }}
                />
                <label htmlFor={fieldName} style={{ cursor: 'pointer', margin: 0, fontWeight: 'normal' }}>
                  {title}
                </label>
              </div>
            )}

            {fieldType === 'date' && (
              <input
                {...form.register(fieldName)}
                id={fieldName}
                type="date"
                style={{
                  ...commonInputStyles,
                  borderColor: fieldError ? '#ef4444' : '#cbd5e1',
                } as React.CSSProperties}
              />
            )}

            {fieldError && (
              <p
                style={{
                  marginTop: '.25rem',
                  fontSize: '.85rem',
                  color: '#ef4444',
                }}
              >
                {typeof fieldError.message === 'string' ? fieldError.message : 'Invalid field'}
              </p>
            )}
          </div>
        )
      })}

      <button
        type="submit"
        disabled={isSubmitting}
        style={{
          width: '100%',
          padding: '.75rem 1rem',
          background: '#2563eb',
          color: '#fff',
          border: 'none',
          borderRadius: '4px',
          cursor: isSubmitting ? 'not-allowed' : 'pointer',
          opacity: isSubmitting ? 0.7 : 1,
          fontSize: '.9rem',
          fontWeight: 500,
        }}
      >
        {isSubmitting ? 'Submitting…' : submitLabel}
      </button>
    </form>
  )
}
