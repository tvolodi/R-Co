import { client } from './client'
import type { HealthStatus } from '@/types/api'

export const healthApi = {
  get: () => client.get<HealthStatus>('/api/v1/health'),
}
