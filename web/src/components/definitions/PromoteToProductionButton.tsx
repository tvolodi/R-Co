import { useState } from 'react'
import { useTestEnvironment } from '@/hooks/useTestEnvironment'
import { PromoteConfirmModal } from './PromoteConfirmModal'
import type { DefinitionStatus } from '@/types/api'

export interface PromoteToProductionButtonProps {
  definitionName: string
  definitionStatus: DefinitionStatus
  onPromoteSuccess: () => void
}

export function PromoteToProductionButton({
  definitionName,
  definitionStatus,
  onPromoteSuccess,
}: PromoteToProductionButtonProps) {
  const { isTestTenant, productionTenantName, currentTenantSlug } = useTestEnvironment()
  const [modalOpen, setModalOpen] = useState(false)

  if (!isTestTenant || definitionStatus !== 'ACTIVE') return null

  const productionDisplayName = productionTenantName ?? 'production'
  const testTenantId = currentTenantSlug ?? ''

  return (
    <>
      <button
        data-testid="btn-promote-to-production"
        type="button"
        onClick={() => setModalOpen(true)}
        style={{
          padding: '.45rem 1rem',
          border: '2px solid #f59e0b',
          borderRadius: 4,
          background: '#fef3c7',
          color: '#92400e',
          fontWeight: 600,
          cursor: 'pointer',
          fontSize: '.9rem',
        }}
      >
        Promote to Production
      </button>

      <PromoteConfirmModal
        open={modalOpen}
        testTenantId={testTenantId}
        definitionName={definitionName}
        productionDisplayName={productionDisplayName}
        onSuccess={() => {
          setModalOpen(false)
          onPromoteSuccess()
        }}
        onCancel={() => setModalOpen(false)}
      />
    </>
  )
}
