import React from 'react'

export interface SkeletonColumn {
  widthPercent: number
}

interface SkeletonLayoutProps {
  columns: SkeletonColumn[]
  rowCount?: number
}

export function SkeletonLayout({ columns, rowCount = 5 }: SkeletonLayoutProps): React.ReactElement {
  return (
    <div aria-busy="true" aria-label="Loading content" style={{ padding: '1rem' }}>
      {Array.from({ length: rowCount }).map((_, rowIdx) => (
        <div key={rowIdx} style={{ display: 'flex', gap: '.5rem', marginBottom: '.5rem' }}>
          {columns.map((col, colIdx) => (
            <div
              key={colIdx}
              style={{
                width: `${col.widthPercent}%`,
                height: '1.25rem',
                borderRadius: '4px',
                background: rowIdx % 2 === 0
                  ? 'var(--color-neutral-200)'
                  : 'var(--color-neutral-100)',
              }}
            />
          ))}
        </div>
      ))}
    </div>
  )
}
