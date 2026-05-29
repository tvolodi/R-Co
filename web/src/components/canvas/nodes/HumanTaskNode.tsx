import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function HumanTaskNode({ data, selected }: NodeProps<Node<CanvasNodeData>>) {
  return (
    <div
      className="human-task-node"
      style={{
        width: 180,
        minHeight: 72,
        borderRadius: 8,
        border: '1.5px solid var(--color-brand-500, #339af0)',
        background: 'var(--color-neutral-0, #fff)',
        padding: '8px 12px',
        display: 'flex',
        flexDirection: 'column',
        gap: 2,
        position: 'relative',
        boxShadow: selected ? '0 0 0 3px rgba(34,139,230,0.2)' : undefined,
        cursor: 'pointer',
      }}
    >
      {data.validationError && (
        <div
          style={{
            position: 'absolute',
            top: -6,
            right: -6,
            width: 16,
            height: 16,
            borderRadius: '50%',
            background: 'var(--color-error, #fa5252)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 10,
            color: '#fff',
            fontWeight: 'bold',
          }}
          title={data.validationError}
        >
          !
        </div>
      )}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        {/* User icon */}
        <svg width="18" height="18" viewBox="0 0 24 24" fill="var(--color-brand-500, #339af0)">
          <circle cx="12" cy="8" r="4" />
          <path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" />
        </svg>
        <span
          style={{
            fontWeight: 600,
            fontSize: 'var(--text-sm, 0.875rem)',
            color: 'var(--text-primary, #212529)',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
            maxWidth: 130,
          }}
        >
          {data.name || 'Human Task'}
        </span>
      </div>
      <span
        style={{
          fontSize: 'var(--text-xs, 0.75rem)',
          color: 'var(--text-secondary, #6c757d)',
          marginLeft: 24,
        }}
      >
        Human Task
      </span>

      <Handle type="target" position={Position.Top} />
      <Handle type="source" position={Position.Bottom} />
    </div>
  )
}
