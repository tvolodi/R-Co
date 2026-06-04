/** RegisterTenantPage — ONB-UI-02
 *
 * Collects onboarding inputs for a new tenant and submits to POST /api/v1/onboarding.
 * Role guard: redirects to /instances if session does not include PLATFORM_ADMIN.
 * On success navigates to OnboardingProgressPage with form values in router state.
 */

import { useState, useEffect } from 'react'
import { Navigate, useNavigate, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import {
  submitOnboarding,
  OnboardingApiError,
  type OnboardingFormValues,
} from '@/api/onboarding'

// ── Types ──────────────────────────────────────────────────────────────────────

interface FormState {
  slug: string
  display_name: string
  admin_email: string
  admin_username: string
  admin_display_name: string
  hostname: string
  redirect_uris: string[]
  realm_default_token_lifetime_seconds: string
  realm_min_password_length: string
  realm_require_uppercase: boolean
  realm_require_digit: boolean
  realm_signing_key_algorithm: string
  client_service_account_enabled: boolean
}

interface FormErrors {
  slug?: string
  display_name?: string
  admin_email?: string
  admin_username?: string
  admin_display_name?: string
  hostname?: string
  redirect_uris?: string
}

const EMPTY_FORM: FormState = {
  slug: '',
  display_name: '',
  admin_email: '',
  admin_username: '',
  admin_display_name: '',
  hostname: '',
  redirect_uris: [''],
  realm_default_token_lifetime_seconds: '',
  realm_min_password_length: '',
  realm_require_uppercase: false,
  realm_require_digit: false,
  realm_signing_key_algorithm: '',
  client_service_account_enabled: false,
}

// ── Validation ─────────────────────────────────────────────────────────────────

function validateForm(form: FormState): FormErrors {
  const errors: FormErrors = {}

  if (!form.slug.trim()) {
    errors.slug = 'Slug is required'
  } else if (form.slug.length < 3 || form.slug.length > 63) {
    errors.slug = 'Slug must be 3–63 characters'
  } else if (!/^[a-z0-9-]+$/.test(form.slug)) {
    errors.slug = 'Slug may only contain lowercase letters, digits, and hyphens'
  }

  if (!form.display_name.trim()) {
    errors.display_name = 'Display name is required'
  }

  if (!form.admin_email.trim()) {
    errors.admin_email = 'Admin email is required'
  } else if (!form.admin_email.includes('@') || form.admin_email.split('@')[1]?.length === 0) {
    errors.admin_email = 'Enter a valid email address'
  }

  if (!form.admin_username.trim()) {
    errors.admin_username = 'Admin username is required'
  }

  if (!form.admin_display_name.trim()) {
    errors.admin_display_name = 'Admin display name is required'
  }

  if (!form.hostname.trim()) {
    errors.hostname = 'Hostname is required'
  } else if (/^https?:\/\//i.test(form.hostname) || form.hostname.includes('/')) {
    errors.hostname = 'Enter a hostname only (no protocol or path)'
  }

  const nonEmptyUris = form.redirect_uris.filter((u) => u.trim().length > 0)
  if (nonEmptyUris.length === 0) {
    errors.redirect_uris = 'At least one redirect URI is required'
  }

  return errors
}

// ── Error taxonomy banner message ──────────────────────────────────────────────

function resolveApiErrorMessage(
  err: OnboardingApiError,
): { banner: string; progressLink?: string } {
  const { httpStatus, body } = err
  const errorCode = body['error'] as string | undefined
  const problemType = body['type'] as string | undefined

  if (httpStatus === 409) {
    if (errorCode === 'onboarding_in_progress') {
      const oid = body['onboarding_id'] as string | undefined
      return {
        banner: 'An onboarding for this tenant is already in progress.',
        progressLink: oid ? `/admin/onboarding/${oid}/progress` : undefined,
      }
    }
    if (problemType?.includes('idempotency-conflict')) {
      return { banner: 'A conflicting submission was detected. Please start over.' }
    }
    // Other 409 (DuplicateTenantSlug, DuplicateHostname, RealmAlreadyExists etc.)
    const title = (body['title'] as string) ?? (body['detail'] as string)
    return { banner: title ?? 'A conflict was detected. Please check your inputs.' }
  }

  if (httpStatus === 422) {
    if (errorCode === 'idempotency_key_required') {
      return { banner: 'Internal error: idempotency key missing. Please reload and try again.' }
    }
    return { banner: 'The server rejected the submission due to a validation error. Please check all fields.' }
  }

  if (httpStatus === 502) {
    return { banner: 'Tenant provisioning failed at the identity provider. Check Keycloak connectivity and try again.' }
  }

  if (httpStatus === 503) {
    return { banner: 'The onboarding service is temporarily unavailable. Please try again in a moment.' }
  }

  return { banner: 'An unexpected error occurred. Please try again.' }
}

// ── Shared input style ─────────────────────────────────────────────────────────

const inputStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  padding: '.45rem .65rem',
  border: '1px solid #cbd5e1',
  borderRadius: '4px',
  fontSize: '.9rem',
  boxSizing: 'border-box',
}

