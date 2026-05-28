/** OIDC Manager — singleton UserManager for authorization code flow via oidc-client-ts */

import { UserManager, WebStorageStateStore, InMemoryWebStorage } from 'oidc-client-ts'
import type { UserManagerSettings } from 'oidc-client-ts'
import { fetchTenantConfig } from './tenantConfig'

const _defaultSettings: UserManagerSettings = {
  authority: (import.meta.env.VITE_OIDC_AUTHORITY as string) ?? 'http://localhost:8081/realms/bpm-default',
  client_id: (import.meta.env.VITE_OIDC_CLIENT_ID as string) ?? 'bpm-platform-api',
  redirect_uri: window.location.origin + '/auth/callback',
  response_type: 'code',
  scope: 'openid profile',
  userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
  automaticSilentRenew: false,
}

/** Backward-compat sync export using default (env-var) config. */
export const oidcManager = new UserManager(_defaultSettings)

/** Lazy-resolved manager using dynamic tenant config from /api/tenant-config. */
let _resolvedManager: UserManager | null = null

export async function getOidcManager(): Promise<UserManager> {
  if (_resolvedManager) return _resolvedManager
  const config = await fetchTenantConfig(window.location.hostname)
  const settings: UserManagerSettings = {
    authority: config.oidc_authority,
    client_id: config.client_id,
    redirect_uri: window.location.origin + '/auth/callback',
    response_type: 'code',
    scope: 'openid profile',
    userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
    automaticSilentRenew: false,
  }
  _resolvedManager = new UserManager(settings)
  return _resolvedManager
}

/** Start the automatic silent renew loop. Call once after a successful OIDC login. */
export function startOidcSilentRenew(): void {
  oidcManager.startSilentRenew()
}
