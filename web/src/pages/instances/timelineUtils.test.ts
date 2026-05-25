import { describe, expect, it } from 'vitest'
import {
  getTimelineActorDisplayName,
  getTimelineSecondaryContext,
  mergeTimelineItems,
} from './timelineUtils'
import type { TimelineEntry } from '@/types/api'

function makeEntry(overrides: Partial<TimelineEntry> = {}): TimelineEntry {
  return {
    event_type: 'TASK_COMPLETED',
    timestamp: '2026-05-25T11:20:40Z',
    actor_display_name: 'Alice Kim',
    description: 'Task review completed by Alice Kim',
    instance_id: 'd5a8b7c6-5a9c-4d95-b2cf-706b9395666f',
    event_id: '7ccf1f98-0cb5-4df4-a9dc-fd57e7d53ac3',
    sequence_num: 88,
    task_id: '759b66fe-e6c6-47d4-af61-97d5e5ccfe6a',
    node_id: 'task_review',
    metadata: {},
    ...overrides,
  }
}

describe('timelineUtils', () => {
  it('falls back to system when actor display name is blank', () => {
    expect(getTimelineActorDisplayName('  ')).toBe('system')
    expect(getTimelineActorDisplayName(undefined)).toBe('system')
  })

  it('preserves non-empty actor display name', () => {
    expect(getTimelineActorDisplayName('  Jamie  ')).toBe('Jamie')
  })

  it('renders secondary context from node and task ids', () => {
    const entry = makeEntry()

    expect(getTimelineSecondaryContext(entry)).toBe('Node task_review • Task 759b66fe-e6c6-47d4-af61-97d5e5ccfe6a')
  })

  it('renders node-only secondary context', () => {
    const entry = makeEntry({ task_id: null })
    expect(getTimelineSecondaryContext(entry)).toBe('Node task_review')
  })

  it('renders empty secondary context when node and task are missing', () => {
    const entry = makeEntry({ task_id: null, node_id: null })
    expect(getTimelineSecondaryContext(entry)).toBe('')
  })

  it('replaces items on first page and appends items on load more', () => {
    const first = makeEntry({ event_id: 'first-event', sequence_num: 1 })
    const second = makeEntry({ event_id: 'second-event', sequence_num: 2 })
    const third = makeEntry({ event_id: 'third-event', sequence_num: 3 })

    const firstPage = mergeTimelineItems([first], [second], undefined)
    expect(firstPage.map((it) => it.event_id)).toEqual(['second-event'])

    const secondPage = mergeTimelineItems(firstPage, [third], 'TL:c1')
    expect(secondPage.map((it) => it.event_id)).toEqual(['second-event', 'third-event'])
  })
})
