/** OnboardingProgressPage — ONB-UI-03
 *
 * Polls GET /api/v1/onboarding/:onboardingId at a fixed interval.
 * Uses a manual setInterval in useEffect (NOT TanStack Query refetchInterval)
 * so that the interval can be cleared and navigation triggered on terminal state.
 *
 * Polling rules:
 * - Skip tick if document.hidden (Page Visibility API)
 * - state=pending: reset transient error counter, stay on screen
 * - state=completed|failed: clearInterval, navigate to result screen
 * - 3 consecutive transient errors: clearInterval, show error banner + Retry button
 * - cleanup: clearInterval unconditionally on unmount
 */

import { useEffect, useRef, useState } from 'react'
import { Navigate, useNavigate, useParams, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import {
  getOnboardingStatus,
  type OnboardingFormValues,
  type OnboardingSagaResult,
} from '@/api/onboarding'

const DEFAULT_POLL_MS = 10_000

export default function OnboardingProgressPage() {
  const { session } = useAuth()
  const { onboardingId } = useParams<{ onboardingId: string }>()
  const navigate = useNavigate()
  const location = useLocation()

  const locationState = location.state as {
    formValues?: OnboardingFormValues
    hostname?: string
  } | null

  const pollMs = Number(import.meta.env.VITE_POLL_INTERVAL_MS ?? DEFAULT_POLL_MS)

  const [errorBanner, setErrorBanner] = useState(false)
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const transientErrorCount = useRef(0)
  // Track latest navigate/state in refs to avoid stale closure
  const navigateRef = useRef(navigate)
  navigateRef.current = navigate
  const formValuesRef = useRef(locationState?.formValues)
  formValuesRef.current = locationState?.formValues
  const hostnameRef = useRef(locationState?.hostname ?? '')
  hostnameRef.current = locationState?.hostname ?? ''

  function startPolling() {
    if (!onboardingId) return

    function clearPoll() {
      if (intervalRef.current !== null) {
        clearInterval(intervalRef.current)
        intervalRef.current = null
      }
    }

    async function tick() {
      if (document.hidden) return

      try {
        const result: OnboardingSagaResult = await getOnboardingStatus(onboardingId!)
        transientErrorCount.current = 0

        if (result.state === 'completed' || result.state === 'failed') {
          clearPoll()
          const hn = hostnameRef.current
          navigateRef.current(
            `/admin/onboarding/${onboardingId}/result${hn ? `?hostname=${encodeURIComponent(hn)}` : ''}`,
            {
              state: {
                sagaResult: result,
                formValues: formValuesRef.current,
              },
            },
          )
        }
        // state === 'pending': stay, transient counter already reset
      } catch {
        transientErrorCount.current += 1
        if (transientErrorCount.current >= 3) {
          clearPoll()
          setErrorBanner(true)
        }
      }
    }

    setErrorBanner(false)
    transientErrorCount.current = 0
    intervalRef.current = setInterval(() => { void tick() }, pollMs)
  }

  useEffect(() => {
    startPolling()
    return () => {
      if (intervalRef.current !== null) {
        clearInterval(intervalRef.current)
        intervalRef.current = null
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onboardingId])

  // Role guard — after all hooks
  if (!session?.roles.includes('PLATFORM_ADMIN')) {
    return <Navigate to="/instances" replace />
  }

  function handleRetry() {
    startPolling()
  }

  return (
    <div style={{ padding: '2rem', maxWidth: '520px' }}>
      <h2 style={{ margin: '0 0 1.5rem 0' }}>Onboarding in Progress</h2>

      {!errorBanner && (
        <>
          <div
            role="status"
            aria-label="Onboarding in progress"
            style={{ display: 'flex', alignItems: 'center', gap: '1rem', marginBottom: '1.5rem' }}
          >
            <Spinner />
            <span style={{ color: '#475569', fontSize: '.95rem' }}>
              Setting up tenant — this may take a moment…
            </span>
          </div>
          <p style={{ color: '#94a3b8', fontSize: '.85rem' }}>
            Onboarding ID: <code>{onboardingId}</code>
          </p>
        </>
      )}

      {errorBanner && (
        <div
          role="alert"
          style={{
            padding: '.85rem 1rem',
            borderRadius: '6px',
            border: '1px solid #fca5a5',
            background: '#fff1f2',
            color: '#9f1239',
            fontSize: '.88rem',
            marginBottom: '1.25rem',
          }}
        >
          <p style={{ margin: '0 0 .75rem 0' }}>
            Unable to check onboarding status. The service may be temporarily unavailable.
          </p>
          <button
            onClick={handleRetry}
            style={{
              padding: '.4rem .9rem',
              background: '#1d4ed8',
              color: '#fff',
              border: 'none',
              borderRadius: '4px',
              cursor: 'pointer',
              fontWeight: 600,
              fontSize: '.85rem',
            }}
          >
            Retry
          </button>
        </div>
      )}
    </div>
  )
}

function Spinner() {
  return (
    <svg
      width="24"
      height="24"
      viewBox="0 0 24 24"
      style={{ animation: 'spin 1s linear infinite' }}
      aria-hidden="true"
    >
      <style>{`@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }`}</style>
      <circle
        cx="12"
        cy="12"
        r="10"
        fill="none"
        stroke="#cbd5e1"
        strokeWidth="3"
      />
      <path
        d="M12 2 A10 10 0 0 1 22 12"
        fill="none"
        stroke="#1d4ed8"
        strokeWidth="3"
        strokeLinecap="round"
      />
    </svg>
  )
}
