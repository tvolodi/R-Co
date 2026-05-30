import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { usersApi, rolesApi, groupsApi } from '@/api/identity'
import { queryKeys } from '@/api/queryKeys'

export type AdminUserFilters = {
  search: string
  status: 'ALL' | 'ACTIVE' | 'INACTIVE'
  page: number
  page_size: number
}

export function useAdminUsers(filters: AdminUserFilters) {
  return useQuery({
    queryKey: queryKeys.admin.users(filters),
    queryFn: () =>
      usersApi.list({
        search: filters.search || undefined,
        status: filters.status === 'ALL' ? undefined : filters.status,
        page: filters.page,
        page_size: filters.page_size,
      }),
  })
}

export function useAdminUser(userId: string) {
  return useQuery({
    queryKey: queryKeys.admin.userDetail(userId),
    queryFn: () => usersApi.get(userId),
    enabled: userId.length > 0,
  })
}

export function useAdminRoles() {
  return useQuery({
    queryKey: queryKeys.admin.roles(),
    queryFn: () => rolesApi.list(),
  })
}

export function useAdminGroups() {
  return useQuery({
    queryKey: queryKeys.admin.groups(),
    queryFn: () => groupsApi.list(),
  })
}

export function useCreateAdminUser() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: usersApi.create,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.admin.users() })
    },
  })
}

export function useUpdateAdminUser(userId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (body: Parameters<typeof usersApi.update>[1]) => usersApi.update(userId, body),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.admin.userDetail(userId) })
      queryClient.invalidateQueries({ queryKey: queryKeys.admin.users() })
    },
  })
}

export function useDeactivateAdminUser(userId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: () => usersApi.update(userId, { status: 'INACTIVE', is_active: false }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.admin.userDetail(userId) })
      queryClient.invalidateQueries({ queryKey: queryKeys.admin.users() })
    },
  })
}
