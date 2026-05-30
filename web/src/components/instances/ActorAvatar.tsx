interface ActorAvatarProps {
  displayName: string | null | undefined
  size?: number
}

const AVATAR_PALETTE = [
  '#2563eb',
  '#0d9488',
  '#7c3aed',
  '#ea580c',
  '#0891b2',
  '#16a34a',
  '#9333ea',
  '#0284c7',
  '#c2410c',
  '#4f46e5',
]

function hashText(value: string): number {
  let hash = 0
  for (let i = 0; i < value.length; i += 1) {
    hash = (hash << 5) - hash + value.charCodeAt(i)
    hash |= 0
  }
  return Math.abs(hash)
}

function buildInitials(displayName: string): string {
  const parts = displayName
    .trim()
    .split(/\s+/)
    .filter(Boolean)

  if (parts.length === 0) return 'SY'
  if (parts.length === 1) return parts[0].slice(0, 1).toUpperCase()

  const first = parts[0].slice(0, 1).toUpperCase()
  const last = parts[parts.length - 1].slice(0, 1).toUpperCase()
  return `${first}${last}`
}

export function ActorAvatar({ displayName, size = 36 }: ActorAvatarProps) {
  const normalized = (displayName ?? '').trim()
  const isSystem = normalized.length === 0
  const paletteIndex = isSystem ? 0 : hashText(normalized) % AVATAR_PALETTE.length
  const backgroundColor = isSystem ? '#64748b' : AVATAR_PALETTE[paletteIndex]
  const initials = isSystem ? 'SY' : buildInitials(normalized)

  return (
    <div
      aria-label={isSystem ? 'System actor' : `Actor ${normalized}`}
      title={isSystem ? 'system' : normalized}
      style={{
        width: `${size}px`,
        height: `${size}px`,
        borderRadius: '9999px',
        background: backgroundColor,
        color: '#ffffff',
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontWeight: 700,
        fontSize: `${Math.round(size * 0.4)}px`,
        lineHeight: 1,
        userSelect: 'none',
      }}
    >
      {initials}
    </div>
  )
}
