import { useCallback, useRef, useState, useEffect, type DragEvent } from 'react'
import {
  ReactFlow,
  Background,
  MiniMap,
  Controls,
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
  useReactFlow,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'

import type { NodeType } from '@/types/api'
import type { CanvasNodeData, CanvasEdgeData } from '@/utils/canvas/graphToFlow'
import { useCanvasHistoryStore } from '@/stores/canvasHistoryStore'

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

// ── Helper: minimap node color matching node type ────────────────────────────

function minimapNodeColor(node: Node<CanvasNodeData>) {
  const nodeType = node.data?.nodeType
  switch (nodeType) {
    case 'START':
      return 'var(--color-brand-400, #4dabf7)'
    case 'END':
      return 'var(--color-error, #fa5252)'
    case 'EXCLUSIVE_GATEWAY':
      return 'var(--color-warning-dark, #e67700)'
    case 'PARALLEL_GATEWAY':
      return 'var(--color-success-dark, #2f9e44)'
    default:
      return 'var(--color-brand-500, #339af0)'
  }
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
  /** External auto-layout trigger: apply Dagre layout to all nodes */
  autoLayoutTrigger?: { counter: number }
  /** External undo/redo trigger */
  undoTrigger?: { counter: number }
  redoTrigger?: { counter: number }
  /** Condition errors from server-side validation, keyed by edge source-target */
  conditionErrors?: Map<string, string>
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
  autoLayoutTrigger,
  undoTrigger,
  redoTrigger,
  conditionErrors,
}: ProcessCanvasProps) {
  const [nodes, setNodes, onNodesChange] = useNodesState(initialNodes)
  const [edges, setEdges, onEdgesChange] = useEdgesState(initialEdges)

  const reactFlowWrapper = useRef<HTMLDivElement>(null)
  const historyStore = useCanvasHistoryStore()
  const reactFlowInstance = useReactFlow()

  // ── Condition dialog state ──────────────────────────────────────────────────

  const [conditionDialog, setConditionDialog] = useState<{
    source: string
    target: string
    sourceName: string
    targetName: string
    serverError?: string | null
    initialCondition?: string
    initialIsDefault?: boolean
  } | null>(null)

  // ── Helper: take a snapshot of current canvas state ────────────────────────

  const takeSnapshot = useCallback(() => {
    const snapshot = {
      nodesJSON: JSON.stringify(nodes),
      edgesJSON: JSON.stringify(edges),
    }
    historyStore.pushSnapshot(snapshot)
  }, [nodes, edges, historyStore])

  // ── Sync canvas state to ref for parent serialization ───────────────────────

  useEffect(() => {
    canvasStateRef.current = {
      nodesJSON: JSON.stringify(nodes),
      edgesJSON: JSON.stringify(edges),
    }
  }, [nodes, edges, canvasStateRef])

  // ── Set condition errors on dialog when mapping changes ────────────────────

  // ── Edge creation ───────────────────────────────────────────────────────────

  const onConnect = useCallback(
    (connection: Connection) => {
      // Take snapshot before mutation
      takeSnapshot()

      const sourceNode = nodes.find((n) => n.id === connection.source)
      if (!sourceNode) return

      const sourceType = sourceNode.data.nodeType
      const sourceName = sourceNode.data.name || sourceType
      const targetNode = nodes.find((n) => n.id === connection.target)
      const targetName = targetNode?.data?.name || connection.target || ''

      if (sourceType === 'EXCLUSIVE_GATEWAY') {
        // Look up any condition error for this edge
        const edgeKey = `${connection.source}-${connection.target}`
        const err = conditionErrors?.get(edgeKey) ?? null
        setConditionDialog({
          source: connection.source,
          target: connection.target,
          sourceName,
          targetName,
          serverError: err,
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
    [nodes, setEdges, onDirtyChange, takeSnapshot, conditionErrors],
  )

  const handleConditionConfirm = useCallback(
    (data: { condition?: string; isDefault: boolean }) => {
      if (!conditionDialog) return
      const edgeId = `rf-edge-${conditionDialog.source}-${conditionDialog.target}`

      // Check if this edge already exists (e.g. opened via double-click on existing edge)
      const existingEdge = edges.find(
        (e) => e.source === conditionDialog.source && e.target === conditionDialog.target,
      )

      if (existingEdge) {
        // Update existing edge data in place
        setEdges((eds) =>
          eds.map((e) =>
            e.id === existingEdge.id
              ? { ...e, data: { ...e.data, condition: data.condition, isDefault: data.isDefault } }
              : e,
          ),
        )
      } else {
        // Create a new edge
        const newEdge: Edge<CanvasEdgeData> = {
          id: edgeId,
          source: conditionDialog.source,
          target: conditionDialog.target,
          type: 'condition',
          data: { condition: data.condition, isDefault: data.isDefault },
        }
        setEdges((eds) => addEdge(newEdge, eds))
      }

      setConditionDialog(null)
      onDirtyChange(true)
    },
    [conditionDialog, edges, setEdges, onDirtyChange],
  )

  const handleConditionCancel = useCallback(() => {
    setConditionDialog(null)
  }, [])

  // ── Handle external auto-layout trigger ───────────────────────────────────

  const prevAutoLayoutRef = useRef(0)
  useEffect(() => {
    if (!autoLayoutTrigger || autoLayoutTrigger.counter === prevAutoLayoutRef.current) return
    prevAutoLayoutRef.current = autoLayoutTrigger.counter
    if (isReadOnly) return

    // Take snapshot before auto-layout
    takeSnapshot()

    // Dynamic import to avoid bundling dagre eagerly
    import('@/utils/canvas/autoLayout').then(({ applyLayout }) => {
      const result = applyLayout(nodes, edges)
      if (result.nodes) {
        setNodes(result.nodes)
        onDirtyChange(true)
        // Fit view after layout
        setTimeout(() => {
          reactFlowInstance.fitView({ duration: 300 })
        }, 50)
      }
    })
  }, [autoLayoutTrigger, isReadOnly, setNodes, onDirtyChange, nodes, edges, takeSnapshot, reactFlowInstance])

  // ── Handle external undo/redo triggers ─────────────────────────────────────

  const prevUndoRef = useRef(0)
  useEffect(() => {
    if (!undoTrigger || undoTrigger.counter === prevUndoRef.current) return
    prevUndoRef.current = undoTrigger.counter

    const current = canvasStateRef.current
    if (!current) return
    const snapshot = historyStore.undo({ nodesJSON: current.nodesJSON, edgesJSON: current.edgesJSON })
    if (snapshot) {
      try {
        const restoredNodes = JSON.parse(snapshot.nodesJSON) as Node<CanvasNodeData>[]
        const restoredEdges = JSON.parse(snapshot.edgesJSON) as Edge<CanvasEdgeData>[]
        setNodes(restoredNodes)
        setEdges(restoredEdges)
        onDirtyChange(true)
      } catch { /* silent fallback on corrupted data */ }
    }
  }, [undoTrigger, canvasStateRef, historyStore, setNodes, setEdges, onDirtyChange])

  const prevRedoRef = useRef(0)
  useEffect(() => {
    if (!redoTrigger || redoTrigger.counter === prevRedoRef.current) return
    prevRedoRef.current = redoTrigger.counter

    const current = canvasStateRef.current
    if (!current) return
    const snapshot = historyStore.redo({ nodesJSON: current.nodesJSON, edgesJSON: current.edgesJSON })
    if (snapshot) {
      try {
        const restoredNodes = JSON.parse(snapshot.nodesJSON) as Node<CanvasNodeData>[]
        const restoredEdges = JSON.parse(snapshot.edgesJSON) as Edge<CanvasEdgeData>[]
        setNodes(restoredNodes)
        setEdges(restoredEdges)
        onDirtyChange(true)
      } catch { /* silent fallback on corrupted data */ }
    }
  }, [redoTrigger, canvasStateRef, historyStore, setNodes, setEdges, onDirtyChange])

  // ── Handle external add-node trigger from palette double-click ────────────

  const prevCounterRef = useRef(0)
  const prevUpdateCounterRef = useRef(0)
  const lastSnapshottedNodeRef = useRef<string | null>(null)

  // Handle node data updates from PropertyPanel
  useEffect(() => {
    if (!nodeUpdateTrigger || nodeUpdateTrigger.counter === prevUpdateCounterRef.current) return
    prevUpdateCounterRef.current = nodeUpdateTrigger.counter
    if (isReadOnly) return

    // Only take one snapshot per "edit session" — when the node being edited
    // changes. This prevents per-keystroke snapshots from flooding the undo
    // stack, ensuring Ctrl+Z restores the full pre-edit state.
    if (lastSnapshottedNodeRef.current !== nodeUpdateTrigger.nodeId) {
      takeSnapshot()
      lastSnapshottedNodeRef.current = nodeUpdateTrigger.nodeId
    }

    setNodes((nds) =>
      nds.map((n) =>
        n.id === nodeUpdateTrigger.nodeId
          ? { ...n, data: { ...n.data, ...nodeUpdateTrigger.data, name: nodeUpdateTrigger.data.name ?? n.data.name } }
          : n,
      ),
    )
  }, [nodeUpdateTrigger, isReadOnly, setNodes, takeSnapshot])
  useEffect(() => {
    if (!paletteAddTrigger || paletteAddTrigger.counter === prevCounterRef.current) return
    prevCounterRef.current = paletteAddTrigger.counter
    if (isReadOnly) return

    // Take snapshot before mutation
    takeSnapshot()

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
  }, [paletteAddTrigger, isReadOnly, setNodes, onDirtyChange, takeSnapshot])

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

      // Take snapshot before mutation
      takeSnapshot()

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
    [isReadOnly, setNodes, onDirtyChange, takeSnapshot],
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

  // ── Edge double-click: open ConditionDialog for EXCLUSIVE_GATEWAY edges ────

  const onEdgeDoubleClick = useCallback(
    (_: React.MouseEvent, edge: Edge<CanvasEdgeData>) => {
      const sourceNode = nodes.find((n) => n.id === edge.source)
      if (!sourceNode || sourceNode.data.nodeType !== 'EXCLUSIVE_GATEWAY') return

      const targetNode = nodes.find((n) => n.id === edge.target)
      const sourceName = sourceNode.data.name || 'Gateway'
      const targetName = targetNode?.data?.name || edge.target || ''

      setConditionDialog({
        source: edge.source,
        target: edge.target,
        sourceName,
        targetName,
        serverError: null,
        initialCondition: edge.data?.condition ?? '',
        initialIsDefault: edge.data?.isDefault ?? false,
      })
    },
    [nodes],
  )

  const onPaneClick = useCallback(() => {
    onSelectedNodeChange(null)
    onSelectedEdgeChange(null)
  }, [onSelectedNodeChange, onSelectedEdgeChange])

  // ── Mark dirty on any change; take snapshot on removes ─────────────────────

  const handleNodesChange: OnNodesChange<Node<CanvasNodeData>> = useCallback(
    (changes) => {
      // Take snapshot before removal
      const hasRemove = changes.some(c => c.type === 'remove')
      if (hasRemove) {
        takeSnapshot()
      }
      onNodesChange(changes)
      onDirtyChange(true)
    },
    [onNodesChange, onDirtyChange, takeSnapshot],
  )

  const handleEdgesChange: OnEdgesChange<Edge<CanvasEdgeData>> = useCallback(
    (changes) => {
      // Take snapshot before removal
      const hasRemove = changes.some(c => c.type === 'remove')
      if (hasRemove) {
        takeSnapshot()
      }
      onEdgesChange(changes)
      onDirtyChange(true)
    },
    [onEdgesChange, onDirtyChange, takeSnapshot],
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
        onEdgeDoubleClick={onEdgeDoubleClick}
        onPaneClick={onPaneClick}
        nodeTypes={nodeTypes}
        edgeTypes={edgeTypes}
        nodesDraggable={!isReadOnly}
        nodesConnectable={!isReadOnly}
        elementsSelectable={true}
        fitView
        fitViewOptions={{ maxZoom: 1.5 }}
        deleteKeyCode={['Backspace', 'Delete']}
        style={{ background: 'var(--surface-page, #f8f9fa)' }}
      >
        <Background color="#ccc" gap={20} />
        <MiniMap
          nodeColor={minimapNodeColor}
          maskColor="rgba(0,0,0,0.1)"
          style={{
            position: 'absolute',
            bottom: 12,
            right: 12,
            borderRadius: 8,
            boxShadow: '0 2px 8px rgba(0,0,0,0.15)',
          }}
        />
        <Controls
          position="bottom-left"
          style={{ borderRadius: 8, boxShadow: '0 2px 8px rgba(0,0,0,0.15)' }}
        />
      </ReactFlow>

      {/* Condition dialog */}
      {conditionDialog && (
        <ConditionDialog
          sourceName={conditionDialog.sourceName}
          targetName={conditionDialog.targetName}
          onConfirm={handleConditionConfirm}
          onCancel={handleConditionCancel}
          serverError={conditionDialog.serverError}
          initialCondition={conditionDialog.initialCondition}
          initialIsDefault={conditionDialog.initialIsDefault}
        />
      )}
    </div>
  )
}


