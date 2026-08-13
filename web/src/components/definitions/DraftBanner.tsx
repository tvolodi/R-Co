/** DraftBanner — RND-UI-06
 *
 *  Non-modal banner rendered above the editor body when a draft is present
 *  (savedAt == null). Notifies the user that their changes are still in the
 *  Zustand store after a refetch and can be re-applied.
 */

import type { DefinitionDraft } from '@/stores/definitionDraftStore'

export interface DraftBannerProps {
  draft: DefinitionDraft
  onApply: () => void
  onDiscard: () => void
}

export function DraftBanner(props: DraftBannerProps): React.ReactElement {
  const { draft, onApply, onDiscard } = props
  const dirtyCount = draft.dirtyFieldKeys.length

  return (
    <div
      data-testid="draft-banner"
      role="region"
      aria-label="Unsaved local draft"
      style={{
        padding: '.85rem 1.1rem',
        background: '#eff6ff',
        border: '1px solid #bfdbfe',
        borderRadius: '6px',
        marginBottom: '1rem',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: '1rem',
        flexWrap: 'wrap',
      }}
    >
      <div>
        <p style={{ margin: 0, fontWeight: 500, color: '#1e3a8a', fontSize: '.9rem' }}>
          You have an unsaved local draft
        </p>
        <p style={{ margin: '.15rem 0 0', fontSize: '.8rem', color: '#3b82f6' }}>
          {dirtyCount === 0
            ? '1 field changed'
            : `${dirtyCount} fields changed`}
          {draft.savedAt ? ` · last saved ${new Date(draft.savedAt).toLocaleTimeString()}` : ''}
        </p>
      </div>
      <div style={{ display: 'flex', gap: '.5rem' }}>
        <button
          type="button"
          data-testid="draft-banner-apply"
          onClick={onApply}
          style={{
            padding: '.35rem .85rem',
            border: '1px solid #2563eb',
            borderRadius: '4px',
            background: '#fff',
            color: '#2563eb',
            cursor: 'pointer',
            fontSize: '.85rem',
          }}
        >
          Re-apply draft
        </button>
        <button
          type="button"
          data-testid="draft-banner-discard"
          onClick={onDiscard}
          style={{
            padding: '.35rem .85rem',
            border: '1px solid #dc2626',
            borderRadius: '4px',
            background: '#fff',
            color: '#dc2626',
            cursor: 'pointer',
            fontSize: '.85rem',
          }}
        >
          Discard draft
        </button>
      </div>
    </div>
  )
}
