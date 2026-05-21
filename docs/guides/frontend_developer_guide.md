# BPM Platform — Frontend Developer Guide

**Version:** 0.1 · 2026-05-20  
**Agent ID:** `FRONTEND-DEV`  
**Audience:** Frontend Developer agent, Code Designer agent

---

## 1. Environment Setup

### Required tools
- Node.js 22 LTS
- npm 10+

### Install dependencies
```bash
cd web
npm install
```

### Environment variables (`web/.env.local`)

| Variable | Default | Purpose |
|---|---|---|
| `VITE_API_BASE_URL` | `http://localhost:8080` | BPM Platform API base URL |
| `VITE_POLL_INTERVAL_MS` | `10000` | Instance/task inbox polling interval |
| `VITE_TASK_BADGE_INTERVAL_MS` | `30000` | Task badge count poll interval |

### Development server
```bash
cd web && npm run dev
```

---

## 2. Project Structure

```
web/
├── index.html
├── vite.config.ts
├── tsconfig.json
├── package.json
└── src/
    ├── main.tsx                    # React root, router setup, query client
    ├── router.tsx                  # React Router v7 route definitions
    ├── api/
    │   ├── client.ts               # Axios/Fetch base client; token injection; error normalisation
    │   ├── definitions.ts          # API calls for /definitions
    │   ├── instances.ts            # API calls for /instances
    │   ├── tasks.ts                # API calls for /tasks
    │   ├── identity.ts             # API calls for /users, /groups, /tokens
    │   ├── dlq.ts                  # API calls for /dlq
    │   ├── webhooks.ts             # API calls for /webhooks
    │   └── health.ts               # API calls for /health
    ├── auth/
    │   ├── AuthProvider.tsx        # Context provider: session state
    │   ├── useAuth.ts              # Hook: access current user + roles
    │   └── ProtectedRoute.tsx      # Route wrapper: redirect to /login if unauthenticated
    ├── components/
    │   ├── ui/                     # Design system primitives (see design_system.md)
    │   │   ├── Badge.tsx
    │   │   ├── Button.tsx
    │   │   ├── Card.tsx
    │   │   ├── DataTable.tsx
    │   │   ├── Dialog.tsx
    │   │   ├── Form/               # Field, Input, Select, Textarea, JsonEditor
    │   │   ├── StatusBadge.tsx
    │   │   ├── Toast.tsx
    │   │   └── ...
    │   ├── layout/
    │   │   ├── AppShell.tsx        # Sidebar + header wrapper
    │   │   ├── Sidebar.tsx         # Role-gated nav items
    │   │   └── ErrorBoundary.tsx
    │   ├── canvas/
    │   │   ├── ProcessCanvas.tsx   # React Flow wrapper
    │   │   ├── NodePalette.tsx
    │   │   ├── nodes/              # Custom node components per type
    │   │   │   ├── StartNode.tsx
    │   │   │   ├── EndNode.tsx
    │   │   │   ├── HumanTaskNode.tsx
    │   │   │   ├── ExclusiveGatewayNode.tsx
    │   │   │   └── ParallelGatewayNode.tsx
    │   │   └── edges/
    │   │       └── ConditionEdge.tsx
    │   └── forms/
    │       └── DynamicForm.tsx     # JSON Schema → form fields renderer
    ├── pages/
    │   ├── LoginPage.tsx
    │   ├── definitions/
    │   │   ├── DefinitionListPage.tsx
    │   │   └── DefinitionEditorPage.tsx
    │   ├── instances/
    │   │   ├── InstanceBoardPage.tsx
    │   │   └── InstanceDetailPage.tsx
    │   ├── tasks/
    │   │   └── TaskInboxPage.tsx
    │   ├── admin/
    │   │   ├── UsersPage.tsx
    │   │   ├── GroupsPage.tsx
    │   │   ├── TokensPage.tsx
    │   │   ├── HealthDashboardPage.tsx
    │   │   ├── AuditLogPage.tsx
    │   │   └── MetricsPage.tsx
    │   └── dlq/
    │       ├── DlqPage.tsx
    │       └── WebhooksPage.tsx
    ├── hooks/
    │   ├── useDefinitions.ts       # TanStack Query hooks for definitions API
    │   ├── useInstances.ts
    │   ├── useTasks.ts
    │   ├── usePolling.ts           # Generic polling hook with visibility-awareness
    │   └── usePagination.ts        # Cursor pagination state management
    ├── stores/
    │   └── canvasHistoryStore.ts   # Zustand store for undo/redo canvas state
    ├── types/
    │   └── api.ts                  # TypeScript types mirroring backend response shapes
    └── utils/
        ├── dates.ts                # UTC ↔ local display helpers
        ├── cursors.ts              # base64 cursor helpers
        └── rfcError.ts             # RFC 9457 Problem Details parser
```

