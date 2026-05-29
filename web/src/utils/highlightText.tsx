import type { ReactNode } from 'react'

/**
 * Wraps matching substrings of `query` in `<mark>` tags with yellow background.
 * Case-insensitive matching. Returns a ReactNode array with plain text and <mark> elements.
 */
export function highlightText(text: string, query: string): ReactNode {
  if (!query.trim()) return text

  const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const regex = new RegExp(`(${escaped})`, 'gi')
  const parts = text.split(regex)

  if (parts.length === 1) return text

  return parts.map((part, i) =>
    regex.test(part)
      ? <mark key={i} style={{ background: '#fef08a', borderRadius: 2, padding: '0 1px' }}>{part}</mark>
      : part,
  )
}
