/**
 * canvasHistoryStore — Zustand store for canvas undo/redo history
 *
 * Schema defined in Batch 1 for import stability. Logic implemented in Batch 2
 * (PD-UI-19). Placeholder actions exist to prevent import errors.
 */

import { create } from 'zustand'

interface CanvasSnapshot {
  nodesJSON: string
  edgesJSON: string
}

interface CanvasHistoryState {
  /** Undo stack (past states) */
  past: CanvasSnapshot[]
  /** Redo stack (future states) */
  future: CanvasSnapshot[]
  /** Push a snapshot onto the undo stack */
  pushSnapshot: (nodesJSON: string, edgesJSON: string) => void
  /** Pop from undo stack and push current onto redo stack */
  undo: () => CanvasSnapshot | null
  /** Pop from redo stack and push current onto undo stack */
  redo: () => CanvasSnapshot | null
  /** Clear all history (e.g. on save or load) */
  clear: () => void
}

export const useCanvasHistoryStore = create<CanvasHistoryState>((set, get) => ({
  past: [],
  future: [],

  pushSnapshot: (nodesJSON: string, edgesJSON: string) => {
    set((state) => ({
      past: [...state.past.slice(-49), { nodesJSON, edgesJSON }], // max 50 entries
      future: [],
    }))
  },

  undo: () => {
    const { past } = get()
    if (past.length === 0) return null
    const snapshot = past[past.length - 1]
    set((state) => ({
      past: state.past.slice(0, -1),
      future: [...state.future, snapshot],
    }))
    return snapshot
  },

  redo: () => {
    const { future } = get()
    if (future.length === 0) return null
    const snapshot = future[future.length - 1]
    set((state) => ({
      future: state.future.slice(0, -1),
      past: [...state.past, snapshot],
    }))
    return snapshot
  },

  clear: () => set({ past: [], future: [] }),
}))
