/**
 * CelExpressionEditor — CodeMirror 6 wrapper with CEL syntax highlighting
 *
 * Replaces the plain <textarea> for CEL expression editing.
 * Features:
 *  - CEL syntax highlighting (keywords, types, strings, numbers, operators)
 *  - Bracket matching (closeBrackets)
 *  - Line numbers
 *  - Inline server error display
 */

import CodeMirror from '@uiw/react-codemirror'
import { closeBrackets } from '@codemirror/autocomplete'
import { bracketMatching } from '@codemirror/language'
import { EditorView } from '@codemirror/view'
import { celLanguage } from '@/utils/cel/celLanguage'

// ── Props ─────────────────────────────────────────────────────────────────────

interface CelExpressionEditorProps {
  value: string
  onChange: (value: string) => void
  disabled?: boolean
  serverError?: string | null
  placeholder?: string
  minHeight?: string
}

// ── CM6 Extensions ────────────────────────────────────────────────────────────

const celExtensions = [
  celLanguage,
  closeBrackets(),
  bracketMatching(),
  EditorView.lineWrapping,
]

// ── Component ─────────────────────────────────────────────────────────────────

export default function CelExpressionEditor({
  value,
  onChange,
  disabled = false,
  serverError = null,
  placeholder = "e.g. status == 'approved'",
  minHeight = '80px',
}: CelExpressionEditorProps) {
  const editorId = 'cel-expression-editor'
  const errorId = `${editorId}-error`

  return (
    <div>
      <CodeMirror
        id={editorId}
        data-testid="cel-expression-editor"
        value={value}
        onChange={(val) => onChange(val)}
        extensions={celExtensions}
        editable={!disabled}
        placeholder={placeholder}
        aria-describedby={serverError ? errorId : undefined}
        aria-invalid={serverError ? true : undefined}
        basicSetup={{
          lineNumbers: true,
          foldGutter: false,
          highlightActiveLine: false,
          highlightActiveLineGutter: false,
        }}
        style={{
          minHeight,
          border: `1px solid ${serverError ? 'var(--border-error, #fa5252)' : 'var(--border-default, #e9ecef)'}`,
          borderRadius: 4,
          fontSize: 'var(--text-sm, 0.875rem)',
          fontFamily: 'var(--font-mono, monospace)',
          opacity: disabled ? 0.6 : 1,
        }}
        theme={EditorView.theme({
          '&': { backgroundColor: disabled ? 'var(--color-neutral-50, #f8f9fa)' : '#fff' },
          '.cm-content': {
            caretColor: disabled ? 'transparent' : 'auto',
          },
          '.cm-placeholder': {
            color: 'var(--text-disabled, #ced4da)',
            fontFamily: 'var(--font-mono, monospace)',
            fontSize: 'var(--text-sm, 0.875rem)',
          },
          '.cm-gutters': {
            backgroundColor: 'var(--color-neutral-50, #f8f9fa)',
            borderRight: '1px solid var(--border-default, #e9ecef)',
          },
          '.cm-activeLineGutter': {
            backgroundColor: 'var(--color-neutral-100, #f1f3f5)',
          },
        })}
      />

      {/* Inline server error display */}
      {serverError && (
        <div
          id={errorId}
          role="alert"
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 6,
            marginTop: 4,
            padding: '4px 8px',
            fontSize: 'var(--text-xs, 0.75rem)',
            color: 'var(--color-error-dark, #c92a2a)',
            background: 'var(--color-error-light, #ffe3e3)',
            borderRadius: 4,
          }}
        >
          <span role="img" aria-hidden="true">&#x26A0;&#xFE0F;</span>
          <span>{serverError}</span>
        </div>
      )}
    </div>
  )
}
