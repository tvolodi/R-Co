/** TanStack Query hooks — query key factories + hooks for all APIs */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { definitionsApi } from '@/api/definitions'
import type { DefinitionStatus, CreateDefinitionRequest } from '@/types/api'

export const definitionKeys = {
  all: ['definitions'] as const,
  list: (filters: object) => [...definitionKeys.all, 'list', filters] as const,
  detail: (id: string) => [...definitionKeys.all, 'detail', id] as const,
  active: (name: string) => [...definitionKeys.all, 'active', name] as const,
}

export function useDefinitions(params?: { status?: DefinitionStatus; name?: string }) {
  return useQuery({
    queryKey: definitionKeys.list(params ?? {}),
    queryFn: () => definitionsApi.list(params),
  })
}

export function useDefinition(id: string) {
  return useQuery({
    queryKey: definitionKeys.detail(id),
    queryFn: () => definitionsApi.get(id),
    enabled: !!id,
  })
}

export function useCreateDefinition() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: CreateDefinitionRequest) => definitionsApi.create(body),
    onSuccess: () => qc.invalidateQueries({ queryKey: definitionKeys.all }),
  })
}

export function useDefinitionVersions(name: string) {
  return useQuery({
    queryKey: [...definitionKeys.all, 'versions', name],
    queryFn: () => definitionsApi.getVersions(name),
    enabled: !!name,
  })
}

export function useActivateDefinition() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => definitionsApi.activate(id),
    onSuccess: (_data, id) => {
      qc.invalidateQueries({ queryKey: definitionKeys.detail(id) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
    },
  })
}

export function useArchiveDefinition() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => definitionsApi.archive(id),
    onSuccess: (_data, id) => {
      qc.invalidateQueries({ queryKey: definitionKeys.detail(id) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
    },
  })
}
