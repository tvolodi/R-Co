import { client } from '@/api/client'

/** Tenant OIDC configuration — fetched from backend by hostname, cached in memory */

const DEFAULT_AUTHORITY = (import.meta.env.VITE_OIDC_AUTHORITY as string) ?? 'http://localhost:8081/realms/bpm-default'
const DEFAULT_CLIENT_ID = (import.meta.env.VITE_OIDC_CLIENT_ID as string) ?? 'bpm-platform-api'

const REALM_STORAGE_KEY = 'bpm_realm_slug'

export interface TenantConfig {
  oidc_authority: string
  client_id: string
}

let _cachedConfig: TenantConfig | null = null

/**
 * Resolve a realm slug from URL/sessionStorage before falling back to hostname.
 *
 * Priority:
 *   1. sessionStorage key 'bpm_realm_slug' (set on a previous page load)
 *   2. URL query parameter 'realm'  (e.g. http://localhost:8080/?realm=swiftroute)
 *   3. null (caller falls back to hostname lookup)
 *
 * Side effect: if the slug is found in the URL it is written to sessionStorage
 * so that subsequent navigations within the SPA retain the correct realm.
 */
export function resolveRealmFromUrl(): string | null {
  const stored = sessionStorage.getItem(REALM_STORAGE_KEY)
  if (stored) return stored

  const urlRealm = new URLSearchParams(window.location.search).get('realm')
  if (urlRealm) {
    sessionStorage.setItem(REALM_STORAGE_KEY, urlRealm)
    return urlRealm
  }

  return null
}

export async function fetchTenantConfig(hostname: string): Promise<TenantConfig> {
  if (_cachedConfig) return _cachedConfig
  try {
    const realmSlug = resolveRealmFromUrl()
    const params = realmSlug ? { realm: realmSlug } : { host: hostname }
    const data = await client.get<TenantConfig>('/api/tenant-config', params)
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
