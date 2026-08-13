/** aria-validator — GRD-UI-07 §4.2
 *
 *  Dangling-reference detector: for every `aria-errormessage` reference
 *  present on a rendered element, the corresponding target id MUST exist
 *  in the DOM at the same moment. The validator runs in unit tests
 *  (against a jsdom document) and from the E2E harness.
 */

export interface DanglingReference {
  fieldKey: string
  ariaInvalid: string
  ariaErrorMessage: string
  attribute: 'aria-errormessage'
}

export function detectDanglingAriaReferences(
  root: ParentNode,
  options: { fieldKeyAttr?: string } = {},
): DanglingReference[] {
  const fieldKeyAttr = options.fieldKeyAttr ?? 'data-field-key'
  const elements = root.querySelectorAll<HTMLElement>('[aria-invalid="true"]')
  const dangling: DanglingReference[] = []
  for (const el of Array.from(elements)) {
    const targetId = el.getAttribute('aria-errormessage')
    if (!targetId) {
      dangling.push({
        fieldKey: el.getAttribute(fieldKeyAttr) ?? el.id ?? '<unknown>',
        ariaInvalid: 'true',
        ariaErrorMessage: '',
        attribute: 'aria-errormessage',
      })
      continue
    }
    // NOTE: jsdom does not implement CSS.escape. We use a plain
    // attribute selector; field-name id components are constrained to
    // safe identifier characters (see ariaHints.ts: hintId/errorId),
    // so no escaping is required for our own references.
    const target = root.querySelector(`[id="${targetId}"]`)
    if (!target) {
      dangling.push({
        fieldKey: el.getAttribute(fieldKeyAttr) ?? el.id ?? '<unknown>',
        ariaInvalid: 'true',
        ariaErrorMessage: targetId,
        attribute: 'aria-errormessage',
      })
    }
  }
  return dangling
}
