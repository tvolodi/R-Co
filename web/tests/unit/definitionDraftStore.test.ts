/**
 * Unit tests — RND-UI-06: definitionDraftStore
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { useDefinitionDraftStore } from '@/stores/definitionDraftStore'

describe('RND-UI-06 — definitionDraftStore', () => {
  beforeEach(() => {
    useDefinitionDraftStore.setState({ draft: null })
  })

  it('TC-DDS-01: initial state is null draft', () => {
    expect(useDefinitionDraftStore.getState().draft).toBeNull()
  })

  it('TC-DDS-02: setDraft stores the draft', () => {
    useDefinitionDraftStore.getState().setDraft({
      definitionId: 'def-1',
      body: { name: 'x' },
      dirtyFieldKeys: ['name'],
      savedAt: null,
    })
    expect(useDefinitionDraftStore.getState().draft?.definitionId).toBe('def-1')
  })

  it('TC-DDS-03: clearDraft removes the draft for the matching id', () => {
    useDefinitionDraftStore.getState().setDraft({
      definitionId: 'def-1',
      body: {},
      dirtyFieldKeys: [],
      savedAt: null,
    })
    useDefinitionDraftStore.getState().clearDraft('def-1')
    expect(useDefinitionDraftStore.getState().draft).toBeNull()
  })

  it('TC-DDS-04: clearDraft is a no-op when ids do not match', () => {
    useDefinitionDraftStore.getState().setDraft({
      definitionId: 'def-1',
      body: {},
      dirtyFieldKeys: [],
      savedAt: null,
    })
    useDefinitionDraftStore.getState().clearDraft('def-2')
    expect(useDefinitionDraftStore.getState().draft).not.toBeNull()
  })
})
