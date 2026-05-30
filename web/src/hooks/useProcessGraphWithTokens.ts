/** Hook for managing token state in process graphs */
import { useEffect } from 'react'
import { useInstance } from './useInstances'
import type { Token } from '@/types/api'

export interface TokenMarker {
  node_id: string
  count: number // number of concurrent tokens on this node
  status: 'active' | 'completed' | 'pending' | 'error'
}

export interface UseProcessGraphWithTokensResult {
  tokens: TokenMarker[]
  isLoading: boolean
  error: Error | null
}

/**
 * Hook for polling instance state and deriving token markers
 * Refetches every 2 seconds while instance is ACTIVE
 */
export function useProcessGraphWithTokens(instanceId: string): UseProcessGraphWithTokensResult {
  const { data: instance, isLoading, error, refetch } = useInstance(instanceId)

  // Determine if we should be polling
  const shouldPoll = instance?.status === 'ACTIVE'

  // Set up polling interval
  useEffect(() => {
    if (!shouldPoll) return

    const interval = setInterval(() => {
      void refetch()
    }, 2000)

    return () => clearInterval(interval)
  }, [shouldPoll, refetch])

  // Derive token markers from instance state
  const tokens = deriveTokenMarkers(instance)

  return {
    tokens,
    isLoading,
    error: error instanceof Error ? error : null,
  }
}

/**
 * Derive token markers from instance state
 */
function deriveTokenMarkers(instance: unknown | null | undefined): TokenMarker[] {
  if (!instance || typeof instance !== 'object') {
    return []
  }

  const inst = instance as {
    current_tokens?: Token[]
    active_tokens?: Token[]
    status?: string
  }

  const tokens = inst.current_tokens ?? inst.active_tokens ?? []
  const status = inst.status ?? 'UNKNOWN'

  // Group tokens by node and determine status
  const tokensByNode: Record<string, TokenMarker> = {}

  for (const token of tokens) {
    if (typeof token !== 'object' || !token) continue

    const t = token as Token & { node_id?: string; status?: string }
    const nodeId = t.node_id || (t as unknown as Record<string, unknown>).node_id
    const tokenStatus = t.status || 'pending'

    if (!nodeId) continue

    const key = String(nodeId)
    if (!tokensByNode[key]) {
      tokensByNode[key] = {
        node_id: key,
        count: 0,
        status: determineTokenStatus(String(tokenStatus), String(status)),
      }
    }

    tokensByNode[key].count += 1
  }

  return Object.values(tokensByNode)
}

/**
 * Determine token status based on instance status and token status
 */
function determineTokenStatus(
  tokenStatus: string,
  instanceStatus: string
): 'active' | 'completed' | 'pending' | 'error' {
  if (instanceStatus === 'COMPLETED' || instanceStatus === 'CANCELLED') {
    return 'completed'
  }

  if (instanceStatus === 'ERROR') {
    return 'error'
  }

  // Map token status to marker status
  switch (tokenStatus.toLowerCase()) {
    case 'active':
    case 'executing':
      return 'active'
    case 'completed':
    case 'finished':
      return 'completed'
    case 'waiting':
    case 'pending':
      return 'pending'
    case 'error':
    case 'failed':
      return 'error'
    default:
      return 'pending'
  }
}
