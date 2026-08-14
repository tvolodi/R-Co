/** definitionDraftStore — RND-UI-06
 *
 *  Per-definition draft retention. The ConflictResolver reads localDraft from
 *  here but NEVER mutates it. The store is mutated by:
 *    - the Definition Editor on every keystroke (setDraft),
 *    - onDiscardConfirmed (clearDraft),
 *    - onSaveMerged (setDraft with new savedAt).
 */

import { create } from 'zustand'

export interface DefinitionDraft {
  definitionId: string
  body: Record<string, unknown>
  dirtyFieldKeys: string[]
  savedAt: string | null // ISO timestamp of last successful save
}

interface DefinitionDraftStore {
  draft: DefinitionDraft | null
  setDraft: (d: DefinitionDraft) => void
  clearDraft: (definitionId: string) => void
}

export const useDefinitionDraftStore = create<DefinitionDraftStore>((set) => ({
  draft: null,
  setDraft: (d) => set({ draft: d }),
  clearDraft: (definitionId) =>
    set((state) => (state.draft?.definitionId === definitionId ? { draft: null } : state)),
}))

// Test-only escape hatch for E2E access to the underlying store from window.
if (typeof window !== 'undefined') {
  (window as unknown as { __ZUSTAND_DRAFT__?: typeof useDefinitionDraftStore }).__ZUSTAND_DRAFT__ =
    useDefinitionDraftStore
}
