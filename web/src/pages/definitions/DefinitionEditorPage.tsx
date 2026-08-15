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
import { validateSubProcessInterface } from '@/utils/canvas/interfaceValidation'
import { useCanvasHistoryStore } from '@/stores/canvasHistoryStore'
import { ConfirmPromoteModal } from '@/components/ui/ConfirmPromoteModal'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { useDefinitionDraftStore } from '@/stores/definitionDraftStore'
import { DraftBanner } from '@/components/definitions/DraftBanner'
import type { ApiError } from '@/types/api'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'

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

/**
 * SPC-02 — collect client-side SUB_PROCESS interface validation issues per
 * node. Returns a map of node id -> combined human-readable message for every
 * SUB_PROCESS node whose `interface` attribute fails the structural contract
 * (shape, entry shape, JSON Schema well-formedness, duplicate names). Nodes
 * without an `interface` are skipped (EXT-05 no-contract path is valid).
 */
function collectSubProcessInterfaceErrors(nodes: Node<CanvasNodeData>[]): Map<string, string> {
  const byNode = new Map<string, string>()
  for (const node of nodes) {
    if (node.data.nodeType !== 'SUB_PROCESS') continue
    const issues = validateSubProcessInterface(node.data.attributes?.interface)
    if (issues.length > 0) {
      byNode.set(node.id, issues.map((i) => i.message).join('; '))
    }
  }
  return byNode
}

// ── Page component ────────────────────────────────────────────────────────────

