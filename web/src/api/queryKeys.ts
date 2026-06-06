import type { DefinitionStatus, InstanceStatus, TaskStatus } from '@/types/api'

type InstanceListFilters = {
  status?: InstanceStatus[]
  definition_id?: string
  cursor?: string
  page_size?: number
}

type DefinitionListFilters = {
  status?: DefinitionStatus
  name?: string
  cursor?: string
  page_size?: number
}

type TaskListFilters = {
  status?: TaskStatus
  instance_id?: string
  assignee_ref?: string
  cursor?: string
  page_size?: number
}

type AdminAuditFilters = {
  actor?: string
  resource_type?: string
  from?: string
  to?: string
  cursor?: string
  page_size?: number
}

type EventFilters = {
  event_type?: string
  from?: string
  to?: string
}

function sortStatuses(statuses?: InstanceStatus[]): InstanceStatus[] | undefined {
  if (!statuses || statuses.length === 0) return undefined
  return [...statuses].sort()
}

export const queryKeys = {
  instances: {
    all: ['instances'] as const,
    list: (filters: InstanceListFilters) => [
      ...queryKeys.instances.all,
      'list',
      {
        ...filters,
        status: sortStatuses(filters.status),
      },
    ] as const,
    detail: (id: string) => [...queryKeys.instances.all, 'detail', id] as const,
    events: (id: string, filters?: EventFilters) =>
      [...queryKeys.instances.all, 'events', id, filters ?? {}] as const,
    timeline: (id: string, cursor: string | null, pageSize: number) =>
      [...queryKeys.instances.all, 'timeline', id, cursor, pageSize] as const,
  },

  definitions: {
    all: ['definitions'] as const,
    list: (filters: DefinitionListFilters) => [...queryKeys.definitions.all, 'list', filters] as const,
    detail: (id: string) => [...queryKeys.definitions.all, 'detail', id] as const,
    active: (name: string) => [...queryKeys.definitions.all, 'active', name] as const,
    versions: (name: string) => [...queryKeys.definitions.all, 'versions', name] as const,
    search: (query: string, limit?: number, offset?: number) =>
      [...queryKeys.definitions.all, 'search', query, limit, offset] as const,
  },

  tasks: {
    all: ['tasks'] as const,
    list: (filters: TaskListFilters) => [...queryKeys.tasks.all, 'list', filters] as const,
    detail: (id: string) => [...queryKeys.tasks.all, 'detail', id] as const,
    inbox: () => [...queryKeys.tasks.all, 'inbox'] as const,
  },

  admin: {
    all: ['admin'] as const,
    audit: (filters?: AdminAuditFilters) => [...queryKeys.admin.all, 'audit', filters ?? {}] as const,
    groups: () => [...queryKeys.admin.all, 'groups'] as const,
    groupMembers: (groupId: string) => [...queryKeys.admin.all, 'group-members', groupId] as const,
    health: () => [...queryKeys.admin.all, 'health'] as const,
    metrics: () => [...queryKeys.admin.all, 'metrics'] as const,
    tokens: () => [...queryKeys.admin.all, 'tokens'] as const,
    users: (filters?: { search?: string; status?: string; page?: number; page_size?: number }) =>
      [...queryKeys.admin.all, 'users', filters ?? {}] as const,
    userDetail: (id: string) => [...queryKeys.admin.all, 'user', id] as const,
    roles: () => [...queryKeys.admin.all, 'roles'] as const,
    tenants: (filters?: { search?: string; limit?: number; offset?: number }) =>
      [...queryKeys.admin.all, 'tenants', filters ?? {}] as const,
    tenantDetail: (slug: string) => [...queryKeys.admin.all, 'tenant', slug] as const,
  },

  dlq: {
    all: ['dlq'] as const,
    list: (filters?: { search?: string; status?: string; source_type?: string; cursor?: string; page_size?: number }) =>
      [...queryKeys.dlq.all, 'list', filters ?? {}] as const,
    detail: (id: string) => [...queryKeys.dlq.all, 'detail', id] as const,
  },

  webhooks: {
    all: ['webhooks'] as const,
    list: () => [...queryKeys.webhooks.all, 'list'] as const,
    detail: (id: string) => [...queryKeys.webhooks.all, 'detail', id] as const,
    deliveries: (id: string, limit = 20) => [...queryKeys.webhooks.all, 'deliveries', id, limit] as const,
  },

  onboarding: {
    all: ['onboarding'] as const,
    status: (id: string) => ['onboarding', 'status', id] as const,
    hostname: (h: string) => ['onboarding', 'hostname', h] as const,
  },
}
