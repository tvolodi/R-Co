/** NonSkippableApprovalGate — PRM-05: Non-skippable approval gate UI
 *
 *  Displays the full promotion context (stored plan, digest, assertions, NEEDS_REVIEW package).
 *  Provides Reject / Approve / Apply buttons with:
 *    - Self-approval prevention (HTTP 403 inline error)
 *    - Apply button disabled unless plan_digest present in context
 *    - HTTP 422 for extra fields on apply (shown inline)
 *  Gate is non-skippable: no bypass parameter exists.
 */

import React, { useState } from 'react'
import type {
  PromotionContext,
} from '@/api/promotions'
import { PlanDigestView } from './PlanDigestView'

export interface NonSkippableApprovalGateProps {
  /** The full context response from GET /api/v1/promotions/{id}/context */
  context: PromotionContext
  /** Current user ID (sub from JWT) — used to enforce requested_by != approved_by */
  currentUserId: string
  /** Called when the review transitions; parent should invalidate queries */
  onTransition?: () => void
  /** Mutation helpers (passed in from parent to avoid coupling to query client here) */
  onApprove: (reviewId: string, planDigest: string) => Promise<void>
  onReject: (reviewId: string) => Promise<void>
  onApply: (reviewId: string, planDigest: string) => Promise<void>
  className?: string
}

// ── Inline error alert ─────────────────────────────────────────────────────────

function InlineError(props: { message: string; testId?: string }) {
  return (
    <div
      data-testid={props.testId ?? 'inline-error'}
      role="alert"
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '.4rem',
        padding: '.5rem .75rem',
        borderRadius: '6px',
        background: '#fff5f5',
        border: '1px solid #fa5252',
        color: '#c92a2a',
        fontSize: '.82rem',
        marginTop: '.5rem',
      }}
    >
      <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="10" />
        <line x1="12" y1="8" x2="12" y2="12" />
        <line x1="12" y1="16" x2="12.01" y2="16" />
      </svg>
      {props.message}
    </div>
  )
}

// ── Self-approval error (HTTP 403) ───────────────────────────────────────────

function SelfApprovalError(props: { message?: string }) {
  return (
    <InlineError
      testId="self-approval-error"
      message={props.message ?? 'You cannot approve your own promotion request. A different reviewer must approve.'}
    />
  )
}

// ── Digest mismatch error (HTTP 409) ──────────────────────────────────────────

function DigestMismatchError(props: { message?: string }) {
  return (
    <InlineError
      testId="digest-mismatch-error"
      message={props.message ?? 'Plan digest mismatch. The plan may have changed since submission. Please review again.'}
    />
  )
}

// ── Invalid transition error (HTTP 400) ───────────────────────────────────────

function TransitionError(props: { message?: string }) {
  return (
    <InlineError
      testId="transition-error"
      message={props.message ?? 'This action is not permitted in the current review state.'}
    />
  )
}

// ── Extra fields error (HTTP 422) ─────────────────────────────────────────────

function ExtraFieldsError(props: { message?: string }) {
  return (
    <InlineError
      testId="extra-fields-error"
      message={props.message ?? 'Unknown fields in request body. Ensure no extra parameters are sent.'}
    />
  )
}

// ── Assertion item ─────────────────────────────────────────────────────────────

function AssertionItem(props: { artifact_id: string; assertion_type: string; passed: boolean }) {
  return (
    <div
      data-testid={`assertion-${props.assertion_type}`}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '.5rem',
        padding: '.4rem .6rem',
        borderRadius: '5px',
        background: props.passed ? '#f8fff8' : '#fff5f5',
        border: `1px solid ${props.passed ? '#40c057' : '#fa5252'}`,
      }}
    >
      {props.passed ? (
        <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#2f9e44" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <polyline points="20 6 9 17 4 12" />
        </svg>
      ) : (
        <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#c92a2a" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <line x1="18" y1="6" x2="6" y2="18" />
          <line x1="6" y1="6" x2="18" y2="18" />
        </svg>
      )}
      <code style={{ fontFamily: 'monospace', fontSize: '.75rem', color: '#343a40' }}>
        {props.assertion_type}
      </code>
      <span style={{ fontSize: '.72rem', color: '#6c757d', marginLeft: 'auto' }}>
        {props.artifact_id}
      </span>
    </div>
  )
}

