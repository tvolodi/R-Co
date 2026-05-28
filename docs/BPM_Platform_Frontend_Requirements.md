# BPM Platform — Frontend Functional Requirements Specification

**Version:** 0.1-draft · 2026-05-20  
**Backend reference:** BPM_Platform_Functional_Requirements.md v0.2-draft  
**Technology stack:** React 19 + TypeScript 5, Vite, React Router v7

---

## Introduction

This document specifies functional requirements for the BPM Platform web frontend — a single-page application that consumes the platform's REST API and provides role-appropriate interfaces for all four actor types: **PLATFORM_ADMIN**, **PROCESS_DESIGNER**, **PROCESS_OPERATOR**, and **TASK_WORKER**.

The frontend has no business logic of its own. All data mutations go through the platform REST API. The UI reflects the current state of the backend and provides tools to navigate it effectively.

**Priority notation:**

- **MUST** — mandatory for the area to be usable; no release without it.
- **SHOULD** — strongly recommended; defer only with documented reason.
- **COULD** — desirable if capacity allows.

---

## Glossary

| Term | Definition |
|---|---|
| **Workspace** | The authenticated user's top-level application shell, rendered after login |
| **Process Designer view** | The visual canvas for creating and editing process definition graphs |
| **Task Inbox** | A TASK_WORKER's personal queue of assigned and claimable tasks |
| **Instance Board** | An OPERATOR's view of all running, completed, and errored instances |
| **Control Panel** | PLATFORM_ADMIN views for users, groups, tokens, and system health |
| **Canvas** | The drag-and-drop area inside the Process Designer view |
| **Node palette** | The sidebar listing draggable node types in the Process Designer |

---

## Non-Functional Requirements (Frontend)

| ID | Requirement | Target |
|---|---|---|
| **FNFR-01** | **Initial load (LCP)** | Largest Contentful Paint ≤ 2.5 s on a 4G connection (Lighthouse score ≥ 90) |
| **FNFR-02** | **Interaction responsiveness** | UI interactions (navigation, filter changes) SHALL produce visible feedback within 100 ms |
| **FNFR-03** | **Accessibility** | All interactive elements SHALL meet WCAG 2.1 AA; keyboard navigation MUST be fully supported |
| **FNFR-04** | **Browser support** | Latest two stable versions of Chrome, Firefox, Safari, and Edge |
| **FNFR-05** | **Error resilience** | A failed API call SHALL never leave the UI in a broken or blank state; a recoverable error message with a retry action MUST be shown |
| **FNFR-06** | **Token storage** | The API token SHALL be stored in an `httpOnly` session cookie or memory only — never in `localStorage` or `sessionStorage` |
| **FNFR-07** | **Responsive layout** | All views SHALL be usable on viewports ≥ 1024 px wide; the Task Inbox SHALL additionally be usable on viewports ≥ 375 px (mobile) |

---

## Constraints & Assumptions

