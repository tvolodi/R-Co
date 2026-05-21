import { client } from './client'
import type {
  ProcessInstance,
  StartInstanceRequest,
  CursorPage,
  InstanceStatus,
  EventRecord,
} from '@/types/api'

export const instancesApi = {
  list: (params?: {
    status?: InstanceStatus
    definition_id?: string
    cursor?: string
    page_size?: number
  }) =>
    client.get<CursorPage<ProcessInstance>>('/api/v1/instances', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<ProcessInstance>(`/api/v1/instances/${id}`),

  start: (body: StartInstanceRequest) =>
    client.post<ProcessInstance>('/api/v1/instances', body),

  cancel: (id: string, reason?: string) =>
    client.post<void>(`/api/v1/instances/${id}/cancel`, { reason }),

  events: (id: string, params?: { after_seq?: number; before_seq?: number; limit?: number }) =>
    client.get<EventRecord[]>(`/api/v1/instances/${id}/events`, params as Record<string, unknown>),

  reconstruct: (id: string) =>
    client.get<ProcessInstance>(`/api/v1/instances/${id}/reconstruct`),
}
