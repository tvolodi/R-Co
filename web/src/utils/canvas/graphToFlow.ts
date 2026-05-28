/**
 * graphToFlow — DefinitionGraph (API) → React Flow nodes/edges
 *
 * Converts the backend DefinitionGraph shape into React Flow's Node/Edge arrays
 * for rendering on the ProcessCanvas. Handles position restoration from
 * persisted attributes and auto-generates positions for new/positionless nodes.
 */

import type { Node, Edge } from '@xyflow/react'
import type { DefinitionGraph, NodeType } from '@/types/api'

// ── Canvas-specific data types ────────────────────────────────────────────────

export interface CanvasNodeData {
  nodeType: NodeType
  name: string
  attributes: Record<string, unknown>
  validationError?: string
  [key: string]: unknown
}

export interface CanvasEdgeData {
  condition?: string
  isDefault?: boolean
  [key: string]: unknown
}

// ── Default positions for starter graphs ──────────────────────────────────────

const DEFAULT_POSITIONS: Record<string, { x: number; y: number }> = {
  start: { x: 250, y: 50 },
  end: { x: 250, y: 300 },
}

let _posCounter = 0

function nextPosition(): { x: number; y: number } {
  _posCounter++
  return { x: 100 + (_posCounter % 4) * 160, y: 100 + Math.floor(_posCounter / 4) * 120 }
}

const NODE_DIMENSIONS: Record<NodeType, { width: number; height: number }> = {
  START: { width: 48, height: 48 },
  END: { width: 48, height: 48 },
  HUMAN_TASK: { width: 180, height: 72 },
  SERVICE_TASK: { width: 180, height: 72 },
  EXCLUSIVE_GATEWAY: { width: 56, height: 56 },
  PARALLEL_GATEWAY: { width: 56, height: 56 },
  TIMER: { width: 56, height: 56 },
  SUB_PROCESS: { width: 200, height: 80 },
}

// ── Converter ─────────────────────────────────────────────────────────────────

export interface GraphToFlowResult {
  nodes: Node<CanvasNodeData>[]
  edges: Edge<CanvasEdgeData>[]
}

export function graphToFlow(graph: DefinitionGraph): GraphToFlowResult {
  _posCounter = 0

  // Map node IDs to their persisted positions
  const persistedPositions = new Map<string, { x: number; y: number }>()
  for (const gn of graph.nodes) {
    if (gn.attributes?.position && typeof gn.attributes.position === 'object') {
      const pos = gn.attributes.position as { x: number; y: number }
      if (typeof pos.x === 'number' && typeof pos.y === 'number') {
        persistedPositions.set(gn.id, pos)
      }
    }
  }

  const nodes: Node<CanvasNodeData>[] = graph.nodes.map((gn) => {
    const dims = NODE_DIMENSIONS[gn.type] ?? { width: 180, height: 72 }
    const defaultPos = DEFAULT_POSITIONS[gn.id] ?? nextPosition()
    const position = persistedPositions.get(gn.id) ?? defaultPos

    return {
      id: gn.id,
      type: gn.type.toLowerCase(), // React Flow uses lowercase node type keys
      position,
      data: {
        nodeType: gn.type,
        name: gn.name ?? '',
        attributes: gn.attributes ?? {},
      },
      width: dims.width,
      height: dims.height,
    }
  })

  const edges: Edge<CanvasEdgeData>[] = graph.edges.map((ge) => ({
    id: ge.id,
    source: ge.source,
    target: ge.target,
    type: 'condition',
    data: {
      condition: ge.condition,
      isDefault: ge.is_default ?? false,
    },
  }))

  return { nodes, edges }
}
