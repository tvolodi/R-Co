interface EventJsonExpandableProps {
  payload: Record<string, unknown>
}

export function EventJsonExpandable({ payload }: EventJsonExpandableProps) {
  return (
    <details>
      <summary style={{ cursor: 'pointer', color: '#334155', fontSize: '.8rem' }}>
        Payload
      </summary>
      <pre
        style={{
          marginTop: '.4rem',
          background: '#f8fafc',
          border: '1px solid #e2e8f0',
          borderRadius: '4px',
          padding: '.65rem',
          fontSize: '.75rem',
          overflow: 'auto',
          maxHeight: '400px',
        }}
      >
        {JSON.stringify(payload, null, 2)}
      </pre>
    </details>
  )
}
