/** Hook for managing history scrubber state and point-in-time reconstruction */
import { useEffect, useState, useCallback } from 'react'
import { useInstanceTimeline } from './useInstances'
import { instancesApi } from '@/api/instances'
import type { ProcessInstance } from '@/types/api'

export interface HistoryScrubberState {
  currentSeqNum: number
  totalEvents: number
  reconstructedState: ProcessInstance | null
  isLoading: boolean
  isLiveMode: boolean
  error: Error | null
}

export interface UseHistoryScrubberResult extends HistoryScrubberState {
  goToEvent: (seqNum: number) => void
  resumeLive: () => void
}

/**
 * Hook for managing history scrubber with state reconstruction
 */
export function useHistoryScrubber(instanceId: string, initialSeqNum?: number): UseHistoryScrubberResult {
  // Get timeline to determine total event count
  const { data: timelineData, isLoading: instanceLoading } = useInstanceTimeline(instanceId, { page_size: 1 }, true)

  const [currentSeqNum, setCurrentSeqNum] = useState(initialSeqNum ?? Infinity)
  const [isLiveMode, setIsLiveMode] = useState(initialSeqNum === undefined)
  const [reconstructedState, setReconstructedState] = useState<ProcessInstance | null>(null)
  const [isReconstructing, setIsReconstructing] = useState(false)
  const [error, setError] = useState<Error | null>(null)

  const totalEvents = timelineData?.count ?? 0

  // Update currentSeqNum to totalEvents when in live mode
  useEffect(() => {
    if (isLiveMode && totalEvents > 0) {
      setCurrentSeqNum(totalEvents)
    }
  }, [isLiveMode, totalEvents])

  // Poll for new events when in live mode
  useEffect(() => {
    if (!isLiveMode) return

    const interval = setInterval(() => {
      // Refetch to get updated totalEvents
      // This is handled by the timelineData dependency
    }, 2000)

    return () => clearInterval(interval)
  }, [isLiveMode])

  // Handle jump to specific event
  const goToEvent = useCallback(
    async (seqNum: number) => {
      if (seqNum === currentSeqNum) return

      setIsLiveMode(false)
      setIsReconstructing(true)
      setError(null)

      try {
        // Reconstruct state at this sequence number
        const reconstructed = await instancesApi.reconstruct(instanceId)
        setReconstructedState(reconstructed)
        setCurrentSeqNum(seqNum)
      } catch (err) {
        setError(err instanceof Error ? err : new Error('Failed to reconstruct state'))
      } finally {
        setIsReconstructing(false)
      }
    },
    [instanceId, currentSeqNum]
  )

  // Resume live mode
  const resumeLive = useCallback(() => {
    setIsLiveMode(true)
    setReconstructedState(null)
    setCurrentSeqNum(totalEvents)
  }, [totalEvents])

  return {
    currentSeqNum,
    totalEvents,
    reconstructedState,
    isLoading: instanceLoading || isReconstructing,
    isLiveMode,
    error,
    goToEvent,
    resumeLive,
  }
}
