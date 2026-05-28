/** OIDC Manager — singleton UserManager for authorization code flow via oidc-client-ts */

import { UserManager, WebStorageStateStore, InMemoryWebStorage } from 'oidc-client-ts'

const settings = {
  authority: (import.meta.env.VITE_OIDC_AUTHORITY as string) ?? 'http://localhost:8081/realms/bpm-default',
  client_id: (import.meta.env.VITE_OIDC_CLIENT_ID as string) ?? 'bpm-platform-api',
  redirect_uri: window.location.origin + '/auth/callback',
  response_type: 'code',
  scope: 'openid profile',
  userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
  automaticSilentRenew: false,
}

export const oidcManager = new UserManager(settings)

/** Start the automatic silent renew loop. Call once after a successful OIDC login. */
export function startOidcSilentRenew(): void {
  oidcManager.startSilentRenew()
}
