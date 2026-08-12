/**
 * DefinitionEditorPage — Visual Process Designer Canvas
 *
 * Integrates ReactFlow canvas, node palette, property panel, validation bar,
 * and save workflow. Replaces the old JSON textarea as the primary editor.
 */

import { useParams, useBlocker } from 'react-router-dom'
import { useState, useRef, useMemo, useCallback, useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { ReactFlowProvider } from '@xyflow/react'
import type { Node, Edge } from '@xyflow/react'

import { useDefinition, useCreateDefinition } from '@/hooks/useDefinitions'
import { definitionsApi } from '@/api/definitions'
import { useAuth } from '@/auth/AuthContext'
import { useTenantContext } from '@/auth/useTenantContext'
import { queryKeys } from '@/api/queryKeys'
import type { DefinitionGraph } from '@/types/api'
import type { CanvasNodeData, CanvasEdgeData } from '@/utils/canvas/graphToFlow'
import { graphToFlow } from '@/utils/canvas/graphToFlow'
import { flowToGraph } from '@/utils/canvas/flowToGraph'
import { useCanvasHistoryStore } from '@/stores/canvasHistoryStore'
import { ConfirmPromoteModal } from '@/components/ui/ConfirmPromoteModal'

import ProcessCanvas from '@/components/canvas/ProcessCanvas'
import NodePalette from '@/components/canvas/NodePalette'
import PropertyPanel from '@/components/canvas/PropertyPanel'
import ValidationSummaryBar from '@/components/canvas/ValidationSummaryBar'
import type { ValidationError } from '@/components/canvas/ValidationSummaryBar'

const DESIGNER_ROLES = ['PROCESS_DESIGNER', 'PLATFORM_ADMIN']

// ── Empty starter graph ───────────────────────────────────────────────────────

const EMPTY_GRAPH: DefinitionGraph = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [{ id: 'e1', source: 'start', target: 'end' }],
}

// ── Page component ────────────────────────────────────────────────────────────

