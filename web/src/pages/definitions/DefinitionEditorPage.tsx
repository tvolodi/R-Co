/**
 * DefinitionEditorPage — Visual Process Designer Canvas
 *
 * Integrates ReactFlow canvas, node palette, property panel, validation bar,
 * and save workflow. Replaces the old JSON textarea as the primary editor.
 */

import { useParams, useBlocker } from 'react-router-dom'
import { useState, useRef, useMemo, useCallback, useEffect } from 'react'
import { ReactFlowProvider } from '@xyflow/react'
import type { Node, Edge } from '@xyflow/react'

import { useDefinition, useCreateDefinition } from '@/hooks/useDefinitions'
import { definitionsApi } from '@/api/definitions'
import type { DefinitionGraph } from '@/types/api'
import type { CanvasNodeData, CanvasEdgeData } from '@/utils/canvas/graphToFlow'
import { graphToFlow } from '@/utils/canvas/graphToFlow'
import { flowToGraph } from '@/utils/canvas/flowToGraph'

import ProcessCanvas from '@/components/canvas/ProcessCanvas'
import NodePalette from '@/components/canvas/NodePalette'
import PropertyPanel from '@/components/canvas/PropertyPanel'
import ValidationSummaryBar from '@/components/canvas/ValidationSummaryBar'
import type { ValidationError } from '@/components/canvas/ValidationSummaryBar'

// ── Empty starter graph ───────────────────────────────────────────────────────

const EMPTY_GRAPH: DefinitionGraph = {
  nodes: [
    { id: 'start', type: 'START' },
    { id: 'end', type: 'END' },
  ],
  edges: [{ id: 'e1', source: 'start', target: 'end' }],
}

// ── Page component ────────────────────────────────────────────────────────────

export default function DefinitionEditorPage() {
  const { id } = useParams<{ id?: string }>()
  const isNew = !id
  const { data: def, isLoading } = useDefinition(id!)
  const create = useCreateDefinition()

  const [name, setName] = useState('')
  const [version, setVersion] = useState('1.0.0')
  const [description, setDescription] = useState('')
  const [saved, setSaved] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [showRawJson, setShowRawJson] = useState(false)

  // ── Canvas state ────────────────────────────────────────────────────────────

  const [dirty, setDirty] = useState(false)
  const validationErrors: ValidationError[] = []
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [selectedEdgeId, setSelectedEdgeId] = useState<string | null>(null)

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
      map.set(gn.id, gn.name || gn.type)
    }
    return map
  }, [currentGraph])

  // ── Save handler ────────────────────────────────────────────────────────────

  async function handleSave() {
    setError(null)

    if (validationErrors.some((e) => e.severity === 'error')) {
      setError('Fix validation errors before saving.')
      return
    }

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
        await definitionsApi.update(id!, { graph })
      }

      setDirty(false)
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
    } catch (e) {
      setError(e instanceof SyntaxError ? 'Invalid graph data' : (e as Error).message)
    }
  }

  // ── Unsaved changes guard ───────────────────────────────────────────────────

  useBlocker(
    ({ currentLocation, nextLocation }) =>
      dirty && currentLocation.pathname !== nextLocation.pathname,
  )

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

  // ── Property panel callbacks ────────────────────────────────────────────────

  const handleUpdateNode = useCallback(
    (_nodeId: string, _data: Partial<CanvasNodeData>) => { setDirty(true); void _nodeId; void _data; },
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
          {!isReadOnly && (
            <>
              <button
                onClick={() => setShowRawJson(!showRawJson)}
                style={toolbarButtonStyle(showRawJson ? 'var(--color-neutral-200, #e9ecef)' : undefined)}
              >
                {showRawJson ? 'Hide Raw JSON' : 'Show Raw JSON'}
              </button>
              <button
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
              style={{
                fontSize: 'var(--text-sm, 0.875rem)',
                color: 'var(--color-warning-dark, #e67700)',
                background: 'var(--color-warning-light, #fff3bf)',
                padding: '4px 12px',
                borderRadius: 4,
              }}
            >
              Read-only — {def?.status?.toLowerCase() ?? 'unknown'} status
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

      {saved && (
        <div
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
          <NodePalette isReadOnly={isReadOnly} />

          <div style={{ flex: 1, position: 'relative', display: 'flex', flexDirection: 'column' }}>
            <ProcessCanvas
              definitionId={id ?? ''}
              initialNodes={initialNodes}
              initialEdges={initialEdges}
              isReadOnly={isReadOnly}
              onDirtyChange={setDirty}
              canvasStateRef={canvasStateRef}
              onSelectedNodeChange={setSelectedNodeId}
              onSelectedEdgeChange={setSelectedEdgeId}
            />

            {/* Raw JSON drawer */}
            {showRawJson && (
              <div
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
