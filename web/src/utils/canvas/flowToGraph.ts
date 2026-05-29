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
    let attrs: string | null = null
    try {
      const existing = typeof node.data.attributes === 'string' && node.data.attributes ? JSON.parse(node.data.attributes) : {}
      attrs = JSON.stringify({
        ...existing,
        position: { x: Math.round(node.position.x), y: Math.round(node.position.y) },
      })
    } catch {
      attrs = JSON.stringify({ position: { x: Math.round(node.position.x), y: Math.round(node.position.y) } })
    }
    return {
      id: node.id,
      node_type: node.data.nodeType,
      label: node.data.name || null,
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
