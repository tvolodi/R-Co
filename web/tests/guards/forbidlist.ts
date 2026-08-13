// GRD-UI-01: Single source of truth for all banned patterns.
// No other file under web/tests/guards/ may define RegExp literals.

type Applicability = 'source' | 'bundle' | 'both'

interface GuardPattern {
  /** Unique kebab-case identifier used in violation reports and fixture file names. */
  name: string
  /** The regular expression applied to file content. No regex literals appear outside this file. */
  regex: RegExp
  /** Which scan phases apply this pattern. */
  appliesTo: Applicability
  /**
   * Workspace-relative paths excluded from enforcement.
   * Compared with String.startsWith against the normalised forward-slash file path.
   */
  allowedPaths: string[]
  /** Directive ID or requirement ID that this pattern defends. Must be non-empty. */
  rationale: string
}

export type { GuardPattern, Applicability }

export const PATTERNS: GuardPattern[] = [
  {
    name: 'msw-import',
    regex: /import\s+\S.*from\s+['"]msw(?:\/[a-z]+)?['"]|setupServer\b/,
    appliesTo: 'both',
    allowedPaths: [],
    rationale: 'DIRECTIVE T-2',
  },
  {
    name: 'http-mock-adapter',
    regex: /import\s+\S.*from\s+['"]axios-mock-adapter['"]|new\s+MockAdapter\b/,
    appliesTo: 'both',
    allowedPaths: [],
    rationale: 'DIRECTIVE T-2',
  },
  {
    name: 'raw-fetch-outside-client',
    regex: /\bfetch\(|\baxios\(/,
    appliesTo: 'source',
    allowedPaths: ['web/src/api/client.ts'],
    rationale: 'CMP-UI-02',
  },
  {
    // Catches unquoted CSS colour literals: hex or rgba()/hsl() followed by `;` on same line.
    // JS inline-style strings end with `'` not `;` so they don't match.
    // Vite bundles CSS to separate .css files; raw hex in JS only appears in app code.
    // `[^)]+` (one-or-more) prevents matching zero-arg `rgb()` method calls from color libs.
    name: 'literal-colour',
    regex: /#[0-9a-fA-F]{3,8}\b(?=[^'";\n]*;)|(?<![.a-zA-Z0-9_$])rgba?\([^)]+\)(?=[^'";\n]*;)|(?<![.a-zA-Z0-9_$])hsla?\([^)]+\)(?=[^'";\n]*;)/,
    appliesTo: 'both',
    allowedPaths: ['web/src/styles/tokens.css'],
    rationale: 'CMP-UI-06',
  },
  {
    name: 'native-confirm',
    regex: /window\.(confirm|alert|prompt)\(/,
    appliesTo: 'source',
    // PropertyPanel.tsx uses window.confirm — tracked as existing exception
    allowedPaths: ['web/src/components/canvas/PropertyPanel.tsx'],
    rationale: 'CMP-UI-02',
  },
  {
    name: 'tenant-slug-in-source',
    // Matches hard-coded tenant slug string literals (known slugs for this platform)
    regex: /['"](?:swiftroute|vortex(?:-mfg|-manufacturing)?|meridian(?:-capital)?|acme(?:-test|-prod)?)\b/,
    appliesTo: 'source',
    // Test fixtures legitimately use tenant slugs — exempted by directory
    allowedPaths: [
      'web/src/auth/buildRedirectArgs.test.ts',
      'web/src/auth/tenantConfig.test.ts',
      'web/src/components/layout/__tests__/',
      'web/src/pages/admin/tenants/__tests__/',
      'web/src/pages/definitions/__tests__/',
      'web/src/pages/instances/__tests__/',
    ],
    rationale: 'CAC-UI-01',
  },
  {
    name: 'inline-query-key',
    regex: /queryKey\s*:\s*\[/,
    appliesTo: 'source',
    allowedPaths: ['web/src/api/queryKeys.ts'],
    rationale: 'CAC-UI-01',
  },
  {
    name: 'inline-stale-time',
    regex: /staleTime\s*:\s*\d/,
    appliesTo: 'source',
    // main.tsx sets global default staleTime in QueryClient config — legitimate
    allowedPaths: ['web/src/api/queryKeys.ts', 'web/src/main.tsx'],
    rationale: 'CAC-UI-01',
  },
  {
    // Matches files that call useQuery() without importing a query-state boundary.
    // Apply to whole-file content: the ^ anchor + negative lookahead spans multiple lines.
    name: 'missing-query-state-boundary',
    regex: /^(?![\s\S]*(?:QueryStateBoundary|ErrorBoundary|Suspense))[\s\S]*useQuery\(/,
    appliesTo: 'source',
    // Custom hooks return query results for callers to wrap; the named components here are
    // layout/panel components that handle their own loading states inline.
    allowedPaths: [
      'web/src/hooks/',
      'web/src/components/layout/AppShell.tsx',
      'web/src/components/webhooks/WebhookSubscriptionDetailPanel.tsx',
    ],
    rationale: 'GRD-UI-02',
  },
  {
    name: 'test-only-or-skip',
    regex: /\bit\.only\s*\(|\btest\.only\s*\(|\bdescribe\.only\s*\(|\bit\.skip\s*\(|\btest\.skip\s*\(/,
    appliesTo: 'source',
    allowedPaths: [],
    rationale: 'DIRECTIVE T-1',
  },
]
