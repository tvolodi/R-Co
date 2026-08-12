import { client } from './client'
import type {
  ProcessDefinition,
  CreateDefinitionRequest,
  CursorPage,
  DefinitionStatus,
} from '@/types/api'

export interface PromoteResult {
  definition_id: string
  version: string
  status: string
}

export const definitionsApi = {
  list: (params?: { status?: DefinitionStatus; name?: string; cursor?: string; page_size?: number }) =>
    client.get<CursorPage<ProcessDefinition>>('/api/v1/definitions', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<ProcessDefinition>(`/api/v1/definitions/${id}`),

  getActive: (name: string) =>
    client.get<ProcessDefinition>(`/api/v1/definitions/active/${encodeURIComponent(name)}`),

  create: (body: CreateDefinitionRequest) =>
    client.post<ProcessDefinition>('/api/v1/definitions', body),

  update: (id: string, body: Partial<CreateDefinitionRequest>) =>
    client.patch<ProcessDefinition>(`/api/v1/definitions/${id}`, body),

  activate: (id: string) =>
    client.post<ProcessDefinition>(`/api/v1/definitions/${id}/activate`),

  deprecate: (id: string) =>
    client.post<ProcessDefinition>(`/api/v1/definitions/${id}/deprecate`),

  archive: (id: string) =>
    client.post<ProcessDefinition>(`/api/v1/definitions/${id}/archive`),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/definitions/${id}`),

  exportJson: (id: string) =>
    client.get<unknown>(`/api/v1/definitions/${id}/export`),

  importJson: (body: unknown) =>
    client.post<ProcessDefinition>('/api/v1/definitions/import', body),

  search: (params: { q: string; limit?: number; offset?: number }) =>
    client.get<CursorPage<ProcessDefinition>>('/api/v1/definitions/search', params as Record<string, unknown>),

  getVersions: (name: string) =>
    client.get<CursorPage<ProcessDefinition>>('/api/v1/definitions', { name } as Record<string, unknown>),

  promote: (testTenantId: string, definitionName: string) =>
    client.post<PromoteResult>(`/api/v1/tenants/${testTenantId}/promote/${encodeURIComponent(definitionName)}`, {}),
}
