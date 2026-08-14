/** PromotionReviewStateMachine — PRM-04: Promotion review state machine UI
 *
 *  Displays promotion_reviews status with state machine edges visually.
 *  Shows: pending_review / approved / rejected / applied / failed / superseded.
 *  Highlights current state, shows approved_by, approved_at, superseded_by, row_version.
 */

import React from 'react'
import type { PromotionReview, ReviewStatus } from '@/api/promotions'

export interface PromotionReviewStateMachineProps {
  review: PromotionReview
  className?: string
}

// ── State machine definition ───────────────────────────────────────────────────

interface StateNode {
  status: ReviewStatus
  label: string
  description: string
}

interface StateEdge {
  from: ReviewStatus
  to: ReviewStatus
  label?: string
}

const STATES: StateNode[] = [
  { status: 'pending_review', label: 'Pending Review', description: 'Awaiting reviewer approval' },
  { status: 'approved',      label: 'Approved',      description: 'Reviewer approved the plan' },
  { status: 'rejected',      label: 'Rejected',      description: 'Reviewer rejected the plan' },
  { status: 'applied',       label: 'Applied',        description: 'Plan has been applied to target' },
  { status: 'failed',       label: 'Failed',         description: 'Assertion run failed in sandbox' },
  { status: 'superseded',   label: 'Superseded',    description: 'Replaced by a newer review' },
]

const EDGES: StateEdge[] = [
  { from: 'pending_review', to: 'approved',   label: 'approve' },
  { from: 'pending_review', to: 'rejected',   label: 'reject' },
  { from: 'pending_review', to: 'superseded', label: 'superseded' },
  { from: 'approved',      to: 'applied',    label: 'apply' },
  { from: 'approved',      to: 'failed',     label: 'assertion failure' },
  { from: 'applied',      to: 'superseded', label: 'superseded' },
  { from: 'failed',       to: 'superseded', label: 'superseded' },
  { from: 'rejected',     to: 'superseded', label: 'superseded' },
]

const STATUS_META: Record<ReviewStatus, { bg: string; text: string; border: string }> = {
  pending_review: { bg: '#fff3bf', text: '#e67700', border: '#fcc419' },
  approved:       { bg: '#d3f9d8', text: '#2f9e44', border: '#40c057' },
  rejected:       { bg: '#ffe3e3', text: '#c92a2a', border: '#fa5252' },
  applied:        { bg: '#dbe4ff', text: '#3b5bdb', border: '#4c6ef5' },
  failed:         { bg: '#fff0f0', text: '#a61e4d', border: '#e03131' },
  superseded:     { bg: '#f1f3f5', text: '#495057', border: '#ced4da' },
}

function formatDate(iso: string | null): string {
  if (!iso) return '—'
  try {
    return new Date(iso).toLocaleString()
  } catch {
    return iso
  }
}

