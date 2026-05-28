/**
 * flowToGraph — React Flow nodes/edges → DefinitionGraph (API)
 *
 * Serialises the current React Flow canvas state back into the
 * DefinitionGraph shape for PUT /api/v1/definitions/:id.
 * Persists node positions as attributes.position for round-trip layout.
 */

import type { Node, Edge } from '@xyflow/react'
import type { DefinitionGraph, GraphNode, GraphEdge } from '@/types/api'
import type { CanvasNodeData, CanvasEdgeData } from './graphToFlow'

export function flowToGraph(
  nodes: Node<CanvasNodeData>[],
  edges: Edge<CanvasEdgeData>[],
): DefinitionGraph {
  const graphNodes: GraphNode[] = nodes.map((node) => {
    const attrs: Record<string, unknown> = {
      ...(node.data.attributes ?? {}),
      position: { x: Math.round(node.position.x), y: Math.round(node.position.y) },
    }
    return {
      id: node.id,
      type: node.data.nodeType,
      name: node.data.name || undefined,
      attributes: attrs,
    }
  })

  const graphEdges: GraphEdge[] = edges.map((edge) => ({
    id: edge.id,
    source: edge.source,
    target: edge.target,
    condition: edge.data?.condition || undefined,
    is_default: edge.data?.isDefault ?? false,
  }))

  return { nodes: graphNodes, edges: graphEdges }
}
