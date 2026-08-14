/** Field factory: JSON Schema field → React form component (TK-UI-03 / GRD-UI-07)
 *
 *  Renders label, input(s), and a hint/error node per field. Each input
 *  carries the ARIA attribute set:
 *    aria-required        — set when the field is required (omitted otherwise)
 *    aria-describedby     — space-separated list of hint node ids
 *    aria-invalid="true"  — set when errorMessage is non-null
 *    aria-errormessage    — id of the error node (when invalid)
 *
 *  Custom field types registered via fieldRegistry (CMP-UI-05) are routed
 *  here; unknown types fall through to the built-in switch below.
 */

import type { ReactNode, CSSProperties } from 'react'
import type { UseFormRegisterReturn } from 'react-hook-form'
import type { TaskFormField } from '@/types/forms'
import { fieldRegistry, type FieldTypeRenderer } from './fieldRegistry'
import { hintId, errorId, joinHintIds } from './ariaHints'

export function renderFormField(
  fieldName: string,
  fieldDef: TaskFormField,
  _value: unknown,
  _watchValue: unknown,
  register: UseFormRegisterReturn,
  errorMessage?: string,
): ReactNode {
  const fieldType = fieldDef.type || 'string'
  const isRequired = Boolean(fieldDef.required)
  const title = fieldDef.title || fieldName
  const description = fieldDef.description
  const placeholder = fieldDef.placeholder || `Enter ${title.toLowerCase()}`

  const commonStyles: CSSProperties = {
    width: '100%',
    padding: '.5rem .75rem',
    border: '1px solid #cbd5e1',
    borderRadius: '4px',
    fontSize: '.9rem',
    fontFamily: 'inherit',
    boxSizing: 'border-box',
  }

  const errorStyles: CSSProperties = errorMessage ? { borderColor: '#ef4444' } : {}

  const ariaRequired = isRequired
  const ariaInvalid = Boolean(errorMessage)
  const ariaDescribedBy = joinHintIds([description ? hintId(fieldName) : null])
  const ariaErrorMessage = ariaInvalid ? errorId(fieldName) : undefined

  // ── Registry routing (CMP-UI-05) ────────────────────────────────────────────
  const renderer: FieldTypeRenderer | undefined = fieldRegistry.get(fieldType)
  if (renderer) {
    const element = renderer.renderInput({
      fieldName,
      fieldDef,
      register,
      ariaDescribedBy,
      ariaErrorMessage,
      ariaRequired,
    })
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
          {isRequired && (
            <span style={{ color: '#ef4444', marginLeft: '.25rem' }}>*</span>
          )}
        </label>

        {description && (
          <p
            id={hintId(fieldName)}
            style={{ margin: '0.25rem 0 0.5rem 0', fontSize: '.85rem', color: '#64748b' }}
          >
            {description}
          </p>
        )}

        {element}

        {ariaInvalid && ariaErrorMessage && (
          <p
            id={ariaErrorMessage}
            role="alert"
            style={{ marginTop: '.25rem', fontSize: '.85rem', color: '#ef4444' }}
          >
            {errorMessage}
          </p>
        )}
      </div>
    )
  }

  // ── Default built-in renderer (the existing switch) ────────────────────────
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
        <p
          id={hintId(fieldName)}
          style={{ margin: '0.25rem 0 0.5rem 0', fontSize: '.85rem', color: '#64748b' }}
        >
          {description}
        </p>
      )}

      {fieldType === 'string' && !fieldDef.widget && !fieldDef.enum && (
        <input
          {...register}
          id={fieldName}
          type={
            fieldDef.format === 'email'
              ? 'email'
              : fieldDef.format === 'date'
                ? 'date'
                : fieldDef.format === 'date-time'
                  ? 'datetime-local'
                  : 'text'
          }
          placeholder={placeholder}
          aria-required={ariaRequired ? 'true' : undefined}
          aria-describedby={ariaDescribedBy}
          aria-invalid={ariaInvalid ? 'true' : undefined}
          aria-errormessage={ariaErrorMessage}
          style={{ ...commonStyles, ...errorStyles }}
        />
      )}

      {fieldType === 'string' && fieldDef.widget === 'textarea' && (
        <textarea
          {...register}
          id={fieldName}
          placeholder={placeholder}
          rows={4}
          aria-required={ariaRequired ? 'true' : undefined}
          aria-describedby={ariaDescribedBy}
          aria-invalid={ariaInvalid ? 'true' : undefined}
          aria-errormessage={ariaErrorMessage}
          style={{ ...commonStyles, ...errorStyles, resize: 'vertical' }}
        />
      )}

      {fieldType === 'string' && fieldDef.enum && (
        <select
          {...register}
          id={fieldName}
          aria-required={ariaRequired ? 'true' : undefined}
          aria-describedby={ariaDescribedBy}
          aria-invalid={ariaInvalid ? 'true' : undefined}
          aria-errormessage={ariaErrorMessage}
          style={{ ...commonStyles, ...errorStyles }}
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
          aria-required={ariaRequired ? 'true' : undefined}
          aria-describedby={ariaDescribedBy}
          aria-invalid={ariaInvalid ? 'true' : undefined}
          aria-errormessage={ariaErrorMessage}
          style={{ ...commonStyles, ...errorStyles }}
        />
      )}

      {fieldType === 'boolean' && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '.5rem' }}>
          <input
            {...register}
            id={fieldName}
            type="checkbox"
            aria-required={ariaRequired ? 'true' : undefined}
            aria-describedby={ariaDescribedBy}
            aria-invalid={ariaInvalid ? 'true' : undefined}
            aria-errormessage={ariaErrorMessage}
            style={{ width: '1rem', height: '1rem', cursor: 'pointer' }}
          />
          <label
            htmlFor={fieldName}
            style={{ cursor: 'pointer', margin: 0, fontWeight: 'normal' }}
          >
            {title}
          </label>
        </div>
      )}

      {fieldType === 'date' && (
        <input
          {...register}
          id={fieldName}
          type="date"
          aria-required={ariaRequired ? 'true' : undefined}
          aria-describedby={ariaDescribedBy}
          aria-invalid={ariaInvalid ? 'true' : undefined}
          aria-errormessage={ariaErrorMessage}
          style={{ ...commonStyles, ...errorStyles }}
        />
      )}

      {fieldType === 'select' && fieldDef.enum && (
        <select
          {...register}
          id={fieldName}
          aria-required={ariaRequired ? 'true' : undefined}
          aria-describedby={ariaDescribedBy}
          aria-invalid={ariaInvalid ? 'true' : undefined}
          aria-errormessage={ariaErrorMessage}
          style={{ ...commonStyles, ...errorStyles }}
        >
          <option value="">Select option</option>
          {fieldDef.enum.map((option: string | number) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </select>
      )}

      {ariaInvalid && ariaErrorMessage && (
        <p
          id={ariaErrorMessage}
          role="alert"
          style={{ marginTop: '.25rem', fontSize: '.85rem', color: '#ef4444' }}
        >
          {errorMessage}
        </p>
      )}
    </div>
  )
}