const errorStyle: React.CSSProperties = {
  color: '#dc2626',
  fontSize: '.8rem',
  marginTop: '.2rem',
}

const labelStyle: React.CSSProperties = {
  display: 'block',
  marginBottom: '.3rem',
  fontWeight: 600,
  fontSize: '.87rem',
  color: '#374151',
}

const fieldGroupStyle: React.CSSProperties = {
  marginBottom: '1rem',
}

// ── Helpers ────────────────────────────────────────────────────────────────────

function buildRealmConfig(form: FormState) {
  const cfg: Record<string, unknown> = {}
  if (form.realm_default_token_lifetime_seconds.trim()) {
    const v = parseInt(form.realm_default_token_lifetime_seconds, 10)
    if (!isNaN(v)) cfg['default_token_lifetime_seconds'] = v
  }
  if (form.realm_min_password_length.trim()) {
    const v = parseInt(form.realm_min_password_length, 10)
    if (!isNaN(v)) cfg['min_password_length'] = v
  }
  if (form.realm_require_uppercase) cfg['require_uppercase'] = true
  if (form.realm_require_digit) cfg['require_digit'] = true
  if (form.realm_signing_key_algorithm.trim()) {
    cfg['signing_key_algorithm'] = form.realm_signing_key_algorithm.trim()
  }
  return Object.keys(cfg).length > 0 ? cfg : undefined
}

function buildClientConfig(form: FormState) {
  if (form.client_service_account_enabled) {
    return { service_account_enabled: true }
  }
  return undefined
}

// ── Component ──────────────────────────────────────────────────────────────────

