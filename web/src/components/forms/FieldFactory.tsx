/** Field factory: JSON Schema field → React form component (TK-UI-03) */

import type { UseFormRegisterReturn } from 'react-hook-form'
import type { TaskFormField } from '@/types/forms'

export function renderFormField(
  fieldName: string,
  fieldDef: TaskFormField,
  _value: unknown,
  _watchValue: unknown,
  register: UseFormRegisterReturn,
  errorMessage?: string,
): React.ReactNode {
  const fieldType = fieldDef.type || 'string'
  const isRequired = fieldDef.required || false
  const title = fieldDef.title || fieldName
  const description = fieldDef.description
  const placeholder = fieldDef.placeholder || `Enter ${title.toLowerCase()}`

  const commonStyles = {
    width: '100%',
    padding: '.5rem .75rem',
    border: '1px solid #cbd5e1',
    borderRadius: '4px',
    fontSize: '.9rem',
    fontFamily: 'inherit',
    boxSizing: 'border-box' as const,
  }

  const errorStyles = errorMessage
    ? { borderColor: '#ef4444' }
    : {}

  return (
    <div style={{ marginBottom: '1rem' }}>
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
          {...register}
          id={fieldName}
          type={fieldDef.format === 'email' ? 'email' : fieldDef.format === 'date' ? 'date' : fieldDef.format === 'date-time' ? 'datetime-local' : 'text'}
          placeholder={placeholder}
          style={{
            ...commonStyles,
            ...errorStyles,
          } as React.CSSProperties}
        />
      )}

      {fieldType === 'string' && fieldDef.widget === 'textarea' && (
        <textarea
          {...register}
          id={fieldName}
          placeholder={placeholder}
          rows={4}
          style={{
            ...commonStyles,
            ...errorStyles,
            resize: 'vertical',
          } as React.CSSProperties}
        />
      )}

      {fieldType === 'string' && fieldDef.enum && (
        <select
          {...register}
          id={fieldName}
          style={{
            ...commonStyles,
            ...errorStyles,
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
          {...register}
          id={fieldName}
          type="number"
          placeholder={placeholder}
          style={{
            ...commonStyles,
            ...errorStyles,
          } as React.CSSProperties}
        />
      )}

      {fieldType === 'boolean' && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '.5rem' }}>
          <input
            {...register}
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
          {...register}
          id={fieldName}
          type="date"
          style={{
            ...commonStyles,
            ...errorStyles,
          } as React.CSSProperties}
        />
      )}

      {fieldType === 'select' && fieldDef.enum && (
        <select
          {...register}
          id={fieldName}
          style={{
            ...commonStyles,
            ...errorStyles,
          } as React.CSSProperties}
        >
          <option value="">Select option</option>
          {fieldDef.enum.map((option: string | number) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </select>
      )}

      {errorMessage && (
        <p
          style={{
            marginTop: '.25rem',
            fontSize: '.85rem',
            color: '#ef4444',
          }}
        >
          {errorMessage}
        </p>
      )}
    </div>
  )
}
