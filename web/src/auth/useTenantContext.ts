import { useAuth } from './AuthContext'

export interface TenantContextValue {
  tenantSlug: string | null
  tenantId: string | null
  tenantDisplayName: string
  isUnknown: boolean
  tenantType: 'production' | 'test' | null
  productionDisplayName: string | null
}

export function useTenantContext(): TenantContextValue {
  const { session } = useAuth()
  const tenantSlug = session?.tenant_slug ?? null
  const raw = session?.tenant_display_name ?? null
  const isUnknown = raw === null
  return {
    tenantSlug,
    tenantId: session?.tenant_id ?? null,
    tenantDisplayName: raw ?? 'Unknown workspace',
    isUnknown,
    tenantType: session?.tenant_type ?? null,
    productionDisplayName: session?.production_tenant_display_name ?? null,
  }
}