export default function RegisterTenantPage() {
  const { session } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()

  const prefill = (location.state as { prefill?: Partial<FormState> } | null)?.prefill

  // All hooks must be called before any early return
  const [form, setForm] = useState<FormState>(() =>
    prefill
      ? { ...EMPTY_FORM, ...prefill, redirect_uris: (prefill.redirect_uris as string[] | undefined) ?? [''] }
      : { ...EMPTY_FORM },
  )
  const [errors, setErrors] = useState<FormErrors>({})
  const [idempotencyKey] = useState<string>(() => crypto.randomUUID())
  const [submitting, setSubmitting] = useState(false)
  const [apiError, setApiError] = useState<{ banner: string; progressLink?: string } | null>(null)
  const [realmOpen, setRealmOpen] = useState(false)
  const [clientOpen, setClientOpen] = useState(false)

  // Clear API error when form changes
  useEffect(() => {
    setApiError(null)
  }, [form])

  // Role guard — after all hooks
  if (!session?.roles.includes('PLATFORM_ADMIN')) {
    return <Navigate to="/instances" replace />
  }

  function setField<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((prev) => ({ ...prev, [key]: value }))
    const draft = { ...form, [key]: value }
    const fieldErrors = validateForm(draft)
    setErrors((prev) => ({
      ...prev,
      [key]: fieldErrors[key as keyof FormErrors],
    }))
  }

  function setRedirectUri(index: number, value: string) {
    const updated = [...form.redirect_uris]
    updated[index] = value
    setForm((prev) => ({ ...prev, redirect_uris: updated }))
    const draft = { ...form, redirect_uris: updated }
    const fieldErrors = validateForm(draft)
    setErrors((prev) => ({ ...prev, redirect_uris: fieldErrors.redirect_uris }))
  }

  function addRedirectUri() {
    setForm((prev) => ({ ...prev, redirect_uris: [...prev.redirect_uris, ''] }))
  }

  function removeRedirectUri(index: number) {
    const updated = form.redirect_uris.filter((_, i) => i !== index)
    const final = updated.length === 0 ? [''] : updated
    setForm((prev) => ({ ...prev, redirect_uris: final }))
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const allErrors = validateForm(form)
    if (Object.keys(allErrors).length > 0) {
      setErrors(allErrors)
      return
    }

    setSubmitting(true)
    setApiError(null)

    const formValues: OnboardingFormValues = {
      slug: form.slug.trim(),
      display_name: form.display_name.trim(),
      admin_email: form.admin_email.trim(),
      admin_username: form.admin_username.trim(),
      admin_display_name: form.admin_display_name.trim(),
      hostname: form.hostname.trim(),
      redirect_uris: form.redirect_uris.map((u) => u.trim()).filter((u) => u.length > 0),
      realm_config: buildRealmConfig(form),
      client_config: buildClientConfig(form),
    }

    try {
      const result = await submitOnboarding(formValues, idempotencyKey)
      navigate(`/admin/onboarding/${result.onboarding_id}/progress`, {
        state: { formValues, hostname: formValues.hostname },
      })
    } catch (err) {
      if (err instanceof OnboardingApiError) {
        const resolved = resolveApiErrorMessage(err)
        setApiError(resolved)
      } else {
        setApiError({ banner: 'An unexpected error occurred. Please try again.' })
      }
      setSubmitting(false)
    }
  }

  return (
    <div style={{ padding: '1.5rem', maxWidth: '680px' }}>
      <h2 style={{ margin: '0 0 1.5rem 0' }}>Register Tenant</h2>

      {apiError && (
        <div
          role="alert"
          style={{
            marginBottom: '1.25rem',
            padding: '.75rem 1rem',
            borderRadius: '6px',
            border: '1px solid #fca5a5',
            background: '#fff1f2',
            color: '#9f1239',
            fontSize: '.88rem',
          }}
        >
          {apiError.banner}
          {apiError.progressLink && (
            <>
              {' '}
              <a href={apiError.progressLink} style={{ color: '#1d4ed8' }}>
                View progress
              </a>
            </>
          )}
        </div>
      )}

      <form onSubmit={(e) => { void handleSubmit(e) }} noValidate>
        {/* Slug */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="slug">Slug</label>
          <input
            id="slug"
            style={{ ...inputStyle, borderColor: errors.slug ? '#dc2626' : '#cbd5e1' }}
            value={form.slug}
            onChange={(e) => setField('slug', e.target.value)}
            autoComplete="off"
          />
          {errors.slug && <div style={errorStyle}>{errors.slug}</div>}
        </div>

        {/* Display name */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="display_name">Display Name</label>
          <input
            id="display_name"
            style={{ ...inputStyle, borderColor: errors.display_name ? '#dc2626' : '#cbd5e1' }}
            value={form.display_name}
            onChange={(e) => setField('display_name', e.target.value)}
          />
          {errors.display_name && <div style={errorStyle}>{errors.display_name}</div>}
        </div>

        {/* Admin email */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="admin_email">Admin Email</label>
          <input
            id="admin_email"
            type="email"
            style={{ ...inputStyle, borderColor: errors.admin_email ? '#dc2626' : '#cbd5e1' }}
            value={form.admin_email}
            onChange={(e) => setField('admin_email', e.target.value)}
            autoComplete="off"
          />
          {errors.admin_email && <div style={errorStyle}>{errors.admin_email}</div>}
        </div>

        {/* Admin username */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="admin_username">Admin Username</label>
          <input
            id="admin_username"
            style={{ ...inputStyle, borderColor: errors.admin_username ? '#dc2626' : '#cbd5e1' }}
            value={form.admin_username}
            onChange={(e) => setField('admin_username', e.target.value)}
            autoComplete="off"
          />
          {errors.admin_username && <div style={errorStyle}>{errors.admin_username}</div>}
        </div>

        {/* Admin display name */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="admin_display_name">Admin Display Name</label>
          <input
            id="admin_display_name"
            style={{ ...inputStyle, borderColor: errors.admin_display_name ? '#dc2626' : '#cbd5e1' }}
            value={form.admin_display_name}
            onChange={(e) => setField('admin_display_name', e.target.value)}
          />
          {errors.admin_display_name && <div style={errorStyle}>{errors.admin_display_name}</div>}
        </div>

        {/* Hostname */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="hostname">Hostname</label>
          <input
            id="hostname"
            style={{ ...inputStyle, borderColor: errors.hostname ? '#dc2626' : '#cbd5e1' }}
            value={form.hostname}
            onChange={(e) => setField('hostname', e.target.value)}
            placeholder="tenant.example.com"
          />
          {errors.hostname && <div style={errorStyle}>{errors.hostname}</div>}
        </div>

        {/* Redirect URIs */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle}>Redirect URIs</label>
          {form.redirect_uris.map((uri, idx) => (
            <div key={idx} style={{ display: 'flex', gap: '.5rem', marginBottom: '.4rem' }}>
              <input
                style={{
                  ...inputStyle,
                  flex: 1,
                  borderColor: errors.redirect_uris && idx === 0 ? '#dc2626' : '#cbd5e1',
                }}
                value={uri}
                onChange={(e) => setRedirectUri(idx, e.target.value)}
                placeholder="https://app.example.com/callback"
              />
              {form.redirect_uris.length > 1 && (
                <button
                  type="button"
                  onClick={() => removeRedirectUri(idx)}
                  style={{
                    padding: '.4rem .7rem',
                    border: '1px solid #cbd5e1',
                    borderRadius: '4px',
                    background: '#fff',
                    cursor: 'pointer',
                    color: '#dc2626',
                    fontSize: '.85rem',
                  }}
                >
                  Remove
                </button>
              )}
            </div>
          ))}
          {errors.redirect_uris && <div style={errorStyle}>{errors.redirect_uris}</div>}
          <button
            type="button"
            onClick={addRedirectUri}
            style={{
              marginTop: '.25rem',
              padding: '.35rem .7rem',
              border: '1px solid #cbd5e1',
              borderRadius: '4px',
              background: '#fff',
              cursor: 'pointer',
              fontSize: '.82rem',
            }}
          >
            + Add URI
          </button>
        </div>

        {/* Realm config (collapsible) */}
        <div style={{ marginBottom: '1rem', border: '1px solid #e2e8f0', borderRadius: '6px' }}>
          <button
            type="button"
            onClick={() => setRealmOpen((v) => !v)}
            style={{
              width: '100%',
              textAlign: 'left',
              padding: '.65rem 1rem',
              background: '#f8fafc',
              border: 'none',
              borderRadius: realmOpen ? '6px 6px 0 0' : '6px',
              cursor: 'pointer',
              fontWeight: 600,
              fontSize: '.87rem',
              color: '#374151',
            }}
          >
            {realmOpen ? '▾' : '▸'} Realm Config (optional)
          </button>
          {realmOpen && (
            <div style={{ padding: '1rem', borderTop: '1px solid #e2e8f0' }}>
              <div style={fieldGroupStyle}>
                <label style={labelStyle} htmlFor="realm_token_lifetime">
                  Default Token Lifetime (seconds)
                </label>
                <input
                  id="realm_token_lifetime"
                  type="number"
                  style={inputStyle}
                  value={form.realm_default_token_lifetime_seconds}
                  onChange={(e) => setField('realm_default_token_lifetime_seconds', e.target.value)}
                />
              </div>
              <div style={fieldGroupStyle}>
                <label style={labelStyle} htmlFor="realm_min_pw">
                  Minimum Password Length
                </label>
                <input
                  id="realm_min_pw"
                  type="number"
                  style={inputStyle}
                  value={form.realm_min_password_length}
                  onChange={(e) => setField('realm_min_password_length', e.target.value)}
                />
              </div>
              <div style={{ ...fieldGroupStyle, display: 'flex', gap: '1.5rem', alignItems: 'center' }}>
                <label style={{ display: 'flex', alignItems: 'center', gap: '.4rem', cursor: 'pointer', fontSize: '.87rem' }}>
                  <input
                    type="checkbox"
                    checked={form.realm_require_uppercase}
                    onChange={(e) => setField('realm_require_uppercase', e.target.checked)}
                  />
                  Require Uppercase
                </label>
                <label style={{ display: 'flex', alignItems: 'center', gap: '.4rem', cursor: 'pointer', fontSize: '.87rem' }}>
                  <input
                    type="checkbox"
                    checked={form.realm_require_digit}
                    onChange={(e) => setField('realm_require_digit', e.target.checked)}
                  />
                  Require Digit
                </label>
              </div>
              <div style={fieldGroupStyle}>
                <label style={labelStyle} htmlFor="realm_signing_alg">
                  Signing Key Algorithm
                </label>
                <input
                  id="realm_signing_alg"
                  style={inputStyle}
                  value={form.realm_signing_key_algorithm}
                  onChange={(e) => setField('realm_signing_key_algorithm', e.target.value)}
                  placeholder="RS256"
                />
              </div>
            </div>
          )}
        </div>

        {/* Client config (collapsible) */}
        <div style={{ marginBottom: '1.5rem', border: '1px solid #e2e8f0', borderRadius: '6px' }}>
          <button
            type="button"
            onClick={() => setClientOpen((v) => !v)}
            style={{
              width: '100%',
              textAlign: 'left',
              padding: '.65rem 1rem',
              background: '#f8fafc',
              border: 'none',
              borderRadius: clientOpen ? '6px 6px 0 0' : '6px',
              cursor: 'pointer',
              fontWeight: 600,
              fontSize: '.87rem',
              color: '#374151',
            }}
          >
            {clientOpen ? '▾' : '▸'} Client Config (optional)
          </button>
          {clientOpen && (
            <div style={{ padding: '1rem', borderTop: '1px solid #e2e8f0' }}>
              <label style={{ display: 'flex', alignItems: 'center', gap: '.4rem', cursor: 'pointer', fontSize: '.87rem' }}>
                <input
                  type="checkbox"
                  checked={form.client_service_account_enabled}
                  onChange={(e) => setField('client_service_account_enabled', e.target.checked)}
                />
                Service Account Enabled
              </label>
            </div>
          )}
        </div>

        <button
          type="submit"
          disabled={submitting}
          style={{
            padding: '.55rem 1.4rem',
            background: submitting ? '#94a3b8' : '#1d4ed8',
            color: '#fff',
            border: 'none',
            borderRadius: '6px',
            fontWeight: 600,
            fontSize: '.9rem',
            cursor: submitting ? 'not-allowed' : 'pointer',
          }}
        >
          {submitting ? 'Submitting…' : 'Register Tenant'}
        </button>
      </form>
    </div>
  )
}
