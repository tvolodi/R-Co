import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function SubProcessNode({ data, selected }: NodeProps<Node<CanvasNodeData>>) {
  const subDefName = (data.attributes?.sub_definition_name as string) ?? ''

  return (
    <div
      className="sub-process-node"
      style={{
        width: 200,
        minHeight: 80,
        borderRadius: 8,
        border: '2px dashed var(--color-brand-400, #4dabf7)',
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
        {/* Stacked-layers icon */}
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="var(--color-brand-400, #4dabf7)" strokeWidth="2">
          <polygon points="12,2 22,7 12,12 2,7 12,2" />
          <polyline points="2,17 12,22 22,17" />
          <polyline points="2,12 12,17 22,12" />
        </svg>
        <span
          style={{
            fontWeight: 600,
            fontSize: 'var(--text-sm, 0.875rem)',
            color: 'var(--text-primary, #212529)',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
            maxWidth: 145,
          }}
        >
          {data.name || 'Sub-process'}
        </span>
      </div>
      <span
        style={{
          fontSize: 'var(--text-xs, 0.75rem)',
          color: 'var(--text-secondary, #6c757d)',
          marginLeft: 24,
        }}
      >
        {subDefName ? `Sub-process: ${subDefName}` : 'Sub-process'}
      </span>

      <Handle type="target" position={Position.Top} />
      <Handle type="source" position={Position.Bottom} />
    </div>
  )
}
