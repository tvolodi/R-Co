import { client } from './client'

export interface Tenant {
  slug: string
  display_name: string
  idp_realm_id: string | null
  hostname?: string
  redirect_uris?: string[]
  status: 'ACTIVE' | 'INACTIVE'
  created_at: string
  // ENV-04 additions
  tenant_type: 'production' | 'test'
  production_tenant_id: string | null
  production_tenant_display_name: string | null
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

  deactivate: (slug: string) =>
    client.post<Tenant>(`/api/v1/tenants/${slug}/deactivate`, {}),

  reactivate: (slug: string) =>
    client.post<Tenant>(`/api/v1/tenants/${slug}/reactivate`, {}),

  getCurrent: () =>
    client.get<Tenant>('/api/v1/tenants/current'),

  promote: (testTenantId: string, definitionName: string) =>
    client.post<{ promoted_definition_id: string }>(
      `/api/v1/tenants/${testTenantId}/promote/${definitionName}`,
      {},
    ),
}
