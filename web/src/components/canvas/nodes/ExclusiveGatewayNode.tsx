import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function ExclusiveGatewayNode({ selected }: NodeProps<Node<CanvasNodeData>>) {
  return (
    <div
      className="exclusive-gateway-node"
      style={{
        width: 56,
        height: 80,
        display: 'flex',
        flexDirection: 'column',
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
          border: '2px solid var(--color-warning-dark, #e67700)',
          background: 'var(--color-neutral-0, #fff)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          boxShadow: selected ? '0 0 0 3px rgba(34,139,230,0.2)' : undefined,
          flexShrink: 0,
        }}
      >
        {/* X mark */}
        <span
          style={{
            transform: 'rotate(-45deg)',
            fontWeight: 'bold',
            color: 'var(--color-warning-dark, #e67700)',
            fontSize: 18,
            lineHeight: 1,
          }}
        >
          ✕
        </span>
      </div>

      {/* Label text for identification */}
      <span
        style={{
          fontSize: 'var(--text-xs, 0.65rem)',
          color: 'var(--color-warning-dark, #e67700)',
          marginTop: 2,
          textAlign: 'center',
          lineHeight: 1.1,
          fontWeight: 500,
        }}
      >
        GATEWAY
      </span>

      <Handle type="target" position={Position.Top} />
      <Handle type="source" position={Position.Bottom} />
      <Handle type="source" position={Position.Left} id="left" />
      <Handle type="source" position={Position.Right} id="right" />
    </div>
  )
}