---

## 3. API Client Pattern

All API calls go through `src/api/client.ts`. Never use `fetch` or `axios` directly in components or hooks.

### client.ts responsibilities
1. Inject `Authorization: Bearer <token>` header on every request
2. On 401 response: clear session and redirect to `/login`
3. On 429 response: surface `Retry-After` value to the caller
4. Normalise all error responses to a typed `ApiError` (parsed from RFC 9457)
5. Apply `VITE_API_BASE_URL` as the base URL

```typescript
// Example API module pattern (src/api/instances.ts)
import { client } from './client'
import type { Instance, StartInstanceRequest, PaginatedResponse } from '../types/api'

export const instancesApi = {
  list: (params: { status?: string; cursor?: string; pageSize?: number }) =>
    client.get<PaginatedResponse<Instance>>('/instances', { params }),

  get: (id: string) =>
    client.get<Instance>(`/instances/${id}`),

  start: (body: StartInstanceRequest) =>
    client.post<Instance>('/instances', body),

  cancel: (id: string) =>
    client.post<void>(`/instances/${id}/cancel`),
}
```

---

## 4. Server State Management

Use **TanStack Query (React Query v5)** for all server state. Do not use `useState` + `useEffect` for data fetching.

```typescript
// hooks/useInstances.ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { instancesApi } from '../api/instances'

export const instanceKeys = {
  all: ['instances'] as const,
  list: (filters: object) => [...instanceKeys.all, 'list', filters] as const,
  detail: (id: string) => [...instanceKeys.all, 'detail', id] as const,
}

export function useInstances(filters: object) {
  return useQuery({
    queryKey: instanceKeys.list(filters),
    queryFn: () => instancesApi.list(filters),
  })
}

export function useCancelInstance() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => instancesApi.cancel(id),
    onMutate: async (id) => {
      // Optimistic update
      await queryClient.cancelQueries({ queryKey: instanceKeys.detail(id) })
      const previous = queryClient.getQueryData(instanceKeys.detail(id))
      queryClient.setQueryData(instanceKeys.detail(id), (old: Instance) => ({
        ...old, status: 'CANCELLED',
      }))
      return { previous }
    },
    onError: (_err, id, context) => {
      // Rollback on error
      queryClient.setQueryData(instanceKeys.detail(id), context?.previous)
    },
    onSettled: (_, __, id) => {
      queryClient.invalidateQueries({ queryKey: instanceKeys.detail(id) })
    },
  })
}
```

---

## 5. Form Pattern

Use **React Hook Form** with **Zod** schemas for all forms.

```typescript
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'

const startInstanceSchema = z.object({
  definitionId: z.string().uuid(),
  correlationKey: z.string().optional(),
  variables: z.record(z.unknown()).default({}),
})

type StartInstanceForm = z.infer<typeof startInstanceSchema>

export function StartInstanceDialog() {
  const form = useForm<StartInstanceForm>({ resolver: zodResolver(startInstanceSchema) })

  const mutation = useStartInstance()

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(data => mutation.mutate(data))}>
        {/* fields */}
      </form>
    </Form>
  )
}
```

