import { useCallback, type DragEvent } from 'react'
import type { NodeType } from '@/types/api'

interface PaletteItem {
  type: NodeType
  label: string
  category: string
}

const PALETTE_ITEMS: PaletteItem[] = [
  { type: 'START', label: 'Start', category: 'Events' },
  { type: 'END', label: 'End', category: 'Events' },
  { type: 'HUMAN_TASK', label: 'Human Task', category: 'Tasks' },
  { type: 'SERVICE_TASK', label: 'Service Task', category: 'Tasks' },
  { type: 'EXCLUSIVE_GATEWAY', label: 'Exclusive Gateway', category: 'Gateways' },
  { type: 'PARALLEL_GATEWAY', label: 'Parallel Gateway', category: 'Gateways' },
  { type: 'TIMER', label: 'Timer', category: 'Events' },
  { type: 'SUB_PROCESS', label: 'Sub-process', category: 'Tasks' },
]

const CATEGORIES = ['Events', 'Tasks', 'Gateways'] as const

interface NodePaletteProps {
  isReadOnly: boolean
}

export default function NodePalette({ isReadOnly }: NodePaletteProps) {
  const onDragStart = useCallback(
    (e: DragEvent<HTMLDivElement>, nodeType: NodeType) => {
      if (isReadOnly) return
      e.dataTransfer.setData('application/bpm-node-type', nodeType)
      e.dataTransfer.effectAllowed = 'copy'
    },
    [isReadOnly],
  )

  if (isReadOnly) return null

  return (
    <div
      className="node-palette"
      style={{
        width: 200,
        minWidth: 200,
        background: 'var(--surface-card, #fff)',
        borderRight: '1px solid var(--border-default, #e9ecef)',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        height: '100%',
      }}
    >
      <div
        style={{
          padding: '12px 16px',
          borderBottom: '1px solid var(--border-default, #e9ecef)',
          fontSize: 'var(--text-sm, 0.875rem)',
          fontWeight: 600,
          color: 'var(--text-primary, #212529)',
        }}
      >
        Node Palette
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '8px 0' }}>
        {CATEGORIES.map((category) => {
          const items = PALETTE_ITEMS.filter((i) => i.category === category)
          if (items.length === 0) return null
          return (
            <div key={category}>
              <div
                style={{
                  padding: '4px 16px',
                  fontSize: 'var(--text-xs, 0.75rem)',
                  fontWeight: 500,
                  color: 'var(--text-secondary, #6c757d)',
                  textTransform: 'uppercase',
                  letterSpacing: '0.5px',
                }}
              >
                {category}
              </div>
              {items.map((item) => (
                <div
                  key={item.type}
                  draggable={!isReadOnly}
                  onDragStart={(e) => onDragStart(e, item.type)}
                  style={{
                    padding: '8px 16px',
                    cursor: isReadOnly ? 'default' : 'grab',
                    fontSize: 'var(--text-sm, 0.875rem)',
                    color: 'var(--text-primary, #212529)',
                    display: 'flex',
                    alignItems: 'center',
                    gap: 8,
                    userSelect: 'none',
                    transition: 'background 0.1s',
                  }}
                  onMouseEnter={(e) => {
                    if (!isReadOnly) e.currentTarget.style.background = 'var(--color-neutral-100, #f1f3f5)'
                  }}
                  onMouseLeave={(e) => {
                    e.currentTarget.style.background = 'transparent'
                  }}
                >
                  <NodeTypeIcon type={item.type} />
                  <span>{item.label}</span>
                </div>
              ))}
            </div>
          )
        })}
      </div>
    </div>
  )
}

/** Small inline icon for palette items */
function NodeTypeIcon({ type }: { type: NodeType }) {
  const iconProps = { width: 16, height: 16 }

  switch (type) {
    case 'START':
      return (
        <svg {...iconProps} viewBox="0 0 24 24" fill="var(--color-brand-600, #228be6)">
          <polygon points="8,5 19,12 8,19" />
        </svg>
      )
    case 'END':
      return (
        <svg {...iconProps} viewBox="0 0 24 24" fill="var(--color-error-dark, #c92a2a)">
          <rect x="6" y="6" width="12" height="12" rx="1" />
        </svg>
      )
    case 'HUMAN_TASK':
      return (
        <svg {...iconProps} viewBox="0 0 24 24" fill="var(--color-brand-500, #339af0)">
          <circle cx="12" cy="8" r="4" />
          <path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" />
        </svg>
      )
    case 'SERVICE_TASK':
      return (
        <svg {...iconProps} viewBox="0 0 24 24" fill="none" stroke="var(--color-info, #4c6ef5)" strokeWidth="2">
          <circle cx="12" cy="12" r="3" />
          <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
        </svg>
      )
    case 'EXCLUSIVE_GATEWAY':
      return (
        <span style={{ color: 'var(--color-warning-dark, #e67700)', fontWeight: 'bold', fontSize: 14 }}>✕</span>
      )
    case 'PARALLEL_GATEWAY':
      return (
        <span style={{ color: 'var(--color-success-dark, #2f9e44)', fontWeight: 'bold', fontSize: 16 }}>+</span>
      )
    case 'TIMER':
      return (
        <svg {...iconProps} viewBox="0 0 24 24" fill="none" stroke="var(--color-warning, #fcc419)" strokeWidth="2">
          <circle cx="12" cy="12" r="10" />
          <polyline points="12,6 12,12 16,14" />
        </svg>
      )
    case 'SUB_PROCESS':
      return (
        <svg {...iconProps} viewBox="0 0 24 24" fill="none" stroke="var(--color-brand-400, #4dabf7)" strokeWidth="2">
          <polygon points="12,2 22,7 12,12 2,7 12,2" />
          <polyline points="2,17 12,22 22,17" />
          <polyline points="2,12 12,17 22,12" />
        </svg>
      )
    default:
      return null
  }
}
