/** BPM Platform — shared TypeScript types mirroring backend response shapes */

// ── API infrastructure ─────────────────────────────────────────────────────────

/** RFC 9457 Problem Details error shape */
export interface ApiError {
  status: number
  message: string
  code: string
  details?: Record<string, unknown>
}

/** Cursor-paginated list response (API-13) */
export interface CursorPage<T> {
  items: T[]
  next_cursor: string | null
  has_more: boolean
}

/** Offset-paginated list response for admin endpoints */
export interface PagedResponse<T> {
  items: T[]
  total: number
  page: number
  page_size: number
}

// ── Process Definitions (Stage 2) ─────────────────────────────────────────────

export type DefinitionStatus = 'DRAFT' | 'ACTIVE' | 'DEPRECATED' | 'ARCHIVED'
export type NodeType = 'START' | 'END' | 'HUMAN_TASK' | 'EXCLUSIVE_GATEWAY' | 'PARALLEL_GATEWAY' | 'SERVICE_TASK' | 'TIMER' | 'SUB_PROCESS'

export interface GraphNode {
  id: string
  type: NodeType
  name?: string
  attributes?: Record<string, unknown>
}

export interface GraphEdge {
  id: string
  source: string
  target: string
  condition?: string    // CEL expression for EXCLUSIVE_GATEWAY outgoing edges
  is_default?: boolean
}

export interface DefinitionGraph {
  nodes: GraphNode[]
  edges: GraphEdge[]
}

export interface ProcessDefinition {
  id: string
  name: string
  version: string
  description?: string
  status: DefinitionStatus
  graph: DefinitionGraph
  created_by: string
  created_at: string
  updated_at: string
}

export interface CreateDefinitionRequest {
  name: string
  version: string
  description?: string
  graph: DefinitionGraph
}

// ── Process Instances (Stage 3) ───────────────────────────────────────────────

export type InstanceStatus = 'ACTIVE' | 'COMPLETED' | 'CANCELLED' | 'ERROR'

export interface ProcessInstance {
  instance_id: string
  definition_id: string
  definition_name: string
  definition_version: string
  correlation_key?: string
  status: InstanceStatus
  current_nodes: string[]
  variables: Record<string, unknown>
  error_detail?: Record<string, unknown>
  started_at: string
  completed_at?: string
  cancelled_at?: string
}

export interface StartInstanceRequest {
  definition_id?: string
  definition_name?: string
  definition_version?: string
  correlation_key?: string
  variables?: Record<string, unknown>
}

// ── Tasks (Stage 3) ───────────────────────────────────────────────────────────

export type TaskStatus = 'PENDING' | 'COMPLETED' | 'CANCELLED'

export interface Task {
  id: string
  instance_id: string
  token_id: string
  node_id: string
  node_name: string
  status: TaskStatus
  assignee_type?: string
  assignee_ref?: string
  form_schema?: Record<string, unknown>
  output_variables?: Record<string, unknown>
  completed_by?: string
  completed_at?: string
  created_at: string
}

export interface CompleteTaskRequest {
  output_variables?: Record<string, unknown>
}

// ── Events (Stage 1) ──────────────────────────────────────────────────────────

export interface EventRecord {
  event_id: string
  instance_id: string
  event_type: string
  payload: Record<string, unknown>
  actor_id: string
  sequence_number: number
  global_seq: number
  idempotency_key: string
  metadata: Record<string, string>
  created_at: string
}

export interface TimelineEntry {
  event_type: string
  timestamp: string
  actor_display_name: string
  description: string
  instance_id: string
  event_id: string
  sequence_num: number
  task_id: string | null
  node_id: string | null
  metadata: Record<string, unknown>
}

export interface TimelinePage {
  items: TimelineEntry[]
  next_cursor: string | null
  count: number
}

export interface AppendEventRequest {
  instance_id: string
  event_type: string
  payload: Record<string, unknown>
  actor_id: string
  idempotency_key: string
  metadata?: Record<string, string>
}

// ── Identity (Stage 4/5) ──────────────────────────────────────────────────────

// ── Auth (Stage F1) ───────────────────────────────────────────────────────────

export interface JwtPayload {
  sub: string
  display_name?: string
  name?: string
  preferred_username?: string
  roles: string[]
  exp?: number
  iat?: number
  iss?: string
}

export interface UserSession {
  token: string
  display_name: string
  roles: string[]
}

export interface User {
  id: string
  email: string
  display_name: string
  is_active: boolean
  roles: string[]
  last_login_at?: string
  created_at: string
}

export interface Group {
  id: string
  name: string
  display_name: string
  description?: string
  is_system: boolean
  member_count?: number
}

export interface Role {
  id: string
  name: string
  description?: string
  is_system: boolean
  permissions: RolePermission[]
}

export interface RolePermission {
  id: string
  resource: string
  action: string
}

export interface ApiToken {
  id: string
  name: string
  last_used_at?: string
  expires_at?: string
  revoked_at?: string
  created_at: string
}

// ── DLQ (Stage 3) ─────────────────────────────────────────────────────────────

export type DlqStatus = 'pending' | 'retrying' | 'resolved' | 'discarded'

export interface DlqEntry {
  id: string
  entry_type: string
  instance_id?: string
  reference_id?: string
  reason: string
  error_detail?: Record<string, unknown>
  retry_count: number
  max_retries: number
  next_retry_at?: string
  status: DlqStatus
  created_at: string
}

// ── Webhooks (Stage 5) ────────────────────────────────────────────────────────

export interface WebhookSubscription {
  id: string
  owner_id: string
  url: string
  description?: string
  event_types?: string[]
  is_active: boolean
  created_at: string
}

// ── Audit Log ─────────────────────────────────────────────────────────────────

export interface AuditEntry {
  id: string
  actor_id?: string
  actor_email?: string
  action: string
  entity_type?: string
  entity_id?: string
  entity_name?: string
  ip_address?: string
  trace_id?: string
  detail?: Record<string, unknown>
  occurred_at: string
}

// ── Health ────────────────────────────────────────────────────────────────────

export interface ComponentStatus {
  status: string
  latency_ms?: number
}

export interface HealthStatus {
  status: 'ok' | 'degraded' | 'down'
  db_latency_ms: number
  uptime_seconds: number
  version: string
  components: Record<string, ComponentStatus>
}