---

## 6. Role-Gated UI Pattern

Never disable or grey out items the user cannot access — hide them entirely.

```typescript
// auth/useAuth.ts
export function useHasRole(role: BpmRole | BpmRole[]): boolean {
  const { user } = useAuth()
  const required = Array.isArray(role) ? role : [role]
  return required.some(r => user?.roles.includes(r))
}

// Usage in component
function Sidebar() {
  const canManageUsers = useHasRole('PLATFORM_ADMIN')
  return (
    <nav>
      <NavItem to="/tasks" label="Task Inbox" />
      {canManageUsers && <NavItem to="/admin/users" label="Users" />}
    </nav>
  )
}
```

---

## 7. Polling Pattern

```typescript
// hooks/usePolling.ts
export function usePolling(callback: () => void, intervalMs: number) {
  useEffect(() => {
    // Do not poll when tab is hidden (Page Visibility API)
    const tick = () => { if (!document.hidden) callback() }
    const id = setInterval(tick, intervalMs)
    return () => clearInterval(id)
  }, [callback, intervalMs])
}
```

---

## 8. Pagination Pattern

All list API calls use cursor-based pagination. The `usePagination` hook manages cursor state:

```typescript
// hooks/usePagination.ts
export function usePagination(pageSize = 50) {
  const [cursors, setCursors] = useState<string[]>([])  // stack of cursors
  const currentCursor = cursors[cursors.length - 1]

  return {
    cursor: currentCursor,
    pageSize,
    hasNext: (nextCursor: string | null) => nextCursor !== null,
    goNext: (nextCursor: string) => setCursors(prev => [...prev, nextCursor]),
    goPrev: () => setCursors(prev => prev.slice(0, -1)),
    reset: () => setCursors([]),
  }
}
```

---

## 9. Canvas (React Flow) Pattern

### Node registration

All custom node types MUST be registered in `ProcessCanvas.tsx` in the `nodeTypes` map. Never pass inline objects — this causes React Flow re-renders.

```typescript
// Defined OUTSIDE the component
const nodeTypes: NodeTypes = {
  START: StartNode,
  END: EndNode,
  HUMAN_TASK: HumanTaskNode,
  EXCLUSIVE_GATEWAY: ExclusiveGatewayNode,
  PARALLEL_GATEWAY: ParallelGatewayNode,
}
```

### Read-only mode

Pass `nodesDraggable={false}` `nodesConnectable={false}` `elementsSelectable={false}` to `<ReactFlow>` for non-DRAFT definitions.

### Undo/redo

Use Zustand (`canvasHistoryStore.ts`) with a past/future stack. Snapshot the full `{nodes, edges}` state on every change. `Ctrl+Z` pops from past; `Ctrl+Y` pops from future.

---

## 10. Accessibility Rules

- Every interactive element must have a visible focus ring (use CSS `:focus-visible`)
- `<img>` must have `alt` text; decorative images use `alt=""`
- Form fields must have an associated `<label>` (via `htmlFor` or `aria-labelledby`)
- Error messages must be linked to their field via `aria-describedby`
- Dynamic content updates (toasts, badges) must use `aria-live` regions
- Color alone must never be the sole indicator of state (always pair with text or icon)

---

## 11. Build Commands Reference

| Command | Purpose |
|---|---|
| `npm run dev` | Start Vite dev server |
| `npm run build` | Production build |
| `npm run preview` | Preview production build locally |
| `npx tsc --noEmit` | TypeScript type check |
| `npm run lint` | ESLint check |
| `npm run test` | Run Vitest unit tests |
| `npm run test:coverage` | Run tests with coverage report |
| `npx playwright test` | Run E2E tests (requires running stack) |
