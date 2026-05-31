import { client } from './client'
import type {
  CursorPage,
  DlqEntry,
  WebhookDeliveryAttempt,
  WebhookDeliveryAttemptListResponse,
  WebhookSubscription,
} from '@/types/api'

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function parseDeliveryAttempt(item: unknown): WebhookDeliveryAttempt {
  if (!isRecord(item)) {
    throw new Error('WebhookDeliveryLogContractMismatch')
  }

  const deliveryId = item.delivery_id
  const subscriptionId = item.subscription_id
  const eventType = item.event_type
  const status = item.status
  const attemptedAt = item.attempted_at
  const attemptCount = item.attempt_count
  const maxAttempts = item.max_attempts
  const httpStatusCode = item.http_status_code
  const lastError = item.last_error

  if (
    typeof deliveryId !== 'string' ||
    typeof subscriptionId !== 'string' ||
    typeof eventType !== 'string' ||
    (status !== 'SUCCESS' && status !== 'FAILED') ||
    typeof attemptedAt !== 'string' ||
    typeof attemptCount !== 'number' ||
    typeof maxAttempts !== 'number' ||
    !(httpStatusCode === null || typeof httpStatusCode === 'number') ||
    !(lastError === undefined || lastError === null || typeof lastError === 'string')
  ) {
    throw new Error('WebhookDeliveryLogContractMismatch')
  }

  return {
    delivery_id: deliveryId,
    subscription_id: subscriptionId,
    event_type: eventType,
    status,
    http_status_code: httpStatusCode,
    attempted_at: attemptedAt,
    attempt_count: attemptCount,
    max_attempts: maxAttempts,
    last_error: lastError,
  }
}

function parseDeliveryAttemptsResponse(payload: unknown): WebhookDeliveryAttemptListResponse {
  if (!isRecord(payload) || !Array.isArray(payload.items)) {
    throw new Error('WebhookDeliveryLogContractMismatch')
  }

  return {
    items: payload.items.map(parseDeliveryAttempt),
  }
}

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
    client.get<{ items: WebhookSubscription[] }>('/api/v1/webhooks/subscriptions'),

  create: (body: { target_url: string; secret?: string | null; description?: string; event_types?: string[] }) =>
    client.post<WebhookSubscription>('/api/v1/webhooks/subscriptions', body),

  update: (id: string, body: Partial<{ status: 'ACTIVE' | 'PAUSED'; is_active: boolean }>) =>
    client.patch<WebhookSubscription>(`/api/v1/webhooks/subscriptions/${id}`, body),

  getDeliveries: async (subscriptionId: string, params?: { limit?: number }) =>
    parseDeliveryAttemptsResponse(
      await client.get<unknown>(`/api/v1/webhooks/subscriptions/${subscriptionId}/deliveries`, params as Record<string, unknown> | undefined),
    ),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/webhooks/subscriptions/${id}`),
}
