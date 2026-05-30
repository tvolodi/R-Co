/** ProcessGraphWithTokens — Display process graph with token position overlays */
import { useState } from 'react'
import { ReactFlow, Background, Controls, MiniMap, type Node, type Edge } from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import { useInstance } from '@/hooks/useInstances'
import { useDefinition } from '@/hooks/useDefinitions'
import { useProcessGraphWithTokens, type TokenMarker } from '@/hooks/useProcessGraphWithTokens'
import { graphToFlow, type CanvasNodeData, type CanvasEdgeData } from '@/utils/canvas/graphToFlow'
import { getTokenMarkerColour } from '@/utils/tokenVisualisation'
import type { DefinitionGraph } from '@/types/api'

export interface ProcessGraphWithTokensProps {
  instanceId: string
  definitionId?: string
  tokens?: TokenMarker[]
  isLoading?: boolean
  onNodeClick?: (nodeId: string) => void
}

export function ProcessGraphWithTokens(props: ProcessGraphWithTokensProps): JSX.Element {
  const { instanceId, definitionId } = props
  const [hoveredTokenNode, setHoveredTokenNode] = useState<string | null>(null)

  const { data: instance } = useInstance(instanceId)
  const { data: definition } = useDefinition(definitionId || instance?.definition_id || '')
  const { tokens: derivedTokens, isLoading: isTokenLoading } = useProcessGraphWithTokens(instanceId)

  const isLoading = props.isLoading ?? isTokenLoading
  const tokens = props.tokens ?? derivedTokens
  const instanceGraph = instance?.definition_snapshot ?? definition?.graph
  const activeNodeIds = instance?.current_nodes ?? []

  // Build React Flow graph
  const { nodes: baseNodes, edges } = buildGraphFromDefinition(instanceGraph, activeNodeIds)

  // Add token overlays to nodes
  const nodesWithTokens = baseNodes.map((node) => ({
    ...node,
    data: {
      ...(node.data || {}),
      tokens: tokens.filter((t) => t.node_id === node.id),
    },
  }))

  return (
    <div style={{ position: 'relative', width: '100%', height: '320px' }}>
      {isLoading && (
        <div
          style={{
            position: 'absolute',
            top: '50%',
            left: '50%',
            transform: 'translate(-50%, -50%)',
            zIndex: 10,
          }}
        >
          <p style={{ color: '#64748b' }}>Loading tokens…</p>
        </div>
      )}

      {!instanceGraph || typeof instanceGraph !== 'object' ? (
        <div style={{ padding: '1rem', color: '#64748b', fontSize: '.85rem' }}>
          No graph snapshot is available for this instance.
        </div>
      ) : (
        <>
          <ReactFlow
            nodes={nodesWithTokens}
            edges={edges}
            nodesDraggable={false}
            nodesConnectable={false}
            elementsSelectable={false}
            fitView
            proOptions={{ hideAttribution: true }}
          >
            <Background color="#e2e8f0" gap={20} />
            <MiniMap />
            <Controls />
          </ReactFlow>

          {/* Render token markers as overlays */}
          <div style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%', pointerEvents: 'none' }}>
            {tokens.map((token) => (
              <TokenMarkerOverlay
                key={`${token.node_id}-${token.status}`}
                token={token}
                onHover={() => setHoveredTokenNode(token.node_id)}
                onHoverEnd={() => setHoveredTokenNode(null)}
                isHovered={hoveredTokenNode === token.node_id}
              />
            ))}
          </div>

          {/* Tooltip */}
          {hoveredTokenNode && (
            <div
              style={{
                position: 'absolute',
                background: '#1f2937',
                color: '#f3f4f6',
                padding: '.5rem .75rem',
                borderRadius: '4px',
                fontSize: '.75rem',
                zIndex: 20,
                pointerEvents: 'none',
                maxWidth: '200px',
              }}
            >
              <div style={{ fontWeight: 600 }}>{hoveredTokenNode}</div>
              <div style={{ marginTop: '.25rem', color: '#d1d5db' }}>{tokens.find((t) => t.node_id === hoveredTokenNode)?.count ?? 0} token(s)</div>
            </div>
          )}
        </>
      )}
    </div>
  )
}

/**
 * Individual token marker overlay
 */
interface TokenMarkerOverlayProps {
  token: TokenMarker
  onHover: () => void
  onHoverEnd: () => void
  isHovered: boolean
}

