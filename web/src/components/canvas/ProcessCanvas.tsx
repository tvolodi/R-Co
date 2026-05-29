import { useCallback, useRef, useState, useEffect, type DragEvent } from 'react'
import {
  ReactFlow,
  Background,
  useNodesState,
  useEdgesState,
  addEdge,
  type Connection,
  type Node,
  type Edge,
  type NodeTypes,
  type EdgeTypes,
  type OnNodesChange,
  type OnEdgesChange,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'

import type { NodeType } from '@/types/api'
import type { CanvasNodeData, CanvasEdgeData } from '@/utils/canvas/graphToFlow'

import StartNode from './nodes/StartNode'
import EndNode from './nodes/EndNode'
import HumanTaskNode from './nodes/HumanTaskNode'
import ServiceTaskNode from './nodes/ServiceTaskNode'
import ExclusiveGatewayNode from './nodes/ExclusiveGatewayNode'
import ParallelGatewayNode from './nodes/ParallelGatewayNode'
import TimerNode from './nodes/TimerNode'
import SubProcessNode from './nodes/SubProcessNode'
import ConditionEdge from './edges/ConditionEdge'
import ConditionDialog from './ConditionDialog'
// ── Static type registries (defined outside component to prevent re-renders) ──

const nodeTypes: NodeTypes = {
  start: StartNode,
  end: EndNode,
  human_task: HumanTaskNode,
  service_task: ServiceTaskNode,
  exclusive_gateway: ExclusiveGatewayNode,
  parallel_gateway: ParallelGatewayNode,
  timer: TimerNode,
  sub_process: SubProcessNode,
}

const edgeTypes: EdgeTypes = {
  condition: ConditionEdge,
}

// ── Props ─────────────────────────────────────────────────────────────────────

interface ProcessCanvasProps {
  definitionId: string
  initialNodes: Node<CanvasNodeData>[]
  initialEdges: Edge<CanvasEdgeData>[]
  isReadOnly: boolean
  onDirtyChange: (dirty: boolean) => void
  /** Ref filled by ProcessCanvas with current nodes/edges JSON for serialization */
  canvasStateRef: React.MutableRefObject<{ nodesJSON: string; edgesJSON: string } | null>
  /** Called when selected node changes */
  onSelectedNodeChange: (id: string | null, nodeData?: CanvasNodeData) => void
  /** Called when selected edge changes */
  onSelectedEdgeChange: (id: string | null) => void
  /** External add-node trigger: incrementing counter + nodeType to add via palette double-click */
  paletteAddTrigger?: { counter: number; nodeType: string }
  /** External node update trigger: from PropertyPanel */
  nodeUpdateTrigger?: { nodeId: string; data: Partial<CanvasNodeData>; counter: number } | null
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function ProcessCanvas({
  initialNodes,
  initialEdges,
  isReadOnly,
  onDirtyChange,
  canvasStateRef,
  onSelectedNodeChange,
  onSelectedEdgeChange,
  paletteAddTrigger,
  nodeUpdateTrigger,
}: ProcessCanvasProps) {
  const [nodes, setNodes, onNodesChange] = useNodesState(initialNodes)
  const [edges, setEdges, onEdgesChange] = useEdgesState(initialEdges)

  const reactFlowWrapper = useRef<HTMLDivElement>(null)

  // ── Condition dialog state ──────────────────────────────────────────────────

  const [conditionDialog, setConditionDialog] = useState<{
    source: string
    target: string
    sourceName: string
    targetName: string
  } | null>(null)

  // ── Sync canvas state to ref for parent serialization ───────────────────────

  useEffect(() => {
    canvasStateRef.current = {
      nodesJSON: JSON.stringify(nodes),
      edgesJSON: JSON.stringify(edges),
    }
  }, [nodes, edges, canvasStateRef])

  // ── Edge creation ───────────────────────────────────────────────────────────

  const onConnect = useCallback(
    (connection: Connection) => {
      const sourceNode = nodes.find((n) => n.id === connection.source)
      if (!sourceNode) return

      const sourceType = sourceNode.data.nodeType
      const sourceName = sourceNode.data.name || sourceType
      const targetNode = nodes.find((n) => n.id === connection.target)
      const targetName = targetNode?.data?.name || connection.target || ''

      if (sourceType === 'EXCLUSIVE_GATEWAY') {
        setConditionDialog({
          source: connection.source,
          target: connection.target,
          sourceName,
          targetName,
        })
      } else {
        const newEdge: Edge<CanvasEdgeData> = {
          id: `rf-edge-${connection.source}-${connection.target}`,
          source: connection.source,
          target: connection.target,
          type: 'condition',
          data: { condition: undefined, isDefault: false },
        }
        setEdges((eds) => addEdge(newEdge, eds))
        onDirtyChange(true)
      }
    },
    [nodes, setEdges, onDirtyChange],
  )

  const handleConditionConfirm = useCallback(
    (data: { condition?: string; isDefault: boolean }) => {
      if (!conditionDialog) return
      const newEdge: Edge<CanvasEdgeData> = {
        id: `rf-edge-${conditionDialog.source}-${conditionDialog.target}`,
        source: conditionDialog.source,
        target: conditionDialog.target,
        type: 'condition',
        data: { condition: data.condition, isDefault: data.isDefault },
      }
      setEdges((eds) => addEdge(newEdge, eds))
      setConditionDialog(null)
      onDirtyChange(true)
    },
    [conditionDialog, setEdges, onDirtyChange],
  )

  const handleConditionCancel = useCallback(() => {
    setConditionDialog(null)
  }, [])

  // ── Handle external add-node trigger from palette double-click ────────────

  const prevCounterRef = useRef(0)
  const prevUpdateCounterRef = useRef(0)

  // Handle node data updates from PropertyPanel
  useEffect(() => {
    if (!nodeUpdateTrigger || nodeUpdateTrigger.counter === prevUpdateCounterRef.current) return
    prevUpdateCounterRef.current = nodeUpdateTrigger.counter
    if (isReadOnly) return

    setNodes((nds) =>
      nds.map((n) =>
        n.id === nodeUpdateTrigger.nodeId
          ? { ...n, data: { ...n.data, ...nodeUpdateTrigger.data, name: nodeUpdateTrigger.data.name ?? n.data.name } }
          : n,
      ),
    )
  }, [nodeUpdateTrigger, isReadOnly, setNodes])
  useEffect(() => {
    if (!paletteAddTrigger || paletteAddTrigger.counter === prevCounterRef.current) return
    prevCounterRef.current = paletteAddTrigger.counter
    if (isReadOnly) return

    const nodeType = paletteAddTrigger.nodeType as NodeType
    const position = { x: 100 + Math.random() * 400, y: 100 + Math.random() * 300 }
    const newNode: Node<CanvasNodeData> = {
      id: `node-${Date.now()}`,
      type: nodeType.toLowerCase(),
      position,
      data: {
        nodeType,
        name: '',
        attributes: {},
      },
    }
    setNodes((nds) => [...nds, newNode])
    onDirtyChange(true)
  }, [paletteAddTrigger, isReadOnly, setNodes, onDirtyChange])

  // ── Drag-and-drop from palette ─────────────────────────────────────────────

  const onDragOver = useCallback((e: DragEvent<HTMLDivElement>) => {
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
  }, [])

  const onDrop = useCallback(
    (e: DragEvent<HTMLDivElement>) => {
      e.preventDefault()
      const nodeType = e.dataTransfer.getData('application/bpm-node-type') as NodeType | ''
      if (!nodeType || isReadOnly) return

      const bounds = reactFlowWrapper.current?.getBoundingClientRect()
      if (!bounds) return

      const position = {
        x: e.clientX - bounds.left - 90,
        y: e.clientY - bounds.top - 36,
      }

      const newNode: Node<CanvasNodeData> = {
        id: `node-${Date.now()}`,
        type: nodeType.toLowerCase(),
        position,
        data: {
          nodeType,
          name: '',
          attributes: {},
        },
      }
      setNodes((nds) => [...nds, newNode])
      onDirtyChange(true)
    },
    [isReadOnly, setNodes, onDirtyChange],
  )

  // ── Node/edge selection ─────────────────────────────────────────────────────

  const onNodeClick = useCallback(
    (_: React.MouseEvent, node: Node<CanvasNodeData>) => {
      onSelectedNodeChange(node.id, node.data)
      onSelectedEdgeChange(null)
    },
    [onSelectedNodeChange, onSelectedEdgeChange],
  )

  const onEdgeClick = useCallback(
    (_: React.MouseEvent, edge: Edge) => {
      onSelectedEdgeChange(edge.id)
      onSelectedNodeChange(null)
    },
    [onSelectedEdgeChange, onSelectedNodeChange],
  )

  const onPaneClick = useCallback(() => {
    onSelectedNodeChange(null)
    onSelectedEdgeChange(null)
  }, [onSelectedNodeChange, onSelectedEdgeChange])

  // ── Mark dirty on any change ────────────────────────────────────────────────

  const handleNodesChange: OnNodesChange<Node<CanvasNodeData>> = useCallback(
    (changes) => {
      onNodesChange(changes)
      onDirtyChange(true)
    },
    [onNodesChange, onDirtyChange],
  )

  const handleEdgesChange: OnEdgesChange<Edge<CanvasEdgeData>> = useCallback(
    (changes) => {
      onEdgesChange(changes)
      onDirtyChange(true)
    },
    [onEdgesChange, onDirtyChange],
  )

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <div ref={reactFlowWrapper} data-testid="process-canvas" style={{ width: '100%', height: '100%', position: 'relative' }}>
      <ReactFlow
        nodes={nodes}
        edges={edges}
        onNodesChange={handleNodesChange}
        onEdgesChange={handleEdgesChange}
        onConnect={onConnect}
        onDrop={onDrop}
        onDragOver={onDragOver}
        onNodeClick={onNodeClick}
        onEdgeClick={onEdgeClick}
        onPaneClick={onPaneClick}
        nodeTypes={nodeTypes}
        edgeTypes={edgeTypes}
        nodesDraggable={!isReadOnly}
        nodesConnectable={!isReadOnly}
        elementsSelectable={true}
        fitView
        deleteKeyCode={['Backspace', 'Delete']}
        style={{ background: 'var(--surface-page, #f8f9fa)' }}
      >
        <Background color="#ccc" gap={20} />
      </ReactFlow>

      {/* Condition dialog */}
      {conditionDialog && (
        <ConditionDialog
          sourceName={conditionDialog.sourceName}
          targetName={conditionDialog.targetName}
          onConfirm={handleConditionConfirm}
          onCancel={handleConditionCancel}
        />
      )}
    </div>
  )
}


