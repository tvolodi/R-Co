import { client } from './client'
import type { CursorPage } from '@/types/api'

export type ServiceScope = 'global' | 'tenant'

export interface ServiceRecord {
  service_id: string
  endpoint_url: string
  request_schema: string
  response_schema: string
  required_auth: string
  timeout_ms: number
  max_retries: number
  scope: ServiceScope
  owner_tenant_id: string | null
  created_at: string
  updated_at: string
}

export interface RegisterServiceBody {
  service_id: string
  endpoint_url: string
  scope: ServiceScope
  owner_tenant_id?: string
  auth_method: string
  timeout_ms: number
  max_retries?: number
  request_schema: string
  response_schema: string
}

export interface UpdateServiceScopeBody {
  scope: ServiceScope
  owner_tenant_id?: string
}

export const servicesApi = {
  /** GET /api/v1/services — tenant-scoped list (any authenticated user) */
  listForTenant: (params?: Record<string, unknown>) =>
    client.get<CursorPage<ServiceRecord>>('/api/v1/services', params),

  /** GET /api/v1/admin/services — all entries (platform-admin only) */
  listAll: (params?: Record<string, unknown>) =>
    client.get<CursorPage<ServiceRecord>>('/api/v1/admin/services', params),

  /** POST /api/v1/admin/services — register new service (platform-admin only) */
  register: (body: RegisterServiceBody) =>
    client.post<ServiceRecord>('/api/v1/admin/services', body),

  /** PATCH /api/v1/admin/services/:service_id — update scope (platform-admin only) */
  updateScope: (serviceId: string, body: UpdateServiceScopeBody) =>
    client.patch<ServiceRecord>(`/api/v1/admin/services/${serviceId}`, body),

  /** DELETE /api/v1/admin/services/:service_id — remove service (platform-admin only) */
  delete: (serviceId: string) =>
    client.delete<void>(`/api/v1/admin/services/${serviceId}`),
}
