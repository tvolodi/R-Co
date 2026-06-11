interface TestEnvironmentBannerProps {
  isTestTenant: boolean
  productionTenantName: string | null
}

export function TestEnvironmentBanner({ isTestTenant, productionTenantName }: TestEnvironmentBannerProps) {
  if (!isTestTenant) return null

  return (
    <div
      data-testid="test-env-banner"
      role="status"
      aria-label="Test environment indicator"
      style={{
        position: 'fixed',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 200,
        background: '#fef3c7',
        borderBottom: '2px solid #f59e0b',
        color: '#92400e',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '.5rem',
        padding: '0 1rem',
        height: '40px',
        fontSize: '.88rem',
        fontWeight: 600,
        userSelect: 'none',
      }}
    >
      <span>⚗ TEST ENVIRONMENT</span>
      {productionTenantName && (
        <span
          style={{
            fontWeight: 400,
          }}
          className="test-env-banner-tenant"
        >
          (linked to: {productionTenantName})
        </span>
      )}
      <style>{`
        @media (max-width: 480px) {
          .test-env-banner-tenant { display: none !important; }
        }
      `}</style>
    </div>
  )
}
