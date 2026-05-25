/** TanStack Query hooks for process instances */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { instancesApi } from '@/api/instances'
import type { InstanceStatus, StartInstanceRequest } from '@/types/api'

export const instanceKeys = {
  all: ['instances'] as const,
  list: (filters: object) => [...instanceKeys.all, 'list', filters] as const,
  detail: (id: string) => [...instanceKeys.all, 'detail', id] as const,
  events: (id: string) => [...instanceKeys.all, 'events', id] as const,
  timeline: (id: string, cursor: string | null, pageSize: number) =>
    [...instanceKeys.all, 'timeline', id, cursor, pageSize] as const,
}

export function useInstances(params?: { status?: InstanceStatus; definition_id?: string }) {
  return useQuery({
    queryKey: instanceKeys.list(params ?? {}),
    queryFn: () => instancesApi.list(params),
  })
}

export function useInstance(id: string) {
  return useQuery({
    queryKey: instanceKeys.detail(id),
    queryFn: () => instancesApi.get(id),
    enabled: !!id,
  })
}

export function useInstanceEvents(id: string) {
  return useQuery({
    queryKey: instanceKeys.events(id),
    queryFn: () => instancesApi.events(id),
    enabled: !!id,
  })
}

export function useInstanceTimeline(
  id: string,
  params?: { cursor?: string; page_size?: number },
  enabled = true,
) {
  const cursor = params?.cursor ?? null
  const pageSize = params?.page_size ?? 50

  return useQuery({
    queryKey: instanceKeys.timeline(id, cursor, pageSize),
    queryFn: () => instancesApi.timeline(id, params),
    enabled: !!id && enabled,
  })
}

export function useStartInstance() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: StartInstanceRequest) => instancesApi.start(body),
    onSuccess: () => qc.invalidateQueries({ queryKey: instanceKeys.list({}) }),
  })
}

export function useCancelInstance() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, reason }: { id: string; reason?: string }) =>
      instancesApi.cancel(id, reason),
    onMutate: async ({ id }) => {
      await qc.cancelQueries({ queryKey: instanceKeys.detail(id) })
      const previous = qc.getQueryData(instanceKeys.detail(id))
      qc.setQueryData(instanceKeys.detail(id), (old: unknown) =>
        old ? { ...(old as object), status: 'CANCELLED' } : old,
      )
      return { previous }
    },
    onError: (_err, { id }, ctx) => {
      qc.setQueryData(instanceKeys.detail(id), ctx?.previous)
    },
    onSettled: (_data, _err, { id }) => {
      qc.invalidateQueries({ queryKey: instanceKeys.detail(id) })
      qc.invalidateQueries({ queryKey: instanceKeys.list({}) })
    },
  })
}
