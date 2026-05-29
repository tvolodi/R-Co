import { useState, useCallback, useEffect } from 'react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

interface PropertyPanelProps {
  selectedNodeId: string | null
  selectedNodeData?: CanvasNodeData
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
  selectedNodeData,
  selectedEdgeId,
  onUpdateNode,
  onDeleteEdge,
  onClose,
  isReadOnly,
  nodeNames,
}: PropertyPanelProps) {
  const [localName, setLocalName] = useState('')

  // Sync localName when selected node changes
  useEffect(() => {
    setLocalName(selectedNodeData?.name ?? '')
  }, [selectedNodeId, selectedNodeData?.name])

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
    <div data-testid="property-panel" style={panelStyle}>
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
            nodeData={selectedNodeData}
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
  nodeData?: CanvasNodeData
  localName: string
  onNameChange: (name: string) => void
  onUpdate: (nodeId: string, data: Partial<CanvasNodeData>) => void
  isReadOnly: boolean
}

function NodePropertyContent({
  nodeId,
  nodeData,
  localName,
  onNameChange,
  onUpdate,
  isReadOnly,
}: NodePropertyContentProps) {
  const nodeType = nodeData?.nodeType

  function renderTypeSpecificFields() {
    switch (nodeType) {
      case 'HUMAN_TASK':
        return (
          <>
            <Field label="Assignee Type">
              <select
                data-testid="prop-assignee-type"
                disabled={isReadOnly}
                style={inputStyle(isReadOnly)}
              >
                <option value="user">User</option>
                <option value="group">Group</option>
                <option value="role">Role</option>
                <option value="unassigned">Unassigned</option>
              </select>
            </Field>
            <Field label="Assignee Ref">
              <input
                data-testid="prop-assignee-ref"
                disabled={isReadOnly}
                placeholder="Assignee reference"
                style={inputStyle(isReadOnly)}
              />
            </Field>
            <Field label="Form Schema">
              <textarea
                data-testid="prop-form-schema"
                disabled={isReadOnly}
                placeholder="JSON Schema"
                rows={4}
                style={inputStyle(isReadOnly)}
              />
            </Field>
          </>
        )
      case 'SERVICE_TASK':
        return (
          <>
            <Field label="Service Type">
              <input
                data-testid="prop-service-type"
                disabled={isReadOnly}
                placeholder="e.g. http, lambda"
                style={inputStyle(isReadOnly)}
              />
            </Field>
            <Field label="Service Config">
              <input
                data-testid="prop-service-config"
                disabled={isReadOnly}
                placeholder="JSON config"
                style={inputStyle(isReadOnly)}
              />
            </Field>
          </>
        )
      case 'TIMER':
        return (
          <>
            <Field label="Timer Type">
              <select
                data-testid="prop-timer-type"
                disabled={isReadOnly}
                style={inputStyle(isReadOnly)}
              >
                <option value="duration">Duration</option>
                <option value="cron">Cron</option>
                <option value="date">Date</option>
              </select>
            </Field>
            <Field label="Timer Duration">
              <input
                data-testid="prop-timer-duration"
                disabled={isReadOnly}
                placeholder="e.g. PT1H"
                style={inputStyle(isReadOnly)}
              />
            </Field>
          </>
        )
      default:
        // START, END, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY, SUB_PROCESS — no type-specific fields
        return null
    }
  }

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
          Node: {nodeId} ({nodeType ?? 'unknown'})
        </span>
      </div>

      <Field label="Name">
        <input
          data-testid="prop-name-input"
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

      {renderTypeSpecificFields()}

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
            data-testid="edge-delete-btn"
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
