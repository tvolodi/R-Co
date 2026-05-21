import { client } from './client'
import type { Task, CompleteTaskRequest, CursorPage, TaskStatus } from '@/types/api'

export const tasksApi = {
  list: (params?: {
    status?: TaskStatus
    assignee_ref?: string
    instance_id?: string
    cursor?: string
    page_size?: number
  }) =>
    client.get<CursorPage<Task>>('/api/v1/tasks', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<Task>(`/api/v1/tasks/${id}`),

  complete: (id: string, body: CompleteTaskRequest) =>
    client.post<Task>(`/api/v1/tasks/${id}/complete`, body),

  reassign: (id: string, assigneeRef: string) =>
    client.post<Task>(`/api/v1/tasks/${id}/reassign`, { assignee_ref: assigneeRef }),

  /** Inbox: pending tasks for the calling user */
  inbox: (params?: { cursor?: string; page_size?: number }) =>
    client.get<CursorPage<Task>>('/api/v1/tasks/inbox', params as Record<string, unknown>),
}
