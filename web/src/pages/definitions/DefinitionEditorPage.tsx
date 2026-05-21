/** Definition editor — visual canvas stub (React Flow) + JSON editor fallback */

import { useParams } from 'react-router-dom'
import { useState } from 'react'
import { useDefinition, useCreateDefinition } from '@/hooks/useDefinitions'
import { definitionsApi } from '@/api/definitions'
import type { DefinitionGraph } from '@/types/api'

const EMPTY_GRAPH: DefinitionGraph = {
  nodes: [
    { id: 'start', type: 'START' },
    { id: 'end', type: 'END' },
  ],
  edges: [{ id: 'e1', source: 'start', target: 'end' }],
}

export default function DefinitionEditorPage() {
  const { id } = useParams<{ id?: string }>()
  const isNew = !id
  const { data: def, isLoading } = useDefinition(id!)
  const create = useCreateDefinition()

  const [name, setName] = useState('')
  const [version, setVersion] = useState('1.0.0')
  const [description, setDescription] = useState('')
  const [graphJson, setGraphJson] = useState(JSON.stringify(EMPTY_GRAPH, null, 2))
  const [saved, setSaved] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!isNew && isLoading) return <p style={{ padding: '1.5rem' }}>Loading…</p>

  const currentGraph = def?.graph ?? EMPTY_GRAPH

  async function handleSave() {
    setError(null)
    try {
      const graph: DefinitionGraph = JSON.parse(graphJson) as DefinitionGraph
      if (isNew) {
        await create.mutateAsync({ name, version, description, graph })
      } else {
        await definitionsApi.update(id!, { graph })
      }
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
    } catch (e) {
      setError(e instanceof SyntaxError ? 'Invalid JSON in graph' : (e as Error).message)
    }
  }

  return (
    <div style={{ padding: '1.5rem', maxWidth: '900px' }}>
      <h2 style={{ marginBottom: '1.25rem' }}>{isNew ? 'New Definition' : `Edit: ${def?.name}`}</h2>

      {error && <p style={{ color: '#dc2626', marginBottom: '1rem' }}>{error}</p>}
      {saved && <p style={{ color: '#16a34a', marginBottom: '1rem' }}>Saved.</p>}

      {isNew && (
        <>
          <div style={{ marginBottom: '1rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Name</label>
            <input value={name} onChange={(e) => setName(e.target.value)}
              style={{ width: '100%', padding: '.5rem .75rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '1rem', boxSizing: 'border-box' }} />
          </div>
          <div style={{ display: 'flex', gap: '1rem', marginBottom: '1rem' }}>
            <div style={{ flex: 1 }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Version</label>
              <input value={version} onChange={(e) => setVersion(e.target.value)}
                style={{ width: '100%', padding: '.5rem .75rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '1rem', boxSizing: 'border-box' }} />
            </div>
          </div>
          <div style={{ marginBottom: '1rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Description</label>
            <textarea value={description} onChange={(e) => setDescription(e.target.value)}
              rows={2}
              style={{ width: '100%', padding: '.5rem .75rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '1rem', boxSizing: 'border-box', resize: 'vertical' }} />
          </div>
        </>
      )}

      <div style={{ marginBottom: '1rem' }}>
        <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>
          Graph JSON {!isNew && <span style={{ color: '#64748b', fontWeight: 400 }}>(nodes + edges)</span>}
        </label>
        <textarea
          value={isNew ? graphJson : JSON.stringify(currentGraph, null, 2)}
          onChange={(e) => setGraphJson(e.target.value)}
          rows={20}
          spellCheck={false}
          style={{ width: '100%', padding: '.75rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontFamily: 'monospace', fontSize: '.85rem', boxSizing: 'border-box', resize: 'vertical' }}
        />
        <p style={{ fontSize: '.8rem', color: '#64748b', marginTop: '.25rem' }}>
          Visual canvas (React Flow) will replace this editor in a future iteration.
        </p>
      </div>

      <button
        onClick={handleSave}
        disabled={create.isPending}
        style={{ padding: '.5rem 1.25rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.9rem' }}
      >
        {create.isPending ? 'Saving…' : 'Save'}
      </button>
    </div>
  )
}
