/** Utility functions for history scrubber component */
import type { ProcessInstance } from '@/types/api'

/**
 * Determine visual significance of an event for tick height
 */
export function getEventSignificance(eventType: string): 'high' | 'medium' | 'low' {
  const highSignificance = [
    'INSTANCE_STARTED',
    'INSTANCE_COMPLETED',
    'INSTANCE_CANCELLED',
    'INSTANCE_ERROR',
    'TASK_CREATED',
    'TASK_COMPLETED',
    'GATEWAY_EVALUATED',
    'TIMER_TRIGGERED',
  ]

  const mediumSignificance = [
    'TOKEN_MOVED',
    'TOKEN_CREATED',
    'TOKEN_COMPLETED',
    'VARIABLE_UPDATED',
  ]

  if (highSignificance.includes(eventType)) {
    return 'high'
  } else if (mediumSignificance.includes(eventType)) {
    return 'medium'
  }
  return 'low'
}

/**
 * Generate human-readable description of state change between two instance states
 */
export function describeStateChange(prevState: ProcessInstance | null, nextState: ProcessInstance): string {
  if (!prevState) {
    return 'Instance started'
  }

  const changes: string[] = []

  // Check if variables changed
  const prevVars = prevState.variables || {}
  const nextVars = nextState.variables || {}
  const changedVars = Object.keys(nextVars).filter((key) => prevVars[key] !== nextVars[key])
  if (changedVars.length > 0) {
    changes.push(`Variables changed: ${changedVars.join(', ')}`)
  }

  // Check if tokens moved
  const prevNodes = new Set(prevState.current_nodes || [])
  const nextNodes = new Set(nextState.current_nodes || [])
  const newNodes = [...nextNodes].filter((n) => !prevNodes.has(n))
  if (newNodes.length > 0) {
    changes.push(`Tokens moved to: ${newNodes.join(', ')}`)
  }

  // Check if tasks were completed
  const prevTasks = prevState.current_tasks || []
  const nextTasks = nextState.current_tasks || []
  if (nextTasks.length < prevTasks.length) {
    changes.push(`${prevTasks.length - nextTasks.length} task(s) completed`)
  }

  // Check status change
  if (prevState.status !== nextState.status) {
    changes.push(`Status: ${prevState.status} → ${nextState.status}`)
  }

  return changes.length > 0 ? changes.join(' • ') : 'State unchanged'
}

/**
 * Compute tick positions for timeline visualization
 */
export function computeTickPositions(
  totalEvents: number,
  trackWidth: number
): Array<{ position: number; significance: 'high' | 'medium' | 'low' }> {
  if (totalEvents <= 0) return []

  const ticks: Array<{ position: number; significance: 'high' | 'medium' | 'low' }> = []

  // Always include first event
  if (totalEvents > 0) {
    ticks.push({ position: 0, significance: 'high' })
  }

  // Always include last event
  if (totalEvents > 1) {
    ticks.push({ position: trackWidth, significance: 'high' })
  }

  return ticks
}