export function PromotionReviewStateMachine(props: PromotionReviewStateMachineProps): React.ReactElement {
  const { review, className } = props
  const meta = STATUS_META[review.status] ?? STATUS_META.pending_review

  // Build outgoing edges for the current state
  const outgoingEdges = EDGES.filter((e) => e.from === review.status)

  return (
    <div
      data-testid="promotion-review-state-machine"
      className={className}
      style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}
    >
      {/* State machine visualization */}
      <div
        style={{
          padding: '1rem',
          border: '1px solid #e9ecef',
          borderRadius: '8px',
          background: '#f8f9fa',
        }}
      >
        {/* Current state highlight */}
        <div style={{ marginBottom: '.75rem' }}>
          <div style={{ fontSize: '.7rem', fontWeight: 600, color: '#6c757d', marginBottom: '.3rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
            Current Status
          </div>
          <div
            data-testid="review-status-badge"
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: '.4rem',
              padding: '.35rem .75rem',
              borderRadius: '20px',
              background: meta.bg,
              border: `1px solid ${meta.border}`,
            }}
          >
            <span style={{ fontSize: '.8rem', fontWeight: 700, color: meta.text }}>
              {review.status}
            </span>
          </div>
        </div>

        {/* State flow diagram */}
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '.4rem', alignItems: 'center' }}>
          {STATES.map((state, idx) => {
            const isCurrent = state.status === review.status
            const stateMeta = STATUS_META[state.status]
            return (
              <React.Fragment key={state.status}>
                {idx > 0 && (
                  <svg
                    aria-hidden="true"
                    width="20"
                    height="16"
                    viewBox="0 0 20 16"
                    style={{ flexShrink: 0 }}
                  >
                    <line x1="0" y1="8" x2="14" y2="8" stroke="#adb5bd" strokeWidth="1.5" />
                    <polygon points="14,4 20,8 14,12" fill="#adb5bd" />
                  </svg>
                )}
                <div
                  title={state.description}
                  style={{
                    padding: '.3rem .6rem',
                    borderRadius: '6px',
                    background: isCurrent ? stateMeta.bg : '#fff',
                    border: `1.5px solid ${isCurrent ? stateMeta.border : '#dee2e6'}`,
                    opacity: isCurrent ? 1 : 0.6,
                  }}
                >
                  <span
                    style={{
                      fontSize: '.75rem',
                      fontWeight: isCurrent ? 700 : 500,
                      color: isCurrent ? stateMeta.text : '#868e96',
                    }}
                  >
                    {state.label}
                  </span>
                </div>
              </React.Fragment>
            )
          })}
        </div>

        {/* Outgoing edges from current state */}
        {outgoingEdges.length > 0 && (
          <div style={{ marginTop: '.75rem', paddingTop: '.75rem', borderTop: '1px solid #dee2e6' }}>
            <div style={{ fontSize: '.7rem', fontWeight: 600, color: '#6c757d', marginBottom: '.3rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
              Possible Transitions
            </div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '.4rem' }}>
              {outgoingEdges.map((edge) => (
                <span
                  key={`${edge.from}-${edge.to}`}
                  data-testid={`transition-${edge.to}`}
                  style={{
                    fontSize: '.72rem',
                    padding: '.15rem .5rem',
                    borderRadius: '4px',
                    background: '#e9ecef',
                    color: '#495057',
                    fontFamily: 'monospace',
                  }}
                >
                  → {edge.to}
                  {edge.label ? ` (${edge.label})` : ''}
                </span>
              ))}
            </div>
          </div>
        )}
      </div>

      {/* Review metadata */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))',
          gap: '.75rem',
        }}
      >
        {/* Requested by */}
        <MetadataItem
          label="Requested By"
          value={review.requested_by}
          testId="review-requested-by"
        />

        {/* Approved by */}
        <MetadataItem
          label="Approved By"
          value={review.approved_by ?? '—'}
          testId="review-approved-by"
        />

        {/* Approved at */}
        <MetadataItem
          label="Approved At"
          value={formatDate(review.approved_at)}
          testId="review-approved-at"
        />

        {/* Superseded by */}
        <MetadataItem
          label="Superseded By"
          value={review.superseded_by ?? '—'}
          testId="review-superseded-by"
        />

        {/* Row version */}
        <MetadataItem
          label="Row Version"
          value={String(review.row_version)}
          testId="review-row-version"
        />

        {/* Created at */}
        <MetadataItem
          label="Created At"
          value={formatDate(review.created_at)}
          testId="review-created-at"
        />

        {/* Plan digest */}
        <MetadataItem
          label="Plan Digest"
          value={review.plan_digest}
          testId="review-plan-digest"
          mono
        />
      </div>

      {/* Serialised plan preview */}
      {review.serialised_plan && (
        <div>
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: '#495057', marginBottom: '.4rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
            Serialised Plan
          </div>
          <pre
            data-testid="review-serialised-plan"
            style={{
              margin: 0,
              padding: '.75rem 1rem',
              background: '#f8f9fa',
              border: '1px solid #e9ecef',
              borderRadius: '6px',
              fontFamily: 'monospace',
              fontSize: '.75rem',
              color: '#343a40',
              overflowX: 'auto',
              maxHeight: '200px',
              overflowY: 'auto',
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
            }}
          >
            {review.serialised_plan}
          </pre>
        </div>
      )}
    </div>
  )
}

function MetadataItem(props: { label: string; value: string; testId: string; mono?: boolean }) {
  const { label, value, testId, mono } = props
  return (
    <div>
      <div style={{ fontSize: '.7rem', fontWeight: 600, color: '#6c757d', marginBottom: '.2rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
        {label}
      </div>
      <div
        data-testid={testId}
        style={{
          fontSize: '.82rem',
          color: '#212529',
          fontFamily: mono ? 'monospace' : 'inherit',
          wordBreak: 'break-all',
        }}
      >
        {value}
      </div>
    </div>
  )
}
