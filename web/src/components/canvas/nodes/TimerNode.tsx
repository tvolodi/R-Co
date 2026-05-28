import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function TimerNode({ selected }: NodeProps<Node<CanvasNodeData>>) {
  return (
    <div
      className="timer-node"
      style={{
        width: 56,
        height: 56,
        borderRadius: '50%',
        border: '2px solid var(--color-warning, #fcc419)',
        background: 'var(--color-neutral-0, #fff)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        position: 'relative',
        boxShadow: selected ? '0 0 0 3px rgba(34,139,230,0.2)' : undefined,
        cursor: 'pointer',
      }}
    >
      {/* Clock icon */}
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="var(--color-warning, #fcc419)" strokeWidth="2">
        <circle cx="12" cy="12" r="10" />
        <polyline points="12,6 12,12 16,14" />
      </svg>

      <Handle type="target" position={Position.Top} />
      <Handle type="source" position={Position.Bottom} />
    </div>
  )
}
