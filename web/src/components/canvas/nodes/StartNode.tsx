import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function StartNode({ selected }: NodeProps<Node<CanvasNodeData>>) {
  return (
    <div
      className="start-node"
      style={{
        width: 48,
        height: 48,
        borderRadius: '50%',
        border: `2px solid var(--color-brand-600, #228be6)`,
        background: 'var(--color-neutral-0, #fff)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        boxShadow: selected ? '0 0 0 3px rgba(34,139,230,0.2)' : undefined,
        cursor: 'default',
      }}
    >
      {/* Play/triangle icon */}
      <svg width="20" height="20" viewBox="0 0 24 24" fill="var(--color-brand-600, #228be6)">
        <polygon points="8,5 19,12 8,19" />
      </svg>
      <Handle type="source" position={Position.Bottom} />
    </div>
  )
}
