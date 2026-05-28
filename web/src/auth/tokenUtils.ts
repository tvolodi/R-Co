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
