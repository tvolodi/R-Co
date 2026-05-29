import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function EndNode({ selected }: NodeProps<Node<CanvasNodeData>>) {
  return (
    <div
      className="end-node"
      style={{
        width: 48,
        height: 48,
        borderRadius: '50%',
        border: '3px solid var(--color-neutral-500, #adb5bd)',
        background: 'var(--color-neutral-50, #f8f9fa)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        position: 'relative',
        boxShadow: selected ? '0 0 0 3px rgba(34,139,230,0.2)' : undefined,
        cursor: 'default',
      }}
    >
      {/* Inner circle for double-border effect */}
      <div
        style={{
          width: 28,
          height: 28,
          borderRadius: '50%',
          border: '2px solid var(--color-error-dark, #c92a2a)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        {/* Stop/square icon */}
        <svg width="14" height="14" viewBox="0 0 24 24" fill="var(--color-error-dark, #c92a2a)">
          <rect x="6" y="6" width="12" height="12" rx="1" />
        </svg>
      </div>
      <Handle type="target" position={Position.Top} />
    </div>
  )
}
