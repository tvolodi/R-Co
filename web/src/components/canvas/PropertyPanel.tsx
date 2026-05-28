import { useState, useCallback, useEffect } from 'react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

interface PropertyPanelProps {
  selectedNodeId: string | null
  selectedEdgeId: string | null
  onUpdateNode: (nodeId: string, data: Partial<CanvasNodeData>) => void
  onDeleteEdge: (edgeId: string) => void
  onClose: () => void
  isReadOnly: boolean
  /** Map of node id -> node name for displaying source/target labels */
  nodeNames: Map<string, string>
}

export default function PropertyPanel({
  selectedNodeId,
  selectedEdgeId,
  onUpdateNode,
  onDeleteEdge,
  onClose,
  isReadOnly,
  nodeNames,
}: PropertyPanelProps) {
  const [localName, setLocalName] = useState('')

  const handleKeyDown = useCallback(
    (e: globalThis.KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    },
    [onClose],
  )

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [handleKeyDown])

  if (!selectedNodeId && !selectedEdgeId) return null

  const panelStyle: React.CSSProperties = {
    width: 400,
    minWidth: 400,
    background: 'var(--surface-card, #fff)',
    borderLeft: '1px solid var(--border-default, #e9ecef)',
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden',
    height: '100%',
  }

  return (
    <div style={panelStyle}>
      {/* Header */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '12px 16px',
          borderBottom: '1px solid var(--border-default, #e9ecef)',
        }}
      >
        <span style={{ fontSize: 'var(--text-sm, 0.875rem)', fontWeight: 600, color: 'var(--text-primary, #212529)' }}>
          Properties
        </span>
        <button
          onClick={onClose}
          style={{
            border: 'none',
            background: 'none',
            cursor: 'pointer',
            padding: 4,
            fontSize: 18,
            lineHeight: 1,
            color: 'var(--text-secondary, #6c757d)',
          }}
          aria-label="Close panel"
        >
          ✕
        </button>
      </div>

      {/* Content */}
      <div style={{ flex: 1, overflowY: 'auto', padding: 16 }}>
        {selectedEdgeId && (
          <EdgePropertyContent
            edgeId={selectedEdgeId}
            nodeNames={nodeNames}
            onDelete={onDeleteEdge}
            isReadOnly={isReadOnly}
          />
        )}
        {selectedNodeId && (
          <NodePropertyContent
            nodeId={selectedNodeId}
            localName={localName}
            onNameChange={setLocalName}
            onUpdate={onUpdateNode}
            isReadOnly={isReadOnly}
          />
        )}
      </div>
    </div>
  )
}

// ── Node property content ─────────────────────────────────────────────────────

interface NodePropertyContentProps {
  nodeId: string
  localName: string
  onNameChange: (name: string) => void
  onUpdate: (nodeId: string, data: Partial<CanvasNodeData>) => void
  isReadOnly: boolean
}

function NodePropertyContent({
  nodeId,
  localName,
  onNameChange,
  onUpdate,
  isReadOnly,
}: NodePropertyContentProps) {

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* Node ID indicator */}
      <div>
        <span
          style={{
            fontSize: 'var(--text-xs, 0.75rem)',
            color: 'var(--text-secondary, #6c757d)',
            textTransform: 'uppercase',
            letterSpacing: '0.5px',
          }}
        >
          Node: {nodeId}
        </span>
      </div>

      <Field label="Name">
        <input
          value={localName}
          onChange={(e) => {
            onNameChange(e.target.value)
            onUpdate(nodeId, { name: e.target.value })
          }}
          disabled={isReadOnly}
          placeholder="Node name"
          style={inputStyle(isReadOnly)}
        />
      </Field>

      <p style={{ fontSize: 'var(--text-sm, 0.875rem)', color: 'var(--text-secondary, #6c757d)' }}>
        Select a node on the canvas to edit its properties. Changes are saved locally until you click Save.
      </p>
    </div>
  )
}

// ── Edge property content ─────────────────────────────────────────────────────

interface EdgePropertyContentProps {
  edgeId: string
  nodeNames: Map<string, string>
  onDelete: (edgeId: string) => void
  isReadOnly: boolean
}

function EdgePropertyContent({
  edgeId,
  nodeNames,
  onDelete,
  isReadOnly,
}: EdgePropertyContentProps) {
  // Edge data is in ProcessCanvas; we can only show IDs and names here
  const parts = edgeId.replace('rf-edge-', '').split('-')
  const sourceId = parts[0] ?? ''
  const targetId = parts.slice(1).join('-')
  const sourceName = nodeNames.get(sourceId) ?? sourceId
  const targetName = nodeNames.get(targetId) ?? targetId

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <Field label="Connection">
        <div style={{ fontSize: 'var(--text-sm, 0.875rem)', color: 'var(--text-primary, #212529)' }}>
          {sourceName} → {targetName}
        </div>
      </Field>

      <p style={{ fontSize: 'var(--text-sm, 0.875rem)', color: 'var(--text-secondary, #6c757d)' }}>
        Select an edge on the canvas and use the Delete/Backspace key to remove it.
      </p>

      {!isReadOnly && (
        <div style={{ marginTop: 8 }}>
          <button
            onClick={() => {
              if (window.confirm('Delete this edge?')) onDelete(edgeId)
            }}
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
            Delete Edge
          </button>
        </div>
      )}
    </div>
  )
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <label
        style={{
          display: 'block',
          fontSize: 'var(--text-sm, 0.875rem)',
          fontWeight: 500,
          marginBottom: 4,
          color: 'var(--text-primary, #212529)',
        }}
      >
        {label}
      </label>
      {children}
    </div>
  )
}

function inputStyle(isReadOnly: boolean): React.CSSProperties {
  return {
    width: '100%',
    padding: '6px 8px',
    border: '1px solid var(--border-default, #e9ecef)',
    borderRadius: 4,
    fontSize: 'var(--text-sm, 0.875rem)',
    boxSizing: 'border-box',
    background: isReadOnly ? 'var(--color-neutral-50, #f8f9fa)' : '#fff',
    cursor: isReadOnly ? 'not-allowed' : undefined,
    color: isReadOnly ? 'var(--text-secondary, #6c757d)' : undefined,
  }
}
