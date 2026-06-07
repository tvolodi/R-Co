import { expect, test, type APIRequestContext } from '@playwright/test'
import {
  getKeycloakToken,
  keycloakTokenUrl,
  resolveTenantContext,
} from './pipeline'

function decodeJwtPayload(token: string): { iss?: string } {
  const payload = token.split('.')[1]
  return JSON.parse(Buffer.from(payload, 'base64url').toString('utf-8')) as { iss?: string }
}

async function requireBackendReady(request: APIRequestContext): Promise<void> {
  const apiBaseUrl = (process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080').replace(/\/$/, '')
  const response = await request.get(`${apiBaseUrl}/health/ready`)
  if (!response.ok()) {
    throw new Error(`Backend readiness check failed (${response.status()}) at ${apiBaseUrl}/health/ready`)
  }
}

async function requireIdpReady(request: APIRequestContext): Promise<void> {
  const idpBaseUrl = (process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081').replace(/\/$/, '')
  const response = await request.get(`${idpBaseUrl}/health/ready`)
  if (!response.ok()) {
    throw new Error(`IdP readiness check failed (${response.status()}) at ${idpBaseUrl}/health/ready`)
  }
}

test.describe('UAT tenant URL helper coverage (UAT-TM-01..04)', () => {
  test('TC-UAT-TM-01-01: resolveTenantContext returns tenant context and uses in-process cache', async ({ request }) => {
    await requireBackendReady(request)
    await requireIdpReady(request)

    const adminToken = await getKeycloakToken(request)
    const first = await resolveTenantContext(request, 'swiftroute', adminToken)
    const second = await resolveTenantContext(request, 'swiftroute', adminToken)

    expect(first.tenantId.length).toBeGreaterThan(0)
    expect(first.slug).toBe('swiftroute')
    expect(first.realm.length).toBeGreaterThan(0)
    expect(first.tokenUrl).toBe(keycloakTokenUrl(first.realm))

    // Cache behavior: same slug returns same object reference from map cache.
    expect(second).toBe(first)
  })

  test('TC-UAT-TM-01-02: resolveTenantContext reports not found for unknown tenant slug', async ({ request }) => {
    await requireBackendReady(request)
    await requireIdpReady(request)

    const adminToken = await getKeycloakToken(request)
    const missingSlug = 'tenant-missing-for-uat-tm'

    await expect(resolveTenantContext(request, missingSlug, adminToken)).rejects.toThrow(
      `Tenant not found: ${missingSlug}`,
    )
  })

  test('TC-UAT-TM-02-01: keycloakTokenUrl builds default and custom realm URLs', async () => {
    expect(keycloakTokenUrl()).toContain('/realms/bpm-default/protocol/openid-connect/token')
    expect(keycloakTokenUrl('swiftroute')).toContain('/realms/swiftroute/protocol/openid-connect/token')
  })

  test('TC-UAT-TM-02-02: getKeycloakToken reaches non-default realm endpoint and returns realm-auth semantics', async ({ request }) => {
    await requireBackendReady(request)
    await requireIdpReady(request)

    const defaultRealmToken = await getKeycloakToken(request)
    await expect(getKeycloakToken(request, 'admin-user', 'admin-pass', 'swiftroute')).rejects.toThrow(
      /Keycloak token request failed \(401\):.*invalid_grant/i,
    )

    const defaultPayload = decodeJwtPayload(defaultRealmToken)
    expect(defaultPayload.iss).toContain('/realms/bpm-default')

    // Distinguish known realm auth failure from unknown realm path failure.
    await expect(getKeycloakToken(request, 'admin-user', 'admin-pass', 'realm-does-not-exist')).rejects.toThrow(
      /Keycloak token request failed \(404\):/i,
    )
  })

  test('TC-UAT-TM-03-01: tenant context can be pre-resolved for scenario company_id values before execution', async ({ request }) => {
    await requireBackendReady(request)
    await requireIdpReady(request)

    const adminToken = await getKeycloakToken(request)
    const companyIds = ['swiftroute', 'swiftroute']
    const uniqueCompanyIds = [...new Set(companyIds)]

    const contexts = new Map<string, Awaited<ReturnType<typeof resolveTenantContext>>>()
    for (const slug of uniqueCompanyIds) {
      contexts.set(slug, await resolveTenantContext(request, slug, adminToken))
    }

    expect(contexts.size).toBe(1)
    const swiftroute = contexts.get('swiftroute')
    expect(swiftroute).toBeDefined()
    expect(swiftroute?.slug).toBe('swiftroute')
    expect(swiftroute?.tenantId.length ?? 0).toBeGreaterThan(0)
  })

  test('TC-UAT-TM-04-01: company_id alone resolves tenant realm and derived token URL chain', async ({ request }) => {
    await requireBackendReady(request)
    await requireIdpReady(request)

    const adminToken = await getKeycloakToken(request)
    const tenant = await resolveTenantContext(request, 'swiftroute', adminToken)

    expect(tenant.slug).toBe('swiftroute')
    expect(tenant.realm.length).toBeGreaterThan(0)
    expect(tenant.tokenUrl).toBe(keycloakTokenUrl(tenant.realm))
    expect(tenant.tokenUrl).toContain(`/realms/${tenant.realm}/protocol/openid-connect/token`)
  })
})
