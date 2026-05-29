import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function ServiceTaskNode({ data, selected }: NodeProps<Node<CanvasNodeData>>) {
  const serviceType = (data.attributes?.service_type as string) ?? 'Service Task'

  return (
    <div
      className="service-task-node"
      style={{
        width: 180,
        minHeight: 72,
        borderRadius: 8,
        border: '1.5px solid var(--color-info, #4c6ef5)',
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
        {/* Gear/cog icon */}
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="var(--color-info, #4c6ef5)" strokeWidth="2">
          <circle cx="12" cy="12" r="3" />
          <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
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
          {data.name || 'Service Task'}
        </span>
      </div>
      <span
        style={{
          fontSize: 'var(--text-xs, 0.75rem)',
          color: 'var(--text-secondary, #6c757d)',
          marginLeft: 24,
        }}
      >
        {serviceType.length > 20 ? serviceType.slice(0, 20) + '…' : serviceType}
      </span>

      <Handle type="target" position={Position.Top} />
      <Handle type="source" position={Position.Bottom} />
    </div>
  )
}
