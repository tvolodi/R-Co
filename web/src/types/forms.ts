/** Form rendering types for dynamic schema-driven forms (Stage F4) */

export interface TaskFormField {
  name: string
  type: 'string' | 'number' | 'boolean' | 'date' | 'select' | 'object' | 'array'
  title?: string
  description?: string
  required: boolean

  // Type-specific metadata
  enum?: string[] | number[]
  minLength?: number
  maxLength?: number
  pattern?: string
  minimum?: number
  maximum?: number
  multipleOf?: number
  format?: 'date' | 'date-time' | 'time' | 'email' | 'uri'

  // Nested structures
  properties?: Record<string, TaskFormField>
  items?: TaskFormField
  additionalProperties?: boolean

  // UI hints
  placeholder?: string
  widget?: 'textarea' | 'code-editor' | 'rich-text'
}

export interface ValidationError {
  field: string // dot-path: "firstName", "address.street", "items.0.name"
  message: string
}

export interface DynamicFormValue {
  [key: string]: string | number | boolean | Date | DynamicFormValue | DynamicFormValue[] | null
}
