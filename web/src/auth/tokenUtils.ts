import type { JwtPayload } from '@/types/api'

export function decodeTokenPayload(token: string): JwtPayload | null {
  try {
    const parts = token.split('.')
    if (parts.length !== 3) return null
    const payload = parts[1]
    // Pad to multiple of 4 for atob
    const padded = payload + '='.repeat((4 - (payload.length % 4)) % 4)
    const decoded = atob(padded)
    return JSON.parse(decoded) as JwtPayload
  } catch {
    return null
  }
}

export function resolveDisplayName(payload: JwtPayload): string {
  return payload.display_name ?? payload.name ?? payload.preferred_username ?? payload.sub ?? 'Unknown User'
}

/**
 * Extract the tenant slug from the JWT payload.
 * Priority: payload.tenant_id claim → realm segment from payload.iss.
 * Returns null if neither is available.
 */
export function resolveTenantSlug(payload: JwtPayload): string | null {
  if (payload.tenant_id) return payload.tenant_id
  if (payload.iss) {
    try {
      const url = new URL(payload.iss)
      const parts = url.pathname.split('/')
      const realmsIdx = parts.indexOf('realms')
      if (realmsIdx !== -1 && parts[realmsIdx + 1]) {
        const realm = parts[realmsIdx + 1]
        return realm.startsWith('bpm-') ? realm.slice(4) : realm
      }
    } catch {
      return null
    }
  }
  return null
}
