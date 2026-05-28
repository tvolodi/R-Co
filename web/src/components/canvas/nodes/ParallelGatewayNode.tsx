import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function ParallelGatewayNode({ selected }: NodeProps<Node<CanvasNodeData>>) {
  return (
    <div
      className="parallel-gateway-node"
      style={{
        width: 56,
        height: 56,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        position: 'relative',
        cursor: 'pointer',
      }}
    >
      {/* Diamond shape via rotated square */}
      <div
        style={{
          width: 40,
          height: 40,
          transform: 'rotate(45deg)',
          border: '2px solid var(--color-success-dark, #2f9e44)',
          background: 'var(--color-neutral-0, #fff)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          boxShadow: selected ? '0 0 0 3px rgba(34,139,230,0.2)' : undefined,
        }}
      >
        {/* Plus sign */}
        <span
          style={{
            transform: 'rotate(-45deg)',
            fontWeight: 'bold',
            color: 'var(--color-success-dark, #2f9e44)',
            fontSize: 20,
            lineHeight: 1,
          }}
        >
          +
        </span>
      </div>

      <Handle type="target" position={Position.Top} />
      <Handle type="source" position={Position.Bottom} id="bottom" />
      <Handle type="source" position={Position.Left} id="left" />
      <Handle type="source" position={Position.Right} id="right" />
    </div>
  )
}
