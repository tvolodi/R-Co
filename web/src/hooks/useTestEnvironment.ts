import { useQuery } from '@tanstack/react-query'
import { tenantsApi } from '@/api/tenants'
import { queryKeys } from '@/api/queryKeys'

export interface TestEnvironmentContext {
  isTestTenant: boolean
  productionTenantName: string | null
  currentTenantSlug: string | null
  isLoading: boolean
}

export function useTestEnvironment(): TestEnvironmentContext {
  const { data, isLoading } = useQuery({
    queryKey: queryKeys.admin.tenantCurrent(),
    queryFn: () => tenantsApi.getCurrent(),
    staleTime: Infinity,
    retry: false,
    // Do not throw on error — return safe default instead
    throwOnError: false,
  })

  if (!data) {
    return { isTestTenant: false, productionTenantName: null, currentTenantSlug: null, isLoading }
  }

  const isTestTenant = data.tenant_type === 'test'
  return {
    isTestTenant,
    productionTenantName: isTestTenant ? (data.production_tenant_display_name ?? null) : null,
    currentTenantSlug: data.slug,
    isLoading,
  }
}
