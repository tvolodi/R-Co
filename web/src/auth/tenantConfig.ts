/** Tenant OIDC configuration — fetched from backend by hostname, cached in memory */

const DEFAULT_AUTHORITY = (import.meta.env.VITE_OIDC_AUTHORITY as string) ?? 'http://localhost:8081/realms/bpm-default'
const DEFAULT_CLIENT_ID = (import.meta.env.VITE_OIDC_CLIENT_ID as string) ?? 'bpm-platform-api'

export interface TenantConfig {
  oidc_authority: string
  client_id: string
}

let _cachedConfig: TenantConfig | null = null

export async function fetchTenantConfig(hostname: string): Promise<TenantConfig> {
  if (_cachedConfig) return _cachedConfig
  try {
    const res = await fetch(`/api/tenant-config?host=${encodeURIComponent(hostname)}`)
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const data = await res.json() as TenantConfig
    _cachedConfig = data
    return data
  } catch {
    const fallback = { oidc_authority: DEFAULT_AUTHORITY, client_id: DEFAULT_CLIENT_ID }
    _cachedConfig = fallback
    return fallback
  }
}

export function getCachedTenantConfig(): TenantConfig {
  return _cachedConfig ?? { oidc_authority: DEFAULT_AUTHORITY, client_id: DEFAULT_CLIENT_ID }
}
