import type { TimelineEntry } from '@/types/api'

export function getTimelineActorDisplayName(actorDisplayName: string | null | undefined): string {
  const normalized = (actorDisplayName ?? '').trim()
  return normalized.length > 0 ? normalized : 'system'
}

export function getTimelineSecondaryContext(entry: TimelineEntry): string {
  const parts: string[] = []

  if (entry.node_id) {
    parts.push(`Node ${entry.node_id}`)
  }

  if (entry.task_id) {
    parts.push(`Task ${entry.task_id}`)
  }

  return parts.join(' • ')
}

export function mergeTimelineItems(
  currentItems: TimelineEntry[],
  incomingItems: TimelineEntry[],
  cursor: string | undefined,
): TimelineEntry[] {
  return cursor ? [...currentItems, ...incomingItems] : incomingItems
}
