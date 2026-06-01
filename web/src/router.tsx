import { createBrowserRouter } from 'react-router-dom'
import { AuthProvider } from '@/auth/AuthProvider'
import { ProtectedRoute } from '@/auth/ProtectedRoute'
import OidcCallbackPage from '@/pages/OidcCallbackPage'
import { AppShell } from '@/components/layout/AppShell'
import { ErrorBoundary } from '@/components/layout/ErrorBoundary'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'
import InstanceDetailPage from '@/pages/instances/InstanceDetailPage'
import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import UsersPage from '@/pages/admin/UsersPage'
import GroupsPage from '@/pages/admin/GroupsPage'
import TokensPage from '@/pages/admin/TokensPage'
import AuditLogPage from '@/pages/admin/AuditLogPage'
import HealthDashboardPage from '@/pages/admin/HealthDashboardPage'
import MetricsPage from '@/pages/admin/MetricsPage'
import DlqPage from '@/pages/dlq/DlqPage'
import WebhooksPage from '@/pages/dlq/WebhooksPage'

export const router = createBrowserRouter([
  {
    path: '/auth/callback',
    element: (
      <AuthProvider>
        <OidcCallbackPage />
      </AuthProvider>
    ),
  },
  {
    path: '/',
    element: (
      <AuthProvider>
        <ProtectedRoute>
          <ErrorBoundary>
            <AppShell />
          </ErrorBoundary>
        </ProtectedRoute>
      </AuthProvider>
    ),
    children: [
      { index: true, element: <InstanceBoardPage /> },
      { path: 'definitions', element: <DefinitionListPage /> },
      { path: 'definitions/new', element: <DefinitionEditorPage /> },
      { path: 'definitions/:id', element: <DefinitionEditorPage /> },
      { path: 'instances', element: <InstanceBoardPage /> },
      { path: 'instances/:id', element: <InstanceDetailPage /> },
      { path: 'tasks', element: <TaskInboxPage /> },
      { path: 'admin/users', element: <UsersPage /> },
      { path: 'admin/users/:id', element: <UsersPage /> },
      { path: 'admin/groups', element: <GroupsPage /> },
      { path: 'admin/tokens', element: <TokensPage /> },
      { path: 'admin/audit', element: <AuditLogPage /> },
      { path: 'admin/health', element: <HealthDashboardPage /> },
      { path: 'admin/metrics', element: <MetricsPage /> },
      { path: 'dlq', element: <DlqPage /> },
      { path: 'webhooks', element: <WebhooksPage /> },
    ],
  },
])