export default function DefinitionEditorPage() {
  const { id } = useParams<{ id?: string }>()
  const isNew = !id
  const { data: def, isLoading, isError, error: defError, refetch } = useDefinition(id!)
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

  // ── RND-UI-06: 409 conflict + draft retention state ─────────────────────────
  const [saveConflict, setSaveConflict] = useState<ApiError | null>(null)
  const draftStore = useDefinitionDraftStore()
  const currentDraft = !isNew && id ? draftStore.draft : null

  // Mirror the editor's current draft body into the Zustand store whenever
  // the canvas state mutates. The editor never reads XRV directly; it only
  // reads the draft (per §2.4 binding rule 1).
  useEffect(() => {
    if (isNew || !id) return
    const state = canvasStateRef.current
    if (!state) return
    try {
      const nodes: Node<CanvasNodeData>[] = JSON.parse(state.nodesJSON)
      const edges: Edge<CanvasEdgeData>[] = JSON.parse(state.edgesJSON)
      const graph = flowToGraph(nodes, edges)
      const dirtyKeys: string[] = []
      if (description !== (def?.description ?? '')) dirtyKeys.push('description')
      if (graph && def?.graph && JSON.stringify(graph) !== JSON.stringify(def.graph)) {
        dirtyKeys.push('graph')
      }
      if (dirtyKeys.length === 0) return
      draftStore.setDraft({
        definitionId: id,
        body: { name: def?.name ?? '', version: def?.version ?? '', description, graph },
        dirtyFieldKeys: dirtyKeys,
        savedAt: draftStore.draft?.savedAt ?? null,
      })
    } catch {
      /* graph parsing failure: don't write a partial draft */
    }
  }, [description, isNew, id, def?.description, def?.name, def?.version, def?.graph, draftStore])

  const handleSaveMerged = async (
    mergedBody: Record<string, unknown>,
    version: string,
  ): Promise<void> => {
    // PD-08: send the version stamp as a body field (backend convention TBD
    // — see design §2.3 OQ-3). For the PATCH path we pass it via the If-Match
    // header equivalent — the backend's PATCH currently consumes the
    // `version` field on the body for optimistic concurrency, falling back
    // to the header on a future release.
    void version
    if (!id) return
    try {
      await definitionsApi.update(id, {
        name: (mergedBody['name'] as string | undefined) ?? def?.name ?? '',
        version: (mergedBody['version'] as string | undefined) ?? def?.version ?? '',
        description: (mergedBody['description'] as string | undefined) ?? def?.description ?? undefined,
        graph: (mergedBody['graph'] as DefinitionGraph | undefined) ?? def?.graph,
        stage: null,
      } as Partial<Parameters<typeof definitionsApi.update>[1]> & { version?: string })
      draftStore.setDraft({
        definitionId: id,
        body: mergedBody,
        dirtyFieldKeys: [],
        savedAt: new Date().toISOString(),
      })
      setSaveConflict(null)
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
      void refetch()
    } catch (e: unknown) {
      setError((e as { message?: string }).message ?? 'Merge save failed')
    }
  }

  const handleDiscardConfirmed = (): void => {
    if (id) draftStore.clearDraft(id)
    setSaveConflict(null)
    void refetch()
  }

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

      // SPC-02 / PD-UI-14 — block save until every SUB_PROCESS `interface`
      // contract is clean. Re-read from the live canvas state (not the
      // possibly-stale validationErrors render value) so an in-flight edit
      // cannot slip through to the backend's HTTP 422.
      const ifaceErrors = collectSubProcessInterfaceErrors(nodes)
      if (ifaceErrors.size > 0) {
        const first = [...ifaceErrors.entries()][0]
        setError(`Fix validation errors before saving: SUB_PROCESS "${first[0]}" interface — ${first[1]}`)
        return
      }

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
      if (err.status === 409) {
        // RND-UI-06: surface ConflictResolver via QueryStateBoundary.
        setSaveConflict(err as ApiError)
        return
      }
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

      // SPC-02 — client-side SUB_PROCESS interface contract validation
      // (mirrors the backend 422 rule). Issues are error-severity: they surface
      // in the validation summary bar (PD-UI-13) and block save (PD-UI-14).
      const interfaceErrors = collectSubProcessInterfaceErrors(nodes)
      for (const [nodeId, message] of interfaceErrors) {
        errors.push({
          nodeId,
          message: `SUB_PROCESS "${nodeId}" interface: ${message}`,
          severity: 'error',
        })
      }

      // Surface interface issues inline on the offending nodes (PD-UI-13) via
      // the dedicated validation trigger. Only dispatch when the computed
      // error differs from the node's current `validationError`, so the update
      // loop converges instead of re-dispatching forever.
      const validationUpdates: Record<string, string | null> = {}
      for (const node of nodes) {
        if (node.data.nodeType !== 'SUB_PROCESS') continue
        const target = interfaceErrors.get(node.id) ?? null
        const current = (node.data.validationError as string | undefined) ?? null
        if (target !== current) validationUpdates[node.id] = target
      }
      if (Object.keys(validationUpdates).length > 0) {
        dispatchNodeValidation(validationUpdates)
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

  // ── Node validation-error trigger (SPC-02 SUB_PROCESS interface) ─────────
  // Separate from nodeUpdateTrigger so inline validation annotations never
  // pollute the undo snapshot stack (they are derived, not user actions).

  const [nodeValidationTrigger, setNodeValidationTrigger] = useState<{
    updates: Record<string, string | null>
    counter: number
  } | null>(null)
  const nodeValidationCounterRef = useRef(0)

  const dispatchNodeValidation = useCallback((updates: Record<string, string | null>) => {
    nodeValidationCounterRef.current += 1
    setNodeValidationTrigger({ updates, counter: nodeValidationCounterRef.current })
  }, [])

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

  // ── Loading state via QueryStateBoundary — no early return needed ───────────
  const rendererState: RendererState = saveConflict
    ? 'stale-version'
    : (!isNew && isLoading)
      ? 'loading'
      : (!isNew && isError)
        ? classifyError(defError)
        : 'success'

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
      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(defError) : undefined
        }
        staleVersionError={saveConflict ?? undefined}
        staleVersionServerPayload={
          saveConflict ? ((saveConflict.details as Record<string, unknown>) ?? {}) : undefined
        }
        staleVersionLocalDraft={currentDraft?.body}
        staleVersionOnSaveMerged={handleSaveMerged}
        staleVersionOnDiscardConfirmed={handleDiscardConfirmed}
        columns={[{ widthPercent: 100 }]}
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
                disabled={create.isPending || validationErrors.some((e) => e.severity === 'error')}
                title={
                  validationErrors.some((e) => e.severity === 'error')
                    ? 'Fix validation errors before saving.'
                    : undefined
                }
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
      {currentDraft && !saveConflict && (
        <DraftBanner
          draft={currentDraft}
          onApply={() => {
            // Re-apply the draft body into the editor fields. The canvas
            // body is read-only here — the user can re-edit then Save.
            if (currentDraft.body['description']) {
              setDescription(String(currentDraft.body['description']))
            }
          }}
          onDiscard={() => {
            if (id) draftStore.clearDraft(id)
          }}
        />
      )}

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
              nodeValidationTrigger={nodeValidationTrigger}
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
      </QueryStateBoundary>
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
