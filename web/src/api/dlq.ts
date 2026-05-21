import { client } from './client'
import type { DlqEntry, WebhookSubscription, PagedResponse } from '@/types/api'

export const dlqApi = {
  list: (params?: { status?: string; page?: number; page_size?: number }) =>
    client.get<PagedResponse<DlqEntry>>('/api/v1/dlq', params as Record<string, unknown>),

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
