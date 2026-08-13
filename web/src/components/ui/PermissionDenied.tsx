import React from 'react'
import { Link } from 'react-router-dom'

export function PermissionDenied(): React.ReactElement {
  return (
    <div style={{ padding: '1.5rem' }}>
      <p style={{ marginBottom: '.75rem' }}>
        You do not have access to this area. Contact your tenant administrator.
      </p>
      <Link to="/tasks">My Tasks</Link>
    </div>
  )
}
