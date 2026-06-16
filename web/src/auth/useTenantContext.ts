import { useAuth } from './AuthContext'

export interface TenantContextValue {
  tenantSlug: string | null
  tenantDisplayName: string
  isUnknown: boolean
}

export function useTenantContext(): TenantContextValue {
  const { session } = useAuth()
  const tenantSlug = session?.tenant_slug ?? null
  const raw = session?.tenant_display_name ?? null
  const isUnknown = raw === null
  return {
    tenantSlug,
    tenantDisplayName: raw ?? 'Unknown workspace',
    isUnknown,
  }
}
