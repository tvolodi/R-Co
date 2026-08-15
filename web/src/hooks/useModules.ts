/** TanStack Query hooks — Process Module Catalog (PLC-01..04) */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { modulesApi } from '@/api/modules'
import { queryKeys } from '@/api/queryKeys'

export const moduleKeys = {
  all: queryKeys.modules.all,
  list: queryKeys.modules.list,
  detail: queryKeys.modules.detail,
  shares: queryKeys.modules.shares,
}

export function useModules(filters?: { cursor?: string; page_size?: number }) {
  return useQuery({
    queryKey: moduleKeys.list(filters),
    queryFn: () => modulesApi.list(filters),
  })
}

export function useModuleDetail(moduleId: string, version: string) {
  return useQuery({
    queryKey: moduleKeys.detail(moduleId, version),
    queryFn: () => modulesApi.get(moduleId, version),
    enabled: !!moduleId && !!version,
  })
}

export function useModuleShares(moduleId: string) {
  return useQuery({
    queryKey: moduleKeys.shares(moduleId),
    queryFn: () => modulesApi.listShares(moduleId),
    enabled: !!moduleId,
  })
}

export function usePublishModule() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ moduleId, version }: { moduleId: string; version: string }) =>
      modulesApi.publish(moduleId, version),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: moduleKeys.all })
    },
  })
}

export function useGrantModuleShare() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: {
      granting_tenant_id: string
      module_id: string
      receiving_tenant_id: string
    }) => modulesApi.grantShare(body),
    onSuccess: (_data, vars) => {
      qc.invalidateQueries({ queryKey: moduleKeys.shares(vars.module_id) })
    },
  })
}

export function useRevokeModuleShare() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (vars: { grantId: string; moduleId: string }) =>
      modulesApi.revokeShare(vars.grantId),
    onSuccess: (_data, vars) => {
      qc.invalidateQueries({ queryKey: moduleKeys.shares(vars.moduleId) })
    },
  })
}
