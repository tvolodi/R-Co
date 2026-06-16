import { useTenantContext } from '@/auth/useTenantContext'

export function TenantHeader(): JSX.Element {
  const { tenantDisplayName, isUnknown } = useTenantContext()

  return (
    <div
      style={{
        padding: '0 1.25rem',
        marginBottom: '.75rem',
        borderBottom: '1px solid #334155',
        paddingBottom: '.75rem',
      }}
    >
      <div
        data-testid={isUnknown ? 'tenant-display-name-unknown' : 'tenant-display-name'}
        style={{
          fontSize: '.78rem',
          fontWeight: 600,
          color: isUnknown ? '#64748b' : '#38bdf8',
          textTransform: 'uppercase',
          letterSpacing: '.05em',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
        }}
        title={tenantDisplayName}
      >
        {tenantDisplayName}
      </div>
    </div>
  )
}
