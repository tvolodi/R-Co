/** fieldRegistry — GRD-UI-07 (CMP-UI-05 contract)
 *
 *  Maps a custom field type to a renderer that produces the input element
 *  WITH the ARIA attributes the FieldFactory will set. FieldFactory looks
 *  up `fieldRegistry.get(fieldDef.type)`; on miss it falls through to
 *  `defaultBuiltinRenderer` (the existing renderFormField switch).
 */

import type { ReactNode } from 'react'
import type { UseFormRegisterReturn } from 'react-hook-form'
import type { TaskFormField } from '@/types/forms'

export interface RenderInputArgs {
  fieldName: string
  fieldDef: TaskFormField
  register: UseFormRegisterReturn
  ariaDescribedBy?: string
  ariaErrorMessage?: string
  ariaRequired?: boolean
}

export type AriaAttributeName =
  | 'aria-required'
  | 'aria-describedby'
  | 'aria-invalid'
  | 'aria-errormessage'

export interface FieldTypeRenderer {
  /** Renders the field's input element(s) WITHOUT the label or hint/error wrappers. */
  renderInput: (args: RenderInputArgs) => ReactNode
  /** The attributes the builtin would set, so the FieldFactory can decorate it. */
  requiredAriaAttributes: ReadonlyArray<AriaAttributeName>
}

/** Empty registry — populated by app code (CMP-UI-05 batches register here). */
export const fieldRegistry: Map<string, FieldTypeRenderer> = new Map()

/**
 * Sentinel marker so the test harness can prove the registry wiring exists.
 * Adding to the registry is intentionally additive; the existing built-in
 * FieldFactory switch continues to be the fall-through renderer.
 */
export const FIELD_REGISTRY_SENTINEL_KEY = '__field_registry_sentinel__'
