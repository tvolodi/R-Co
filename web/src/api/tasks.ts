import { client } from './client'
import type { Task, CompleteTaskRequest, CursorPage, TaskStatus } from '@/types/api'

// Backend sends `task_id` but the frontend Task type uses `id`.
// Normalize at the API boundary so all callers can use task.id safely.
type RawTask = Omit<Task, 'id' | 'created_at' | 'updated_at'> & {
  task_id?: string
  id?: string
  created_at: string | number
  updated_at?: string | number
}

function normalizeTask(raw: RawTask): Task {
  const id = raw.id ?? raw.task_id ?? ''
  const created_at =
    typeof raw.created_at === 'number'
      ? new Date(raw.created_at / 1000).toISOString()
      : (raw.created_at as string)
  const updated_at =
    typeof raw.updated_at === 'number'
      ? new Date(raw.updated_at / 1000).toISOString()
      : raw.updated_at
  return { ...(raw as unknown as Task), id, created_at, updated_at }
}

function normalizeTaskPage(page: CursorPage<RawTask>): CursorPage<Task> {
  return { ...page, items: page.items.map(normalizeTask) }
}

export const tasksApi = {
  list: (params?: {
    status?: TaskStatus
    assignee_ref?: string
    instance_id?: string
    cursor?: string
    page_size?: number
  }) =>
    client
      .get<CursorPage<RawTask>>('/api/v1/tasks', params as Record<string, unknown>)
      .then(normalizeTaskPage),

  get: (id: string) =>
    client.get<RawTask>(`/api/v1/tasks/${id}`).then(normalizeTask),

  complete: (id: string, body: CompleteTaskRequest) =>
    client.post<RawTask>(`/api/v1/tasks/${id}/complete`, body).then(normalizeTask),

  assign: (id: string) =>
    client.post<RawTask>(`/api/v1/tasks/${id}/assign`, {}).then(normalizeTask),

  reassign: (id: string, assigneeRef: string) =>
    client
      .post<RawTask>(`/api/v1/tasks/${id}/reassign`, { assignee_ref: assigneeRef })
      .then(normalizeTask),

  /** Inbox: pending tasks for the calling user */
  inbox: (params?: { cursor?: string; page_size?: number }) =>
    client
      .get<CursorPage<RawTask>>('/api/v1/tasks/inbox', params as Record<string, unknown>)
      .then(normalizeTaskPage),
}