- The frontend communicates exclusively with the BPM Platform REST API — no direct database access, no other backends.
- Authentication is Bearer token–based (API-08). The frontend exchanges credentials (or a bootstrap token in development) for an API token via a login flow.
- The frontend is a static SPA deployed to a CDN or served by a simple file server; it has no server-side rendering requirement.
- Real-time updates (e.g. task inbox refresh) are achieved via polling unless the platform adds WebSocket/SSE support in a future stage.
- The visual process graph renderer/editor uses [React Flow](https://reactflow.dev) as the canvas library.
- All date/times are displayed in the user's browser locale and timezone; stored/transmitted values are UTC ISO 8601.

---

## Stage F1 — Application Shell & Authentication

**Goal:** A running web application with login, role-aware navigation, and an empty workspace per role. The foundation all other views build on.

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **SH-01** | **Login screen** | The application SHALL present a login screen with a token input field when no valid session exists. On submit, the token is validated against `GET /health/ready` (using the token). On success, the user's role set is decoded from the token context and the workspace is rendered. On failure, a clear error message is shown. | **MUST** |
| **SH-02** | **Session persistence** | The authenticated session SHALL persist across page reloads (stored in `httpOnly` cookie or in-memory with a silent re-auth flow). Expired or revoked tokens SHALL trigger an automatic redirect to the login screen with a session-expired message. | **MUST** |
| **SH-03** | **Role-aware navigation** | The global sidebar/navbar SHALL display only the navigation items the current user's role set permits. Items for areas outside the user's permissions SHALL be hidden entirely, not greyed out. | **MUST** |
| **SH-04** | **Active user indicator** | The shell SHALL display the current user's `display_name` and roles in the header. A logout action SHALL clear the session and return to the login screen. | **MUST** |
| **SH-05** | **Global error boundary** | An unhandled runtime error in any view SHALL be caught and render a recoverable error panel with a "reload this view" action, without crashing the entire application. | **MUST** |
| **SH-06** | **API connectivity banner** | If `GET /health/ready` returns non-200, the shell SHALL display a non-blocking banner: "Platform is currently unavailable — some actions may fail." The banner auto-dismisses when health recovers. | **SHOULD** |
| **SH-07** | **Keyboard shortcut map** | A discoverable keyboard shortcut (e.g. `?`) SHALL open an overlay listing all available keyboard shortcuts. | **COULD** |

---

## Stage F1.5 — OIDC SSO Login

**Goal:** Users can log in via Keycloak OIDC authorization code flow from the existing login screen without copy-pasting tokens. The developer token paste field is preserved unchanged.

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **OIDC-F-01** | **SSO login button** | The login screen SHALL display a "Sign in with Keycloak" button alongside the existing token input. Clicking it initiates the OIDC authorization code flow using `oidc-client-ts`. The provider URL is read from `VITE_OIDC_AUTHORITY` (default: `http://localhost:8081/realms/bpm-default`) and the client ID from `VITE_OIDC_CLIENT_ID` (default: `bpm-platform-api`). | **MUST** |
| **OIDC-F-02** | **OIDC callback handler** | The application SHALL include a `/auth/callback` route that receives the Keycloak redirect, exchanges the authorization code for tokens using `oidc-client-ts`, stores the access token in memory via the existing `setToken()` API, decodes display name and roles from the JWT, and redirects the user to the application workspace. Errors in the callback (invalid state, expired code) SHALL redirect to the login page with `?reason=auth-error`. `oidc-client-ts` MUST be initialised with `userStore: new InMemoryWebStorage()` so that its own internal state (ID token, refresh token, PKCE verifier) is also kept in memory only — never in `localStorage` or `sessionStorage` (FNFR-06). | **MUST** |
| **OIDC-F-03** | **Silent token renewal** | If the OIDC provider supports silent renew (`prompt=none` in a hidden iframe), the application SHOULD attempt to renew the access token before it expires, keeping the session alive without user interaction. If silent renew fails, the standard session-expired flow (SH-02) applies. | **SHOULD** |
| **OIDC-F-04** | **OIDC logout** | The logout action (SH-04) SHALL, when the session was established via OIDC, additionally call the Keycloak end-session endpoint to invalidate the SSO session. Internal token sessions (non-OIDC) use the existing logout path unchanged. | **SHOULD** |

---

## Stage F2 — Process Definition Management

**Goal:** PROCESS_DESIGNER and PLATFORM_ADMIN users can create, version, and manage process definitions through both a list view and a visual canvas editor.

### F2-A: Definition List View

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **PD-UI-01** | **Definition list** | The definitions view SHALL display a paginated, searchable table of all process definitions showing: name, latest version, status badge (DRAFT / ACTIVE / DEPRECATED / ARCHIVED), and creation date. | **MUST** |
| **PD-UI-02** | **Status filter** | The list SHALL support filtering by status (multi-select). The active filter SHALL be reflected in the URL query string and survive page reload. | **MUST** |
| **PD-UI-03** | **Version history** | Clicking a definition name SHALL expand an inline version history row showing all versions for that name, each with its status and a link to open that version. | **MUST** |
| **PD-UI-04** | **Create definition** | A "New Definition" button SHALL open a form modal for entering name, version string, and description. On submit, it calls `POST /definitions` and navigates to the Process Designer canvas for the new DRAFT. | **MUST** |
| **PD-UI-05** | **Lifecycle actions** | Each definition row SHALL surface contextual actions based on current status: DRAFT → [Edit, Activate, Delete]; ACTIVE → [View, Deprecate]; DEPRECATED → [View, Archive]; ARCHIVED → [View]. Actions unavailable for the current user's role SHALL be hidden. | **MUST** |
| **PD-UI-06** | **Activate confirmation** | Activating a definition that would deprecate an existing ACTIVE version SHALL show a confirmation dialog listing the version being deprecated before proceeding. | **MUST** |
| **PD-UI-07** | **Export / Import** | Each definition SHALL have an Export button that downloads the self-contained JSON document (PD-09). An Import button on the list view SHALL accept a JSON file and call the import endpoint. | **SHOULD** |
| **PD-UI-08** | **Full-text search** | The search bar SHALL query the definition search endpoint (PD-10) with a debounce of 300 ms. Results SHALL be highlighted. | **COULD** |

### F2-B: Process Designer Canvas

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **PD-UI-09** | **Visual graph canvas** | The canvas SHALL render the process definition graph using React Flow. Nodes are represented as labelled cards; directed edges are represented as arrows with optional condition labels. | **MUST** |
| **PD-UI-10** | **Node palette** | A sidebar palette SHALL list all supported node types: START, END, HUMAN_TASK, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY (and SERVICE_TASK, TIMER, SUB_PROCESS when supported). Nodes are added to the canvas by drag-and-drop or double-click. | **MUST** |
| **PD-UI-11** | **Edge creation** | The user SHALL connect two nodes by dragging from a source handle to a target handle. Edges from EXCLUSIVE_GATEWAY nodes SHALL prompt for a CEL condition expression or a "default edge" toggle on creation. | **MUST** |
| **PD-UI-12** | **Node properties panel** | Clicking a node SHALL open an inline properties panel where the user can set all required and optional attributes for that node type (e.g. `assignee_type`, `assignee_ref`, `form_schema`, `escalation_timer_duration` for HUMAN_TASK). | **MUST** |
| **PD-UI-13** | **Inline validation feedback** | The canvas SHALL run client-side graph validation (mirroring PD-02 rules) continuously and display inline error indicators on offending nodes/edges (e.g. a red border on an isolated node). A validation summary panel SHALL list all errors before save is allowed. | **MUST** |
| **PD-UI-14** | **Save** | A Save button SHALL call `PUT /definitions/:id` (full graph replacement for DRAFTs) and display a success toast or inline error. Unsaved changes SHALL be tracked; navigating away with unsaved changes triggers a confirmation dialog. | **MUST** |
| **PD-UI-15** | **Read-only mode** | Definitions with status ACTIVE, DEPRECATED, or ARCHIVED SHALL open in read-only mode. The canvas is non-interactive; node/edge details are still viewable. A banner communicates the read-only state. | **MUST** |
| **PD-UI-16** | **CEL expression editor** | Edge condition inputs on EXCLUSIVE_GATEWAY SHALL use a code editor field (Monaco or CodeMirror) with CEL syntax highlighting and basic bracket matching. Syntax errors from the server (PD-06) SHALL be surfaced inline below the field. | **SHOULD** |
| **PD-UI-17** | **Canvas minimap & zoom** | The canvas SHALL include a minimap for large graphs and zoom controls (fit-to-screen, zoom in/out). | **SHOULD** |
| **PD-UI-18** | **Auto-layout** | A "Re-layout" button SHALL apply an automatic DAG layout algorithm (e.g. Dagre) to arrange nodes cleanly. | **SHOULD** |
| **PD-UI-19** | **Undo / redo** | The canvas SHALL support undo/redo (Ctrl+Z / Ctrl+Y) for all canvas operations (add node, delete edge, move node, edit property). | **SHOULD** |

---

## Stage F3 — Instance Monitoring & Operations

**Goal:** PROCESS_OPERATOR and PLATFORM_ADMIN users can start, monitor, cancel, and inspect all process instances.

### F3-A: Instance Board

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **IN-UI-01** | **Instance list** | The instance board SHALL display a paginated table of instances with columns: instance ID (truncated), definition name + version, status badge, correlation key, start time, last updated. | **MUST** |
| **IN-UI-02** | **Status & definition filters** | The board SHALL support filtering by status (multi-select) and definition name (typeahead). Filters are URL-persisted. | **MUST** |
| **IN-UI-03** | **Start instance** | A "Start Instance" button SHALL open a form where the user selects a definition (by name, active version auto-selected), enters an optional correlation key, and provides an initial variables JSON object (with a JSON editor widget). | **MUST** |
| **IN-UI-04** | **Instance detail view** | Clicking an instance SHALL navigate to a detail page showing: current status, definition snapshot info, active tokens (highlighted on a read-only graph), current variable map, and active tasks. | **MUST** |
| **IN-UI-05** | **Event history tab** | The instance detail page SHALL include a History tab that calls `GET /instances/:id/history` and renders the ordered event log as a filterable table (filter by event type, time range). Raw JSON payload SHALL be expandable inline. | **MUST** |
| **IN-UI-06** | **Timeline tab** | The instance detail page SHALL include a Timeline tab calling `GET /instances/:id/timeline` and rendering events as a vertical chronological feed with actor avatars, timestamps, and human-readable descriptions. | **MUST** |
| **IN-UI-07** | **Cancel instance** | A Cancel button (operator+ role only) SHALL show a confirmation dialog and call `POST /instances/:id/cancel`. The UI SHALL update the status badge immediately (optimistic update with rollback on error). | **MUST** |
| **IN-UI-08** | **Auto-refresh** | The instance board and detail pages SHALL poll for updates every 10 seconds (configurable). An indicator SHALL show the last-refreshed time and a manual refresh button. | **SHOULD** |
| **IN-UI-09** | **Active token visualisation** | On the instance graph view (read-only canvas), nodes that currently hold an active execution token SHALL be visually highlighted (e.g. animated pulse ring). Completed nodes SHALL be styled differently from pending nodes. | **SHOULD** |

### F3-B: Point-in-time Inspection

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **IN-UI-10** | **History scrubber** | The History tab SHALL include a sequence-number scrubber that allows the operator to view the reconstructed instance state at any past event (calling `GET /instances/:id/history?to_seq=N`). The read-only canvas SHALL reflect the state at the selected point in time. | **SHOULD** |

---

## Stage F4 — Task Inbox

**Goal:** TASK_WORKER and PROCESS_OPERATOR users can view, claim, and complete tasks assigned to them or their groups/roles.

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **TK-UI-01** | **Task inbox** | The inbox SHALL show a list of tasks filterable by: My Tasks (assigned to me), My Group Tasks (assigned to a group I belong to), All Tasks (operator+). Columns: task name, instance ID, status, assignee, created time. | **MUST** |
| **TK-UI-02** | **Task detail panel** | Clicking a task SHALL open a side panel (or navigate to a detail page on mobile) showing: node name, instance context (definition name, instance ID, correlation key), current variables available to the task, and the form schema rendered as an interactive form. | **MUST** |
| **TK-UI-03** | **Dynamic form rendering** | If the task node defines a `form_schema` (JSON Schema), the task detail panel SHALL render a dynamic form with appropriate field types (text, number, boolean, date, select, etc.). Required fields are enforced client-side before submission. | **MUST** |
| **TK-UI-04** | **Complete task** | A "Complete" button SHALL collect the form field values as the output variables map and call `POST /tasks/:id/complete`. On success, the task is removed from the inbox and a success toast is shown. On server-side error (e.g. variable schema violation), the error is shown inline. | **MUST** |
| **TK-UI-05** | **Claim task** | For tasks assigned to a group or role (not yet personally assigned), a "Claim" button SHALL call `POST /tasks/:id/assign` with the current user's ID. Claimed tasks appear in "My Tasks". | **MUST** |
| **TK-UI-06** | **Reassign task** | Operators SHALL be able to reassign a task to another user, group, or role via `POST /tasks/:id/reassign`. The reassign action opens a user/group/role search dialog. | **MUST** |
| **TK-UI-07** | **Task sort & search** | The inbox SHALL support sorting by created time (asc/desc) and free-text search by task name or instance correlation key. | **SHOULD** |
| **TK-UI-08** | **Badge count** | The navigation item for Task Inbox SHALL display a live badge count of pending tasks assigned to the current user or their groups. The count polls every 30 seconds. | **SHOULD** |
| **TK-UI-09** | **Escalation indicator** | Tasks that have exceeded their `escalation_timer_duration` (status: escalated) SHALL show a visual indicator (e.g. amber warning icon) in the inbox list and on the task detail panel. | **SHOULD** |
| **TK-UI-10** | **Mobile task completion** | The task detail panel and complete flow SHALL be fully operable on a 375 px viewport (per FNFR-07). Form fields, the complete button, and error messages must not be clipped or require horizontal scrolling. | **MUST** |

---

## Stage F5 — Administration & Identity Management

**Goal:** PLATFORM_ADMIN users can manage users, groups, roles, and API tokens. System health and metrics are accessible.

### F5-A: User Management

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **ADM-UI-01** | **User list** | A paginated, searchable table of all users with columns: username, display name, email, roles, status badge, created date. | **MUST** |
| **ADM-UI-02** | **Create user** | A "New User" form collects username, display name, email, and initial role assignments. Calls `POST /users`. | **MUST** |
| **ADM-UI-03** | **Edit user** | Clicking a user opens a detail page for editing display name, email, status (ACTIVE/INACTIVE), group memberships, and role assignments. | **MUST** |
| **ADM-UI-04** | **Deactivate user** | A Deactivate action sets user status to INACTIVE. A confirmation dialog notes that active tasks assigned to the user will remain assigned but the user will be unable to complete them. | **MUST** |
| **ADM-UI-05** | **Group management** | A Groups sub-section lists all groups with their member counts. Admins can create groups, add/remove members, and delete empty groups. | **MUST** |

### F5-B: API Token Management

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **ADM-UI-06** | **Token list** | A table listing all API tokens: associated user, roles, expiry, created date, and revocation status. Token values are never shown in this view. | **MUST** |
| **ADM-UI-07** | **Issue token** | An "Issue Token" form collects target user, role set, and optional expiry date. After calling `POST /tokens`, the generated token value SHALL be shown exactly once in a modal with a copy-to-clipboard button and a clear "This value will not be shown again" warning. | **MUST** |
| **ADM-UI-08** | **Revoke token** | A Revoke action (with confirmation) calls the revoke endpoint. Revoked tokens are visually struck-through in the list. | **MUST** |

### F5-C: System Health & Observability

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **ADM-UI-09** | **Health dashboard** | A dashboard page SHALL display the results of `GET /health/ready` in a human-readable card layout: DB connectivity status, DB latency, scheduler status, and uptime. The page auto-refreshes every 15 seconds. | **MUST** |
| **ADM-UI-10** | **Metrics viewer** | An embedded Prometheus-style metrics page SHALL display the raw text from `GET /metrics`, formatted as a readable table grouped by metric family. | **SHOULD** |
| **ADM-UI-11** | **Audit log viewer** | A paginated, filterable (by actor, resource type, time range) view of the audit log. Each row expands to show the before/after state diff rendered as a JSON diff view. | **MUST** |

---

## Stage F6 — Dead Letter Queue & Alerting

**Goal:** Operators can inspect, retry, and discard DLQ items. Webhook subscriptions are manageable.

| ID | Requirement | Description | Priority |
|---|---|---|---|
| **DLQ-UI-01** | **DLQ list** | A paginated table of dead letter items with columns: source type badge, related instance (link), failure reason (truncated), retry count, created time, status. | **MUST** |
| **DLQ-UI-02** | **DLQ item detail** | Clicking a DLQ item opens a detail panel showing the full context JSON, full failure reason, retry history, and the source event/timer that failed. | **MUST** |
| **DLQ-UI-03** | **Retry action** | A "Retry" button calls `POST /dlq/:id/retry`. On success, the item transitions to RETRYING status and the UI updates. | **MUST** |
| **DLQ-UI-04** | **Discard action** | A "Discard" button (with confirmation) calls `POST /dlq/:id/discard`. If the item is tied to an instance, the confirmation dialog states that the instance will be cancelled. | **MUST** |
| **DLQ-UI-05** | **DLQ depth indicator** | The navigation badge for DLQ SHALL show the count of PENDING items. A count > 0 is shown in amber; a count exceeding the configured alert threshold is shown in red. | **SHOULD** |
| **WH-UI-01** | **Webhook subscription list** | A table of webhook subscriptions with columns: target URL, event filter tags, status (ACTIVE / PAUSED), created date. | **MUST** |
| **WH-UI-02** | **Create subscription** | A form for entering target URL, selecting event types (multi-select checkboxes from the known event type list), and generating an HMAC secret (auto-generated, shown once). | **MUST** |
| **WH-UI-03** | **Pause / resume subscription** | Paused subscriptions (after 5 consecutive delivery failures) SHALL be visually distinct. An operator can resume a paused subscription with one click. | **MUST** |
| **WH-UI-04** | **Delivery log** | Each subscription detail view SHALL show a log of recent delivery attempts with status (success / failed), response code, and timestamp. | **SHOULD** |

---

## Appendix A — Navigation Structure

```
Sidebar navigation (role-gated items hidden by role)
│
├── Task Inbox                          [TASK_WORKER, PROCESS_OPERATOR, PLATFORM_ADMIN]
│
├── Instances                           [PROCESS_OPERATOR, PLATFORM_ADMIN]
│   ├── All Instances (board)
│   └── [Instance Detail]
│
├── Definitions                         [PROCESS_DESIGNER, PROCESS_OPERATOR, PLATFORM_ADMIN]
│   ├── Definition List
│   └── [Definition Canvas / Detail]
│
├── Administration                      [PLATFORM_ADMIN only]
│   ├── Users
│   ├── Groups
│   ├── API Tokens
│   ├── Health Dashboard
│   ├── Audit Log
│   └── Metrics
│
└── Dead Letter Queue                   [PROCESS_OPERATOR, PLATFORM_ADMIN]
    ├── DLQ Items
    └── Webhook Subscriptions
```

---

## Appendix B — Requirement Count Summary

| Stage | MUST | SHOULD | COULD | Total |
|---|---|---|---|---|
| F1 — Shell & Auth | 5 | 1 | 1 | **7** |
| F2 — Definition Management | 9 (list) + 7 (canvas) = **16** | 5 | 2 | **23** |
| F3 — Instance Monitoring | 7 | 3 | 0 | **10** |
| F4 — Task Inbox | 7 | 3 | 0 | **10** |
| F5 — Admin & Identity | 9 | 2 | 0 | **11** |
| F6 — DLQ & Alerting | 7 | 3 | 0 | **10** |
| **Total** | **51** | **17** | **3** | **71** |

---

## Appendix C — API Mapping

| Frontend area | Primary backend endpoints consumed |
|---|---|
| Login / session | `GET /health/ready` (token validation probe) |
| Definition list | `GET /definitions`, `DELETE /definitions/:id`, `POST /definitions/:id/activate` |
| Definition canvas | `POST /definitions`, `GET /definitions/:id`, `PUT /definitions/:id` |
| Instance board | `GET /instances`, `POST /instances` |
| Instance detail | `GET /instances/:id`, `GET /instances/:id/history`, `GET /instances/:id/timeline`, `POST /instances/:id/cancel` |
| Task inbox | `GET /tasks`, `POST /tasks/:id/complete`, `POST /tasks/:id/assign`, `POST /tasks/:id/reassign` |
| User management | `GET /users`, `POST /users`, `PUT /users/:id` |
| Token management | `GET /tokens`, `POST /tokens`, `DELETE /tokens/:id` |
| Health dashboard | `GET /health/ready` |
| Metrics viewer | `GET /metrics` |
| Audit log | `GET /audit` |
| DLQ | `GET /dlq`, `POST /dlq/:id/retry`, `POST /dlq/:id/discard` |
| Webhooks | `GET /webhooks`, `POST /webhooks`, `PATCH /webhooks/:id` |