function TokenMarkerOverlay(props: TokenMarkerOverlayProps): JSX.Element {
  const { token, onHover, onHoverEnd, isHovered } = props
  const colour = getTokenMarkerColour(token.status)
  const size = 24

  return (
    <svg
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      style={{
        position: 'absolute',
        left: `calc(50% + ${token.node_id === 'start' ? 0 : 50}px)`,
        top: '20px',
        opacity: isHovered ? 1 : 0.8,
        cursor: 'pointer',
        filter: isHovered ? 'drop-shadow(0 2px 8px rgba(0,0,0,0.3))' : 'none',
        transition: 'opacity 0.2s, filter 0.2s',
      }}
      onMouseEnter={onHover}
      onMouseLeave={onHoverEnd}
    >
      {/* Circle background */}
      <circle cx={size / 2} cy={size / 2} r={size / 2 - 2} fill={colour} opacity={0.2} stroke={colour} strokeWidth="2" />

      {/* Status-specific icon */}
      {token.status === 'active' && (
        <circle cx={size / 2} cy={size / 2} r={size / 2 - 6} fill={colour} />
      )}

      {token.status === 'completed' && (
        <>
          <circle cx={size / 2} cy={size / 2} r={size / 2 - 6} fill="none" stroke={colour} strokeWidth="2" />
          {/* Checkmark */}
          <path
            d={`M ${size / 2 - 4} ${size / 2} L ${size / 2 - 1} ${size / 2 + 3} L ${size / 2 + 4} ${size / 2 - 2}`}
            stroke={colour}
            strokeWidth="2"
            fill="none"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </>
      )}

      {token.status === 'pending' && (
        <>
          <circle cx={size / 2} cy={size / 2} r={size / 2 - 6} fill={colour} opacity={0.4} />
          <circle cx={size / 2} cy={size / 2} r={size / 2 - 6} fill="none" stroke={colour} strokeWidth="2" />
        </>
      )}

      {token.status === 'error' && (
        <>
          <circle cx={size / 2} cy={size / 2} r={size / 2 - 6} fill="none" stroke={colour} strokeWidth="2" />
          {/* X mark */}
          <path
            d={`M ${size / 2 - 4} ${size / 2 - 4} L ${size / 2 + 4} ${size / 2 + 4}`}
            stroke={colour}
            strokeWidth="2"
            strokeLinecap="round"
          />
          <path
            d={`M ${size / 2 + 4} ${size / 2 - 4} L ${size / 2 - 4} ${size / 2 + 4}`}
            stroke={colour}
            strokeWidth="2"
            strokeLinecap="round"
          />
        </>
      )}

      {/* Count badge */}
      {token.count > 1 && (
        <circle
          cx={size - 6}
          cy={6}
          r="5"
          fill="#1f2937"
          stroke={colour}
          strokeWidth="1"
          style={{ pointerEvents: 'none' }}
        />
      )}
      {token.count > 1 && (
        <text
          x={size - 6}
          y={size - 3}
          textAnchor="middle"
          fontSize="10"
          fill={colour}
          fontWeight="bold"
          style={{ pointerEvents: 'none' }}
        >
          {token.count}
        </text>
      )}
    </svg>
  )
}

/**
 * Build React Flow nodes and edges from DefinitionGraph
 */
function buildGraphFromDefinition(
  graph: unknown,
  activeNodeIds: string[]
): { nodes: Node<CanvasNodeData>[]; edges: Edge<CanvasEdgeData>[] } {
  if (!graph || typeof graph !== 'object') {
    return { nodes: [], edges: [] }
  }

  const g = graph as DefinitionGraph & { nodes?: unknown[]; edges?: unknown[] }
  if (!Array.isArray(g.nodes) || !Array.isArray(g.edges)) {
    return { nodes: [], edges: [] }
  }

  try {
    const { nodes, edges } = graphToFlow(graph as never)
    const highlighted = new Set(activeNodeIds)

    return {
      nodes: nodes.map((node) => {
        const isActive = highlighted.has(node.id)
        return {
          ...node,
          style: {
            ...(node.style ?? {}),
            border: isActive ? '2px solid #2563eb' : '1px solid #cbd5e1',
            boxShadow: isActive ? '0 0 0 4px rgba(37, 99, 235, 0.18)' : undefined,
          },
        }
      }),
      edges,
    }
  } catch {
    return { nodes: [], edges: [] }
  }
}