export default function DefinitionEditorPage() {
  const { id } = useParams<{ id?: string }>()
  const isNew = !id
  const { data: def, isLoading } = useDefinition(id!)
  const create = useCreateDefinition()
  const { session } = useAuth()
  const { tenantType, productionDisplayName, tenantId } = useTenantContext()
  const qc = useQueryClient()

  const [name, setName] = useState('')
  const [version, setVersion] = useState('1.0.0')
  const [description, setDescription] = useState('')
  const [saved, setSaved] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [showRawJson, setShowRawJson] = useState(false)
  const [exportError, setExportError] = useState<string | null>(null)
  const [exporting, setExporting] = useState(false)
  const [showPromoteModal, setShowPromoteModal] = useState(false)
  const [promoting, setPromoting] = useState(false)
  const [promoteMessage, setPromoteMessage] = useState<string | null>(null)
  const [promoteError, setPromoteError] = useState<string | null>(null)

  const hasDesignerRole = session?.roles?.some((r) => DESIGNER_ROLES.includes(r)) ?? false

  // ── Canvas state ────────────────────────────────────────────────────────────

  const [dirty, setDirty] = useState(false)
  const [validationErrors, setValidationErrors] = useState<ValidationError[]>([])
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [selectedNodeData, _setSelectedNodeData] = useState<CanvasNodeData | undefined>(undefined)
  const [selectedEdgeId, setSelectedEdgeId] = useState<string | null>(null)
  const [paletteAddCounter, setPaletteAddCounter] = useState(0)
  const [paletteAddNodeType, setPaletteAddNodeType] = useState<string | null>(null)

  // ── Undo/redo triggers ──────────────────────────────────────────────────────
  const [undoCounter, setUndoCounter] = useState(0)
  const [redoCouter, setRedoCounter] = useState(0)
  const undoTrigger = useMemo(() => ({ counter: undoCounter }), [undoCounter])
  const redoTrigger = useMemo(() => ({ counter: redoCouter }), [redoCouter])

  // ── Auto-layout trigger ─────────────────────────────────────────────────────
  const [autoLayoutCounter, setAutoLayoutCounter] = useState(0)
  const autoLayoutTrigger = useMemo(() => ({ counter: autoLayoutCounter }), [autoLayoutCounter])

  // ── Condition errors from server-side validation ────────────────────────────
  const [conditionErrors, setConditionErrors] = useState<Map<string, string>>(new Map())

  // Ref to hold current canvas nodes/edges for serialization (filled by ProcessCanvas)
  const canvasStateRef = useRef<{ nodesJSON: string; edgesJSON: string } | null>(null)

  // Graph data
  const currentGraph = def?.graph ?? EMPTY_GRAPH
  const isReadOnly = !isNew && def?.status !== 'DRAFT' && def?.status !== undefined

  // Convert API graph → React Flow on definition load
  const { nodes: initialNodes, edges: initialEdges } = useMemo(
    () => graphToFlow(currentGraph),
    [currentGraph],
  )

  // Build a node name map for the property panel
  const nodeNames = useMemo(() => {
    const map = new Map<string, string>()
    for (const gn of currentGraph.nodes) {
      map.set(gn.id, gn.label || gn.node_type)
    }
    return map
  }, [currentGraph])
  // ── Promote to Production handler ───────────────────────────────────────────

  async function handlePromoteConfirm() {
    if (!def?.name || !tenantId) return
    setPromoting(true)
    setPromoteError(null)
    try {
      await definitionsApi.promote(tenantId, def.name)
      setShowPromoteModal(false)
      qc.invalidateQueries({ queryKey: queryKeys.definitions.all })
      setPromoteMessage('Definition promoted. A DRAFT version is now available in production.')
      setTimeout(() => setPromoteMessage(null), 4000)
    } catch (e: unknown) {
      const err = e as { code?: string; message?: string }
      const codeMap: Record<string, string> = {
        not_a_test_tenant: 'This operation requires a test tenant.',
        production_tenant_inactive: 'The paired production tenant is inactive. Contact your platform administrator.',
        forbidden: 'You do not have the required role on both tenants.',
      }
      setPromoteError(err.code ? (codeMap[err.code] ?? 'Promotion failed. Please try again.') : 'Promotion failed. Please try again.')
    } finally {
      setPromoting(false)
    }
  }
  // ── Export handler ──────────────────────────────────────────────────────────

  async function handleExport() {
    if (!def?.id || isNew) return
    setExportError(null)
    setExporting(true)
    try {
      const exportData = await definitionsApi.exportJson(def.id)
      const blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `definition-${def.name}-${def.version}.json`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)
    } catch (err: unknown) {
      const apiErr = err as { status?: number; message?: string }
      if (apiErr.status === 404) {
        setExportError('Definition not found')
      } else {
        setExportError(apiErr.message ?? 'Export failed')
      }
    } finally {
      setExporting(false)
    }
  }

  // ── Save handler ────────────────────────────────────────────────────────────

  async function handleSave() {
    setError(null)
    setConditionErrors(new Map())

    const state = canvasStateRef.current
    if (!state) {
      setError('Canvas not ready.')
      return
    }

    try {
      const nodes: Node<CanvasNodeData>[] = JSON.parse(state.nodesJSON)
      const edges: Edge<CanvasEdgeData>[] = JSON.parse(state.edgesJSON)
      const graph = flowToGraph(nodes, edges)

      if (isNew) {
        await create.mutateAsync({ name, version, description, graph })
      } else {
        await definitionsApi.update(id!, { name: def!.name, version: def!.version, description: def!.description ?? undefined, graph, stage: null })
      }

      // Clear undo history on successful save
      useCanvasHistoryStore.getState().clear()
      setDirty(false)
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
    } catch (e: unknown) {
      const err = e as { status?: number; details?: Record<string, unknown>; message?: string }
      // Parse RFC 9457 Problem Details for condition errors
      if (err.details && typeof err.details === 'object') {
        const rawDetails = err.details
        const detailArr = Array.isArray(rawDetails) ? (rawDetails as Array<{ loc?: string; message?: string }>) : []
        if (detailArr.length > 0) {
          const errors = new Map<string, string>()
          for (const d of detailArr) {
            if (d.loc && d.loc.includes('condition')) {
              errors.set(d.loc, d.message ?? 'Invalid condition')
            }
          }
          if (errors.size > 0) setConditionErrors(errors)
        }
      }
      setError(err instanceof SyntaxError ? 'Invalid graph data' : (err.message ?? 'Save failed'))
    }
  }

  // ── Validation logic ────────────────────────────────────────────────────────

  useEffect(() => {
    const state = canvasStateRef.current
    if (!state) {
      setValidationErrors([])
      return
    }
    try {
      const nodes: Node<CanvasNodeData>[] = JSON.parse(state.nodesJSON)
      const edges: Edge<CanvasEdgeData>[] = JSON.parse(state.edgesJSON)
      const errors: ValidationError[] = []

      const hasStart = nodes.some((n) => n.data.nodeType === 'START')
      const hasEnd = nodes.some((n) => n.data.nodeType === 'END')

      if (!hasStart) {
        errors.push({ message: 'Graph must contain a START node.', severity: 'warning' })
      }
      if (!hasEnd) {
        errors.push({ message: 'Graph must contain an END node.', severity: 'warning' })
      }

      // Check for unnamed nodes (except START/END)
      for (const node of nodes) {
        if (node.data.nodeType !== 'START' && node.data.nodeType !== 'END' && !node.data.name?.trim()) {
          errors.push({
            nodeId: node.id,
            message: `${node.data.nodeType.replace(/_/g, ' ')} node "${node.id}" has no name.`,
            severity: 'warning',
          })
        }
        // Check EXCLUSIVE_GATEWAY has at least 2 outgoing edges
        if (node.data.nodeType === 'EXCLUSIVE_GATEWAY') {
          const outgoing = edges.filter((e) => e.source === node.id)
          if (outgoing.length < 2) {
            errors.push({
              nodeId: node.id,
              message: `EXCLUSIVE_GATEWAY "${node.id}" should have at least 2 outgoing edges.`,
              severity: 'warning',
            })
          }
        }
      }

      setValidationErrors(errors)
    } catch {
      setValidationErrors([])
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canvasStateRef.current, dirty])

  // ── Keyboard shortcuts (Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y) ───────────────────

  useEffect(() => {
    const handler = (e: globalThis.KeyboardEvent) => {
      if (isReadOnly) return
      if ((e.ctrlKey || e.metaKey) && e.key === 'z' && !e.shiftKey) {
        e.preventDefault()
        setUndoCounter((c) => c + 1)
      }
      if ((e.ctrlKey || e.metaKey) && e.key === 'z' && e.shiftKey) {
        e.preventDefault()
        setRedoCounter((c) => c + 1)
      }
      if ((e.ctrlKey || e.metaKey) && e.key === 'y') {
        e.preventDefault()
        setRedoCounter((c) => c + 1)
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [isReadOnly])

  // ── Clear history on definition change ──────────────────────────────────────

  useEffect(() => {
    useCanvasHistoryStore.getState().clear()
  }, [id])

  // ── Unsaved changes guard ───────────────────────────────────────────────────

  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) =>
      dirty && currentLocation.pathname !== nextLocation.pathname,
  )

  const handleDiscardAndProceed = useCallback(() => {
    if (blocker.state === 'blocked') {
      setDirty(false)
      blocker.proceed()
    }
  }, [blocker])

  const handleCancelNavigation = useCallback(() => {
    if (blocker.state === 'blocked') {
      blocker.reset()
    }
  }, [blocker])

  useEffect(() => {
    const handler = (e: BeforeUnloadEvent) => {
      if (dirty) {
        e.preventDefault()
        e.returnValue = ''
      }
    }
    window.addEventListener('beforeunload', handler)
    return () => window.removeEventListener('beforeunload', handler)
  }, [dirty])

  // ── Palette add-node via double-click ──────────────────────────────────────

  const handleAddNodeFromPalette = useCallback((nodeType: import('@/types/api').NodeType) => {
    if (isReadOnly) return
    setPaletteAddNodeType(nodeType)
    setPaletteAddCounter((c) => c + 1)
  }, [isReadOnly])

  const paletteAddTrigger = useMemo(() => {
    if (paletteAddCounter === 0 || !paletteAddNodeType) return undefined
    return { counter: paletteAddCounter, nodeType: paletteAddNodeType }
  }, [paletteAddCounter, paletteAddNodeType])


  // ── Node update trigger (PropPanel → ProcessCanvas) ───────────────────────

  const [nodeUpdateTrigger, setNodeUpdateTrigger] = useState<{
    nodeId: string
    data: Partial<CanvasNodeData>
    counter: number
  } | null>(null)
  const nodeUpdateCounterRef = useRef(0)

  // ── Property panel callbacks ────────────────────────────────────────────────

  const handleUpdateNode = useCallback(
    (nodeId: string, data: Partial<CanvasNodeData>) => {
      setDirty(true)
      nodeUpdateCounterRef.current += 1
      setNodeUpdateTrigger({ nodeId, data, counter: nodeUpdateCounterRef.current })
    },
    [setDirty],
  )

  const handleDeleteEdge = useCallback(
    (_edgeId: string) => { setDirty(true); void _edgeId; },
    [setDirty],
  )

  // ── Build current graph JSON for the raw JSON drawer ────────────────────────

  const currentGraphJson = useMemo(() => {
    const state = canvasStateRef.current
    if (!state) return JSON.stringify(EMPTY_GRAPH, null, 2)
    try {
      const nodes: Node<CanvasNodeData>[] = JSON.parse(state.nodesJSON)
      const edges: Edge<CanvasEdgeData>[] = JSON.parse(state.edgesJSON)
      return JSON.stringify(flowToGraph(nodes, edges), null, 2)
    } catch {
      return JSON.stringify(EMPTY_GRAPH, null, 2)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canvasStateRef.current, validationErrors])

  // ── Loading state ───────────────────────────────────────────────────────────

  if (!isNew && isLoading) {
    return (
      <div style={{ padding: '1.5rem', color: 'var(--text-secondary, #6c757d)' }}>
        Loading…
      </div>
    )
  }

  // ── Get selected node/edge for property panel from canvas ───────────────────
  // These are managed inside ProcessCanvas, but we pass them down via props
  // and get changes back via callbacks

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        height: '100%',
        background: 'var(--surface-page, #f8f9fa)',
      }}
    >
      {/* ── Toolbar ─────────────────────────────────────────────── */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '8px 16px',
          background: 'var(--surface-card, #fff)',
          borderBottom: '1px solid var(--border-default, #e9ecef)',
          gap: 12,
          flexWrap: 'wrap',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <h2 style={{ margin: 0, fontSize: 'var(--text-lg, 1.125rem)', fontWeight: 600, color: 'var(--text-primary, #212529)' }}>
            {isNew ? 'New Definition' : def?.name ?? 'Process Designer'}
          </h2>
          {isNew && (
            <span style={{ fontSize: 'var(--text-xs, 0.75rem)', color: 'var(--text-secondary, #6c757d)' }}>
              DRAFT
            </span>
          )}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {hasDesignerRole && !isNew && (
            <button
              data-testid="btn-export-definition"
              onClick={handleExport}
              disabled={exporting}
              style={toolbarButtonStyle(undefined)}
            >
              {exporting ? 'Exporting…' : 'Export'}
            </button>
          )}
          {hasDesignerRole && !isNew && tenantType === 'test' && def?.status === 'ACTIVE' && (
            <button
              data-testid="promote-to-production-btn"
              onClick={() => { setPromoteError(null); setShowPromoteModal(true) }}
              style={toolbarButtonStyle(undefined)}
            >
              Promote to Production
            </button>
          )}
          {!isReadOnly && (
            <>
              <button
                data-testid="btn-show-raw-json"
                onClick={() => setShowRawJson(!showRawJson)}
                style={toolbarButtonStyle(showRawJson ? 'var(--color-neutral-200, #e9ecef)' : undefined)}
              >
                {showRawJson ? 'Hide Raw JSON' : 'Show Raw JSON'}
              </button>
              <button
                data-testid="btn-auto-layout"
                onClick={() => setAutoLayoutCounter((c) => c + 1)}
                style={toolbarButtonStyle(undefined)}
                title="Auto-arrange nodes using Dagre layout"
              >
                Re-layout
              </button>
              <button
                data-testid="btn-save-definition"
                onClick={handleSave}
                disabled={create.isPending}
                style={{
                  ...toolbarButtonStyle('var(--interactive-primary, #228be6)'),
                  color: '#fff',
                  fontWeight: 500,
                }}
              >
                {create.isPending ? 'Saving…' : 'Save'}
              </button>
            </>
          )}
          {isReadOnly && (
            <span
              data-testid="read-only-banner"
              style={{
                fontSize: 'var(--text-sm, 0.875rem)',
                color: 'var(--color-warning-dark, #e67700)',
                background: 'var(--color-warning-light, #fff3bf)',
                padding: '4px 12px',
                borderRadius: 4,
              }}
            >
              Read-only — {def?.status ?? 'UNKNOWN'} status
            </span>
          )}
        </div>
      </div>

      {/* ── Error/success banners ──────────────────────────────── */}
      {error && (
        <div
          style={{
            padding: '8px 16px',
            background: 'var(--color-error-light, #ffe3e3)',
            color: 'var(--color-error-dark, #c92a2a)',
            fontSize: 'var(--text-sm, 0.875rem)',
            borderBottom: '1px solid var(--color-error, #fa5252)',
          }}
        >
          {error}
        </div>
      )}

      {exportError && (
        <div
          style={{
            padding: '8px 16px',
            background: 'var(--color-error-light, #ffe3e3)',
            color: 'var(--color-error-dark, #c92a2a)',
            fontSize: 'var(--text-sm, 0.875rem)',
            borderBottom: '1px solid var(--color-error, #fa5252)',
          }}
        >
          {exportError}
        </div>
      )}

      {saved && (
        <div
          data-testid="save-success-toast"
          style={{
            padding: '8px 16px',
            background: 'var(--color-success-light, #d3f9d8)',
            color: 'var(--color-success-dark, #2f9e44)',
            fontSize: 'var(--text-sm, 0.875rem)',
            borderBottom: '1px solid var(--color-success, #40c057)',
          }}
        >
          Definition saved.
        </div>
      )}

      {promoteMessage && (
        <div
          data-testid="promote-success-toast"
          style={{
            padding: '8px 16px',
            background: 'var(--color-success-light, #d3f9d8)',
            color: 'var(--color-success-dark, #2f9e44)',
            fontSize: 'var(--text-sm, 0.875rem)',
            borderBottom: '1px solid var(--color-success, #40c057)',
          }}
        >
          {promoteMessage}
        </div>
      )}

      {promoteError && (
        <div
          data-testid="promote-error-toast"
          style={{
            padding: '8px 16px',
            background: 'var(--color-error-light, #ffe3e3)',
            color: 'var(--color-error-dark, #c92a2a)',
            fontSize: 'var(--text-sm, 0.875rem)',
            borderBottom: '1px solid var(--color-error, #fa5252)',
          }}
        >
          {promoteError}
        </div>
      )}

      {/* ── New definition metadata (create mode) ───────────────── */}
      {isNew && (
        <div
          style={{
            padding: '12px 16px',
            background: 'var(--surface-card, #fff)',
            borderBottom: '1px solid var(--border-default, #e9ecef)',
            display: 'flex',
            gap: 12,
            flexWrap: 'wrap',
          }}
        >
          <div style={{ flex: 2, minWidth: 200 }}>
            <label style={{ display: 'block', fontSize: 'var(--text-xs, 0.75rem)', fontWeight: 500, marginBottom: 2, color: 'var(--text-secondary, #6c757d)' }}>
              Name
            </label>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Definition name"
              style={inlineInputStyle}
            />
          </div>
          <div style={{ flex: 1, minWidth: 100 }}>
            <label style={{ display: 'block', fontSize: 'var(--text-xs, 0.75rem)', fontWeight: 500, marginBottom: 2, color: 'var(--text-secondary, #6c757d)' }}>
              Version
            </label>
            <input
              value={version}
              onChange={(e) => setVersion(e.target.value)}
              style={{ ...inlineInputStyle, maxWidth: 120 }}
            />
          </div>
          <div style={{ flex: 3, minWidth: 200 }}>
            <label style={{ display: 'block', fontSize: 'var(--text-xs, 0.75rem)', fontWeight: 500, marginBottom: 2, color: 'var(--text-secondary, #6c757d)' }}>
              Description
            </label>
            <input
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Optional description"
              style={inlineInputStyle}
            />
          </div>
        </div>
      )}

      {/* ── Main layout: Palette | Canvas | Property Panel ─────── */}
      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
        <ReactFlowProvider>
          <NodePalette isReadOnly={isReadOnly} onAddNode={handleAddNodeFromPalette} />

          <div style={{ flex: 1, position: 'relative', display: 'flex', flexDirection: 'column' }}>
            <ProcessCanvas
              definitionId={id ?? ''}
              initialNodes={initialNodes}
              initialEdges={initialEdges}
              isReadOnly={isReadOnly}
              onDirtyChange={setDirty}
              canvasStateRef={canvasStateRef}
              onSelectedNodeChange={(id, nodeData) => { setSelectedNodeId(id); if (nodeData !== undefined) _setSelectedNodeData(nodeData) }}
              onSelectedEdgeChange={setSelectedEdgeId}
              paletteAddTrigger={paletteAddTrigger}
              nodeUpdateTrigger={nodeUpdateTrigger}
              autoLayoutTrigger={autoLayoutTrigger}
              undoTrigger={undoTrigger}
              redoTrigger={redoTrigger}
              conditionErrors={conditionErrors}
            />

            {/* Raw JSON drawer */}
            {showRawJson && (
              <div
                data-testid="raw-json-drawer"
                style={{
                  borderTop: '1px solid var(--border-default, #e9ecef)',
                  background: 'var(--surface-card, #fff)',
                }}
              >
                <div
                  style={{
                    padding: '6px 16px',
                    fontSize: 'var(--text-xs, 0.75rem)',
                    fontWeight: 500,
                    color: 'var(--text-secondary, #6c757d)',
                    borderBottom: '1px solid var(--border-default, #e9ecef)',
                  }}
                >
                  Raw Graph JSON (debug)
                </div>
                <textarea
                  data-testid="raw-json-textarea"
                  readOnly
                  value={currentGraphJson}
                  rows={8}
                  style={{
                    width: '100%',
                    padding: '8px 16px',
                    border: 'none',
                    fontFamily: 'var(--font-mono, monospace)',
                    fontSize: 'var(--text-xs, 0.75rem)',
                    resize: 'vertical',
                    boxSizing: 'border-box',
                    background: 'var(--color-neutral-50, #f8f9fa)',
                    color: 'var(--text-primary, #212529)',
                  }}
                />
              </div>
            )}

            <ValidationSummaryBar errors={validationErrors} />
          </div>

          <PropertyPanel
            selectedNodeId={selectedNodeId}
            selectedNodeData={selectedNodeData}
            selectedEdgeId={selectedEdgeId}
            nodeNames={nodeNames}
            onUpdateNode={handleUpdateNode}
            onDeleteEdge={handleDeleteEdge}
            onClose={() => {
              setSelectedNodeId(null)
              setSelectedEdgeId(null)
            }}
            isReadOnly={isReadOnly}
          />
        </ReactFlowProvider>
      </div>

      {/* ── Unsaved changes dialog ────────────────────────────── */}
      {blocker.state === 'blocked' && (
        <div
          data-testid="unsaved-changes-dialog"
          style={{
            position: 'fixed',
            inset: 0,
            background: 'rgba(0,0,0,0.5)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
          }}
        >
          <div
            style={{
              background: 'var(--color-neutral-0, #fff)',
              borderRadius: 8,
              padding: 24,
              minWidth: 360,
              maxWidth: 440,
              boxShadow: '0 8px 32px rgba(0,0,0,0.15)',
            }}
          >
            <h3
              style={{
                margin: '0 0 8px',
                fontSize: 'var(--text-lg, 1.125rem)',
                fontWeight: 600,
                color: 'var(--text-primary, #212529)',
              }}
            >
              Unsaved Changes
            </h3>
            <p
              style={{
                margin: '0 0 20px',
                fontSize: 'var(--text-sm, 0.875rem)',
                color: 'var(--text-secondary, #6c757d)',
              }}
            >
              You have unsaved changes. Do you want to discard them?
            </p>
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
              <button
                onClick={handleCancelNavigation}
                style={{
                  padding: '6px 16px',
                  border: '1px solid var(--border-default, #e9ecef)',
                  borderRadius: 4,
                  background: '#fff',
                  cursor: 'pointer',
                  fontSize: 'var(--text-sm, 0.875rem)',
                  color: 'var(--text-primary, #212529)',
                }}
              >
                Stay
              </button>
              <button
                data-testid="unsaved-discard"
                onClick={handleDiscardAndProceed}
                style={{
                  padding: '6px 16px',
                  border: 'none',
                  borderRadius: 4,
                  background: 'var(--interactive-danger, #fa5252)',
                  color: '#fff',
                  cursor: 'pointer',
                  fontSize: 'var(--text-sm, 0.875rem)',
                  fontWeight: 500,
                }}
              >
                Discard
              </button>
            </div>
          </div>
        </div>
      )}

      {showPromoteModal && def && (
        <ConfirmPromoteModal
          definitionName={def.name}
          productionDisplayName={productionDisplayName ?? '(unknown)'}
          onConfirm={() => void handlePromoteConfirm()}
          onCancel={() => setShowPromoteModal(false)}
          isLoading={promoting}
        />
      )}
    </div>
  )
}

// ── Helper styles ─────────────────────────────────────────────────────────────

function toolbarButtonStyle(bg?: string): React.CSSProperties {
  return {
    padding: '6px 14px',
    border: `1px solid ${bg ? 'transparent' : 'var(--border-default, #e9ecef)'}`,
    borderRadius: 4,
    background: bg ?? 'transparent',
    color: bg ? '#fff' : 'var(--text-primary, #212529)',
    cursor: 'pointer',
    fontSize: 'var(--text-sm, 0.875rem)',
    fontWeight: 400,
  }
}

const inlineInputStyle: React.CSSProperties = {
  width: '100%',
  padding: '6px 8px',
  border: '1px solid var(--border-default, #e9ecef)',
  borderRadius: 4,
  fontSize: 'var(--text-sm, 0.875rem)',
  boxSizing: 'border-box',
}
