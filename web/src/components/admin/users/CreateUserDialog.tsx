import type { CSSProperties, ReactNode } from 'react'
import type { Role } from '@/types/api'

type CreateUserPayload = {
  username: string
  display_name: string
  email: string
  password: string
  role_ids: string[]
}

type Props = {
  open: boolean
  roles: Role[]
  isSubmitting: boolean
  submitError?: string | null
  onCancel: () => void
  onSubmit: (payload: CreateUserPayload) => void
}

export function CreateUserDialog({ open, roles, isSubmitting, submitError, onCancel, onSubmit }: Props) {
  if (!open) return null

  return (
    <div style={overlayStyle} role="dialog" aria-modal="true" aria-label="Create user">
      <div style={dialogStyle}>
        <h3 style={{ marginTop: 0 }}>Create user</h3>
        <CreateUserForm
          roles={roles}
          isSubmitting={isSubmitting}
          submitError={submitError}
          onCancel={onCancel}
          onSubmit={onSubmit}
        />
      </div>
    </div>
  )
}

function CreateUserForm({ roles, isSubmitting, submitError, onCancel, onSubmit }: Omit<Props, 'open'>) {
  const formId = 'create-user-form'

  return (
    <form
      id={formId}
      onSubmit={(event) => {
        event.preventDefault()
        const formData = new FormData(event.currentTarget)
        const roleIds = formData.getAll('role_ids').map(String)
        onSubmit({
          username: String(formData.get('username') ?? '').trim(),
          display_name: String(formData.get('display_name') ?? '').trim(),
          email: String(formData.get('email') ?? '').trim(),
          password: String(formData.get('password') ?? '').trim(),
          role_ids: roleIds,
        })
      }}
    >
      <Field label="Username">
        <input name="username" required />
      </Field>
      <Field label="Display name">
        <input name="display_name" required />
      </Field>
      <Field label="Email">
        <input name="email" type="email" required />
      </Field>
      <Field label="Password">
        <input name="password" type="password" required />
      </Field>
      <Field label="Initial roles">
        <div style={{ maxHeight: 120, overflowY: 'auto', border: '1px solid #d1d5db', borderRadius: 4, padding: 8 }}>
          {roles.map((role) => (
            <label key={role.id} style={{ display: 'block', marginBottom: 6 }}>
              <input type="checkbox" name="role_ids" value={role.id} /> {role.name}
            </label>
          ))}
        </div>
      </Field>
      {submitError && <p role="alert" style={{ color: '#b91c1c' }}>{submitError}</p>}
      <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
        <button type="button" onClick={onCancel}>Cancel</button>
        <button type="submit" form={formId} disabled={isSubmitting}>{isSubmitting ? 'Creating...' : 'Create user'}</button>
      </div>
    </form>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label style={{ display: 'block', marginBottom: 10 }}>
      <span style={{ display: 'block', marginBottom: 4, fontWeight: 600, fontSize: 14 }}>{label}</span>
      {children}
    </label>
  )
}

const overlayStyle: CSSProperties = {
  position: 'fixed',
  inset: 0,
  backgroundColor: 'rgba(15, 23, 42, 0.45)',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  zIndex: 30,
}

const dialogStyle: CSSProperties = {
  backgroundColor: '#fff',
  width: 'min(560px, calc(100vw - 2rem))',
  borderRadius: 8,
  padding: 20,
}
