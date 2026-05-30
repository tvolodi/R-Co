import { client } from './client'
import type {
  User,
  Group,
  Role,
  RolePermission,
  ApiToken,
  PagedResponse,
} from '@/types/api'

// ── Users ──────────────────────────────────────────────────────────────────────

export const usersApi = {
  list: (params?: { page?: number; page_size?: number; search?: string }) =>
    client.get<PagedResponse<User>>('/api/v1/admin/users', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<User>(`/api/v1/admin/users/${id}`),

  create: (body: { username: string; email: string; display_name: string; password: string; role_ids?: string[] }) =>
    client.post<User>('/api/v1/admin/users', body),

  update: (id: string, body: Partial<{ display_name: string; is_active: boolean; role_ids: string[] }>) =>
    client.patch<User>(`/api/v1/admin/users/${id}`, body),

  resetPassword: (id: string, newPassword: string) =>
    client.post<void>(`/api/v1/admin/users/${id}/reset-password`, { password: newPassword }),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/admin/users/${id}`),
}

// ── Groups ─────────────────────────────────────────────────────────────────────

export const groupsApi = {
  list: () =>
    client.get<PagedResponse<Group>>('/api/v1/admin/groups'),

  get: (id: string) =>
    client.get<Group>(`/api/v1/admin/groups/${id}`),

  create: (body: { name: string; display_name: string; description?: string }) =>
    client.post<Group>('/api/v1/admin/groups', body),

  update: (id: string, body: Partial<{ display_name: string; description: string }>) =>
    client.patch<Group>(`/api/v1/admin/groups/${id}`, body),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/admin/groups/${id}`),

  addMembers: (id: string, userIds: string[]) =>
    client.post<void>(`/api/v1/admin/groups/${id}/members`, { user_ids: userIds }),

  removeMembers: (id: string, userIds: string[]) => {
    void userIds
    return client.delete<void>(`/api/v1/admin/groups/${id}/members`)
  },

  members: (id: string) =>
    client.get<User[]>(`/api/v1/admin/groups/${id}/members`),
}

// ── Roles ──────────────────────────────────────────────────────────────────────

export const rolesApi = {
  list: () =>
    client.get<PagedResponse<Role>>('/api/v1/admin/roles'),

  get: (id: string) =>
    client.get<Role>(`/api/v1/admin/roles/${id}`),

  create: (body: { name: string; description?: string }) =>
    client.post<Role>('/api/v1/admin/roles', body),

  update: (id: string, body: Partial<{ description: string }>) =>
    client.patch<Role>(`/api/v1/admin/roles/${id}`, body),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/admin/roles/${id}`),

  grantPermission: (id: string, perm: Omit<RolePermission, 'id'>) =>
    client.post<RolePermission>(`/api/v1/admin/roles/${id}/permissions`, perm),

  revokePermission: (id: string, permId: string) =>
    client.delete<void>(`/api/v1/admin/roles/${id}/permissions/${permId}`),
}

// ── API Tokens ─────────────────────────────────────────────────────────────────

export const tokensApi = {
  list: () =>
    client.get<ApiToken[]>('/api/v1/auth/tokens'),

  /** Returns the raw token value once — store it immediately */
  create: (name: string, expiresAt?: string) =>
    client.post<{ token: string; meta: ApiToken }>('/api/v1/auth/tokens', { name, expires_at: expiresAt }),

  revoke: (id: string) =>
    client.delete<void>(`/api/v1/auth/tokens/${id}`),
}
