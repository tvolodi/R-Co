import { client } from './client'
import type { DlqEntry, WebhookSubscription, CursorPage } from '@/types/api'

export const dlqApi = {
  list: (params?: {
    status?: string
    source_type?: string
    search?: string
    cursor?: string
    page_size?: number
    instance_id?: string
  }) =>
    client.get<CursorPage<DlqEntry>>('/api/v1/dlq', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<DlqEntry>(`/api/v1/dlq/${id}`),

  retry: (id: string) =>
    client.post<DlqEntry>(`/api/v1/dlq/${id}/retry`),

  discard: (id: string) =>
    client.post<DlqEntry>(`/api/v1/dlq/${id}/discard`),
}

export const webhooksApi = {
  list: () =>
    client.get<WebhookSubscription[]>('/api/v1/webhooks'),

  create: (body: { url: string; secret: string; description?: string; event_types?: string[] }) =>
    client.post<WebhookSubscription>('/api/v1/webhooks', body),

  update: (id: string, body: Partial<{ url: string; event_types: string[]; is_active: boolean }>) =>
    client.patch<WebhookSubscription>(`/api/v1/webhooks/${id}`, body),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/webhooks/${id}`),
}