// ── Main component ─────────────────────────────────────────────────────────────

export function NonSkippableApprovalGate(props: NonSkippableApprovalGateProps): React.ReactElement {
  const { context, currentUserId, onApprove, onReject, onApply, className } = props
  const { review, plan, digest_verified, assertions } = context

  const [approving, setApproving] = useState(false)
  const [rejecting, setRejecting] = useState(false)
  const [applying, setApplying] = useState(false)

  const [selfApprovalError, setSelfApprovalError] = useState(false)
  const [digestError, setDigestError] = useState(false)
  const [transitionError, setTransitionError] = useState(false)
  const [extraFieldsError, setExtraFieldsError] = useState(false)
  const [generalError, setGeneralError] = useState<string | null>(null)

  const isSelfApproval = review.requested_by === currentUserId
  const canApprove = !isSelfApproval && review.status === 'pending_review'
  const canReject = review.status === 'pending_review'
  const canApply = review.status === 'approved' && !!review.plan_digest

  async function handleApprove() {
    setSelfApprovalError(false)
    setDigestError(false)
    setTransitionError(false)
    setExtraFieldsError(false)
    setGeneralError(null)

    if (isSelfApproval) {
      setSelfApprovalError(true)
      return
    }

    setApproving(true)
    try {
      await onApprove(review.id, review.plan_digest)
    } catch (err: unknown) {
      const err2 = err as { status?: number; code?: string; message?: string }
      if (err2.status === 403 || err2.code === 'SELF_APPROVAL_FORBIDDEN') {
        setSelfApprovalError(true)
      } else if (err2.status === 409 || err2.code === 'PLAN_DIGEST_MISMATCH') {
        setDigestError(true)
      } else if (err2.status === 400 || err2.code === 'INVALID_REVIEW_TRANSITION') {
        setTransitionError(true)
      } else if (err2.status === 422) {
        setExtraFieldsError(true)
      } else {
        setGeneralError(err2.message ?? 'Approval failed. Please try again.')
      }
    } finally {
      setApproving(false)
    }
  }

  async function handleReject() {
    setTransitionError(false)
    setGeneralError(null)
    setRejecting(true)
    try {
      await onReject(review.id)
    } catch (err: unknown) {
      const err2 = err as { status?: number; code?: string; message?: string }
      if (err2.status === 400 || err2.code === 'INVALID_REVIEW_TRANSITION') {
        setTransitionError(true)
      } else {
        setGeneralError(err2.message ?? 'Rejection failed. Please try again.')
      }
    } finally {
      setRejecting(false)
    }
  }

  async function handleApply() {
    setDigestError(false)
    setTransitionError(false)
    setExtraFieldsError(false)
    setGeneralError(null)
    setApplying(true)
    try {
      await onApply(review.id, review.plan_digest)
    } catch (err: unknown) {
      const err2 = err as { status?: number; code?: string; message?: string }
      if (err2.status === 409 || err2.code === 'PLAN_DIGEST_MISMATCH') {
        setDigestError(true)
      } else if (err2.status === 400 || err2.code === 'INVALID_REVIEW_TRANSITION') {
        setTransitionError(true)
      } else if (err2.status === 422) {
        setExtraFieldsError(true)
      } else {
        setGeneralError(err2.message ?? 'Apply failed. Please try again.')
      }
    } finally {
      setApplying(false)
    }
  }

  return (
    <div
      data-testid="non-skippable-approval-gate"
      className={className}
      style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem' }}
    >
      {/* NEEDS_REVIEW package + assertions */}
      <div
        style={{
          padding: '1rem',
          borderRadius: '8px',
          border: '1px solid #e9ecef',
          background: '#fff',
        }}
      >
        <div style={{ fontSize: '.7rem', fontWeight: 600, color: '#6c757d', marginBottom: '.5rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
          Artifact Assertions
        </div>
        {assertions && assertions.length > 0 ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '.35rem' }}>
            {assertions.map((a) => (
              <AssertionItem key={a.artifact_id + a.assertion_type} {...a} />
            ))}
          </div>
        ) : (
          <p style={{ margin: 0, fontSize: '.82rem', color: '#6c757d' }}>No assertions available.</p>
        )}
      </div>

      {/* Plan digest view */}
      <PlanDigestView
        planDigest={review.plan_digest}
        plan={plan}
        digestVerified={digest_verified}
      />

      {/* Action buttons */}
      <div
        style={{
          display: 'flex',
          flexWrap: 'wrap',
          gap: '.75rem',
          alignItems: 'flex-start',
        }}
      >
        {/* Reject button */}
        <button
          data-testid="reject-btn"
          type="button"
          disabled={!canReject || rejecting}
          onClick={handleReject}
          style={{
            padding: '.5rem 1.25rem',
            border: '1px solid #fa5252',
            borderRadius: '6px',
            background: '#fff',
            color: '#c92a2a',
            cursor: !canReject || rejecting ? 'not-allowed' : 'pointer',
            fontSize: '.875rem',
            fontWeight: 500,
            opacity: !canReject || rejecting ? 0.55 : 1,
          }}
        >
          {rejecting ? 'Rejecting…' : 'Reject'}
        </button>

        {/* Approve button */}
        <button
          data-testid="approve-btn"
          type="button"
          disabled={!canApprove || approving}
          onClick={handleApprove}
          style={{
            padding: '.5rem 1.25rem',
            border: 'none',
            borderRadius: '6px',
            background: isSelfApproval ? '#ced4da' : '#2563eb',
            color: '#fff',
            cursor: !canApprove || approving ? 'not-allowed' : 'pointer',
            fontSize: '.875rem',
            fontWeight: 500,
            opacity: !canApprove || approving ? 0.55 : 1,
          }}
          title={isSelfApproval ? 'Self-approval is not permitted' : undefined}
        >
          {approving ? 'Approving…' : 'Approve'}
        </button>

        {/* Apply button */}
        <button
          data-testid="apply-btn"
          type="button"
          disabled={!canApply || applying}
          onClick={handleApply}
          style={{
            padding: '.5rem 1.25rem',
            border: 'none',
            borderRadius: '6px',
            background: canApply ? '#40c057' : '#adb5bd',
            color: '#fff',
            cursor: !canApply || applying ? 'not-allowed' : 'pointer',
            fontSize: '.875rem',
            fontWeight: 500,
            opacity: !canApply || applying ? 0.55 : 1,
          }}
          title={!canApply && review.status === 'approved' && !review.plan_digest ? 'Plan digest missing — cannot apply' : undefined}
        >
          {applying ? 'Applying…' : 'Apply'}
        </button>

        {/* Non-skippable gate notice */}
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: '.3rem' }}>
          <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#6c757d" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
            <path d="M7 11V7a5 5 0 0 1 10 0v4" />
          </svg>
          <span style={{ fontSize: '.72rem', color: '#6c757d' }}>
            Non-skippable gate
          </span>
        </div>
      </div>

      {/* Inline errors */}
      {selfApprovalError && <SelfApprovalError />}
      {digestError && <DigestMismatchError />}
      {transitionError && <TransitionError />}
      {extraFieldsError && <ExtraFieldsError />}
      {generalError && <InlineError testId="general-error" message={generalError} />}
    </div>
  )
}
