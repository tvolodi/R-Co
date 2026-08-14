/** ConflictRejectionAlert — PRM-02: Conflict pre-flight rejection UI
 *
 *  Displays ConflictRejection details when a promotion returns HTTP 409 PROMOTION_CONFLICT.
 *  Shows conflicting definitions with source change vs target change.
 */

import React from 'react'
import type { PromotionConflictItem } from '@/api/promotions'

export interface ConflictRejectionAlertProps {
  /** The full 409 PROMOTION_CONFLICT response body */
  conflict: PromotionConflictItem
  /** Optional className for container styling */
  className?: string
}

const STATUSBadgeColors: Record<string, { bg: string; text: string }> = {
  source: { bg: '#dbe4ff', text: '#3b5bdb' },
  target: { bg: '#ffe3e3', text: '#c92a2a' },
}

export function ConflictRejectionAlert(props: ConflictRejectionAlertProps): React.ReactElement {
  const { conflict, className } = props

  return (
    <div
      data-testid="conflict-rejection-alert"
      className={className}
      style={{
        border: '1px solid #fa5252',
        borderRadius: '8px',
        padding: '1rem',
        background: '#fff5f5',
      }}
    >
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '.5rem', marginBottom: '.75rem' }}>
        <svg
          aria-hidden="true"
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="#c92a2a"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" />
          <line x1="12" y1="9" x2="12" y2="13" />
          <line x1="12" y1="17" x2="12.01" y2="17" />
        </svg>
        <span style={{ fontWeight: 600, color: '#c92a2a', fontSize: '.95rem' }}>
          Promotion Conflict Detected
        </span>
      </div>

      {/* Conflict detail */}
      <div style={{ marginBottom: '.75rem' }}>
        <p style={{ margin: '0 0 .5rem', fontSize: '.875rem', color: '#495057' }}>
          The target tenant has <strong>advanced past</strong> the version your source was branched from.
          Conflicting definition:
        </p>

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.82rem' }}>
          <thead>
            <tr>
              <th style={{ textAlign: 'left', padding: '.35rem .5rem', borderBottom: '1px solid #fcc419', color: '#495057' }}>Process Key</th>
              <th style={{ textAlign: 'left', padding: '.35rem .5rem', borderBottom: '1px solid #fcc419', color: '#495057' }}>Target Version</th>
              <th style={{ textAlign: 'left', padding: '.35rem .5rem', borderBottom: '1px solid #fcc419', color: '#495057' }}>Target Def ID</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td style={{ padding: '.35rem .5rem', borderBottom: '1px solid #f1f5f9', fontFamily: 'monospace' }}>{conflict.process_key}</td>
              <td style={{ padding: '.35rem .5rem', borderBottom: '1px solid #f1f5f9', fontFamily: 'monospace', fontWeight: 600 }}>{conflict.target_version}</td>
              <td style={{ padding: '.35rem .5rem', borderBottom: '1px solid #f1f5f9', fontFamily: 'monospace', fontSize: '.75rem' }}>{conflict.target_definition_id}</td>
            </tr>
          </tbody>
        </table>
      </div>

      {/* Source vs Target comparison */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '.75rem' }}>
        <div
          style={{
            padding: '.6rem .75rem',
            borderRadius: '6px',
            background: STATUSBadgeColors.source.bg,
          }}
        >
          <div style={{ fontSize: '.7rem', fontWeight: 600, color: STATUSBadgeColors.source.text, marginBottom: '.25rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
            Source Change
          </div>
          <div style={{ fontSize: '.82rem', color: '#343a40' }}>
            {conflict.source_change}
          </div>
        </div>

        <div
          style={{
            padding: '.6rem .75rem',
            borderRadius: '6px',
            background: STATUSBadgeColors.target.bg,
          }}
        >
          <div style={{ fontSize: '.7rem', fontWeight: 600, color: STATUSBadgeColors.target.text, marginBottom: '.25rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
            Target Change
          </div>
          <div style={{ fontSize: '.82rem', color: '#343a40' }}>
            {conflict.target_change}
          </div>
        </div>
      </div>

      {/* Action hint */}
      <p style={{ margin: '.75rem 0 0', fontSize: '.8rem', color: '#6c757d' }}>
        Resolve the conflict by promoting from the target tenant's current version, then retry.
      </p>
    </div>
  )
}
