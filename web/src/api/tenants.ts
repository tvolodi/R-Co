import { client } from './client'

export interface Tenant {
  slug: string
  display_name: string
  idp_realm_id: string
  hostname: string
  redirect_uris: string[]
  status: 'ACTIVE' | 'INACTIVE'
  created_at: string
}

export interface TenantListResponse {
  items: Tenant[]
  total: number
  limit: number
  offset: number
}

export const tenantsApi = {
  list: (params?: { search?: string; limit?: number; offset?: number }) =>
    client.get<TenantListResponse>('/api/v1/tenants', params as Record<string, unknown>),

  getBySlug: (slug: string) =>
    client.get<Tenant>(`/api/v1/tenants/${slug}`),

  patch: (slug: string, body: Partial<{ display_name: string; hostname: string; redirect_uris: string[] }>) =>
    client.patch<Tenant>(`/api/v1/tenants/${slug}`, body),
}
