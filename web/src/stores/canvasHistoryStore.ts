/**
 * canvasHistoryStore — Zustand-based undo/redo history stack
 *
 * Tracks past/present/future states of the canvas (nodes + edges).
 * Supports pushSnapshot, undo, redo, and clear operations.
 * Max depth is configurable (default: 50).
 */

import { create } from 'zustand'

// ── Types ─────────────────────────────────────────────────────────────────────

export interface CanvasSnapshot {
  nodesJSON: string
  edgesJSON: string
}

interface CanvasHistoryState {
  past: CanvasSnapshot[]
  future: CanvasSnapshot[]
  maxDepth: number

  /** Push a snapshot onto the history stack (clears future). */
  pushSnapshot: (snapshot: CanvasSnapshot) => void

  /**
   * Undo: pop last from past[], push current onto future[], return popped snapshot.
   * Returns null if past is empty.
   */
  undo: (current: CanvasSnapshot) => CanvasSnapshot | null

  /**
   * Redo: pop last from future[], push current onto past[], return popped snapshot.
   * Returns null if future is empty.
   */
  redo: (current: CanvasSnapshot) => CanvasSnapshot | null

  /** Clear the entire history stack. */
  clear: () => void

  /** Number of undo steps available. */
  undoCount: () => number

  /** Number of redo steps available. */
  redoCount: () => number
}

// ── Store ─────────────────────────────────────────────────────────────────────

export const useCanvasHistoryStore = create<CanvasHistoryState>((set, get) => ({
  past: [],
  future: [],
  maxDepth: 50,

  pushSnapshot: (snapshot: CanvasSnapshot) => {
    set((state) => {
      const newPast = [...state.past, snapshot]
      // Cap at maxDepth
      if (newPast.length > state.maxDepth) {
        newPast.splice(0, newPast.length - state.maxDepth)
      }
      return { past: newPast, future: [] }
    })
  },

  undo: (current: CanvasSnapshot) => {
    const { past } = get()
    if (past.length === 0) return null

    const newPast = [...past]
    const snapshot = newPast.pop()!
    set({ past: newPast, future: [current, ...get().future] })
    return snapshot
  },

  redo: (current: CanvasSnapshot) => {
    const { future } = get()
    if (future.length === 0) return null

    const newFuture = [...future]
    const snapshot = newFuture.shift()!
    set({ past: [...get().past, current], future: newFuture })
    return snapshot
  },

  clear: () => {
    set({ past: [], future: [] })
  },

  undoCount: () => get().past.length,

  redoCount: () => get().future.length,
}))
