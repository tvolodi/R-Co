/** TanStack Query hooks — query key factories + hooks for all APIs */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { definitionsApi } from '@/api/definitions'
import type { DefinitionStatus, CreateDefinitionRequest } from '@/types/api'
import { queryKeys } from '@/api/queryKeys'

export const definitionKeys = {
  all: queryKeys.definitions.all,
  list: queryKeys.definitions.list,
  detail: queryKeys.definitions.detail,
  active: queryKeys.definitions.active,
  search: queryKeys.definitions.search,
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
    queryKey: queryKeys.definitions.versions(name),
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

export function useDefinitionSearch(query: string, options?: { limit?: number; offset?: number }) {
  const limit = options?.limit ?? 20
  const offset = options?.offset ?? 0
  return useQuery({
    queryKey: definitionKeys.search(query, limit, offset),
    queryFn: () => definitionsApi.search({ q: query, limit, offset }),
    enabled: query.trim().length > 0,
  })
}
