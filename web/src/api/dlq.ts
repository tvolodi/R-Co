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
  list: (params?: { search?: string; status?: string }) =>
    client.get<{ items?: WebhookSubscription[] } | WebhookSubscription[]>('/api/v1/webhooks/subscriptions', params),

  create: (body: { target_url: string; secret?: string | null; event_types: string[] }) =>
    client.post<WebhookSubscription>('/api/v1/webhooks/subscriptions', body),

  update: (id: string, body: Partial<{ target_url: string; event_types: string[]; is_active: boolean; status: 'ACTIVE' | 'PAUSED' }>) =>
    client.patch<WebhookSubscription>(`/api/v1/webhooks/subscriptions/${id}`, body),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/webhooks/subscriptions/${id}`),
}
