/** Token visualization utilities for ProcessGraphWithTokens component */

/**
 * Get SVG fill colour for a token status
 */
export function getTokenMarkerColour(status: 'active' | 'completed' | 'pending' | 'error'): string {
  const colours = {
    active: '#3b82f6',    // blue
    completed: '#10b981', // green
    pending: '#f59e0b',   // amber
    error: '#ef4444',     // red
  }
  return colours[status]
}

/**
 * Compute position on node for token marker (top-right)
 */
export function computeTokenMarkerPosition(
  nodeWidth: number,
  _nodeHeight: number,
  markerSize: number = 24
): { x: number; y: number } {
  // Position at top-right corner with slight padding
  return {
    x: nodeWidth - markerSize / 2 - 4,
    y: -(markerSize / 2) + 4,
  }
}

/**
 * Determine visual significance of an event for timeline tick height
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
 * Compute tick positions for timeline visualization
 */
export function computeTickPositions(
  totalEvents: number,
  trackWidth: number
): Array<{ position: number; significance: 'high' | 'medium' | 'low' }> {
  if (totalEvents <= 0) return []

  const ticks: Array<{ position: number; significance: 'high' | 'medium' | 'low' }> = []

  // Always include first and last
  ticks.push({ position: 0, significance: 'high' })
  if (totalEvents > 1) {
    ticks.push({ position: trackWidth, significance: 'high' })
  }

  return ticks
}
