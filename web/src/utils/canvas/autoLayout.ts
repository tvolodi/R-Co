/**
 * autoLayout — Dagre-based DAG layout algorithm for canvas nodes
 *
 * Applies a Sugiyama-style layered layout (top-to-bottom by default)
 * to the current set of nodes and edges. Returns repositioned nodes
 * with smooth transitions enabled.
 */

import dagre from '@dagrejs/dagre'
import type { Node, Edge } from '@xyflow/react'
import type { CanvasNodeData, CanvasEdgeData } from './graphToFlow'

// ── Node dimensions (matching design system + React Flow node sizes) ──────────

const NODE_DIMS: Record<string, { width: number; height: number }> = {
  START: { width: 48, height: 48 },
  END: { width: 48, height: 48 },
  HUMAN_TASK: { width: 180, height: 72 },
  SERVICE_TASK: { width: 180, height: 72 },
  EXCLUSIVE_GATEWAY: { width: 56, height: 56 },
  PARALLEL_GATEWAY: { width: 56, height: 56 },
  TIMER: { width: 56, height: 56 },
  SUB_PROCESS: { width: 200, height: 80 },
}

function getNodeDimensions(nodeType: string): { width: number; height: number } {
  return NODE_DIMS[nodeType] ?? { width: 180, height: 72 }
}

// ── Layout function ───────────────────────────────────────────────────────────

export interface ApplyLayoutResult {
  nodes: Node<CanvasNodeData>[]
}

/**
 * Apply a Dagre-based layered layout to the given nodes and edges.
 *
 * @param nodes - Current React Flow nodes
 * @param edges - Current React Flow edges
 * @param direction - Layout direction: 'TB' (top-to-bottom) or 'LR' (left-to-right)
 * @returns New node array with updated positions
 */
export function applyLayout(
  nodes: Node<CanvasNodeData>[],
  edges: Edge<CanvasEdgeData>[],
  direction: 'TB' | 'LR' = 'TB',
): ApplyLayoutResult {
  if (nodes.length === 0) {
    return { nodes }
  }

  const g = new dagre.graphlib.Graph()
  g.setDefaultEdgeLabel(() => ({}))

  // Direction: top-to-bottom (rankdir = TB)
  g.setGraph({
    rankdir: direction,
    nodesep: 60,
    ranksep: 80,
    marginx: 40,
    marginy: 40,
  })

  // Register nodes with dimensions
  for (const node of nodes) {
    const dims = getNodeDimensions(node.data.nodeType ?? 'HUMAN_TASK')
    g.setNode(node.id, { width: dims.width, height: dims.height })
  }

  // Register edges
  for (const edge of edges) {
    g.setEdge(edge.source, edge.target)
  }

  // Run layout
  dagre.layout(g)

  // Map laid-out positions back to React Flow nodes
  // Dagre returns center coordinates; React Flow uses top-left origin
  const updatedNodes = nodes.map((node) => {
    const dagreNode = g.node(node.id)
    if (!dagreNode) return node

    const dims = getNodeDimensions(node.data.nodeType ?? 'HUMAN_TASK')
    const x = dagreNode.x - dims.width / 2
    const y = dagreNode.y - dims.height / 2

    return {
      ...node,
      position: { x: Math.round(x), y: Math.round(y) },
    }
  })

  return { nodes: updatedNodes }
}
