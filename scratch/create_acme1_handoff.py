import json, uuid, os

run_id = 'ADHOC-acme1-onboarding-20260604'
os.makedirs('handoffs/' + run_id, exist_ok=True)

handoff_id = str(uuid.uuid4())
filename = 'handoffs/' + run_id + '/step-01-backend-dev.json'

desc = "\n".join([
    "Onboard the acme1 company tenant so that accessing acme1.localhost:5173 routes to its own Keycloak realm.",
    "",
    "ROOT CAUSE: The tenant_hostnames table is empty and no acme1 tenant has been onboarded.",
    "",
    "STEPS:",
    "1. Get admin token: POST http://localhost:8081/realms/bpm-default/protocol/openid-connect/token",
    "   grant_type=password, client_id=bpm-platform-api, username=admin-user, password=admin-pass",
    "",
    "   PowerShell:",
    "   $token = (Invoke-RestMethod -Uri 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token' -Method POST -Body @{grant_type='password';client_id='bpm-platform-api';username='admin-user';password='admin-pass'}).access_token",
    "",
    "2. Generate a new UUID for Idempotency-Key and call POST http://localhost:8080/api/v1/onboarding",
    "   with Authorization: Bearer $token, Content-Type: application/json, Idempotency-Key: <new-uuid>",
    "   Body:",
    '   {"slug":"acme1","display_name":"Acme1 Corp","admin_email":"admin@acme1.com","admin_username":"acme1-admin","admin_display_name":"Acme1 Admin","hostname":"acme1.localhost","client_config":{"redirect_uris":["http://acme1.localhost:5173/*","http://acme1.localhost/*","https://acme1.localhost/*"]}}',
    "",
    "   IMPORTANT: client_config.redirect_uris must include 'http://acme1.localhost:5173/*' so the Keycloak",
    "   client accepts the local dev callback URL. Default provisioning would create only 'https://acme1.localhost/*'",
    "   which does not match the http:// dev origin.",
    "",
    "3. Verify all four acceptance criteria below.",
])

handoff = {
    "handoff_id": handoff_id,
    "run_id": run_id,
    "step": "01",
    "from_agent": "ORCH",
    "to_agent": "BACKEND-DEV",
    "created_at": "2026-06-04T01:00:54Z",
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "ADHOC - Onboard acme1 tenant + fix dev redirect URIs",
        "requirement_ids": ["OIDC-F-05", "OIDC-F-06"],
        "related_handoff_ids": [],
        "artifacts_in": ["src/identity/onboarding.zig"]
    },
    "task": {
        "description": desc,
        "acceptance_criteria": [
            "GET /api/tenant-config?host=acme1.localhost returns oidc_authority with /realms/acme1 (not bpm-default)",
            "Keycloak has realm 'acme1' at http://localhost:8081",
            "SELECT * FROM tenant_hostnames shows row with hostname='acme1.localhost'",
            "Keycloak acme1 realm bpm-platform-api client has http://acme1.localhost:5173/* as allowed redirect URI"
        ],
        "functions_to_call": []
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 3,
    "started_at": None,
    "completed_at": None
}

with open(filename, 'w') as f:
    json.dump(handoff, f, indent=2)

with open('handoffs/registry.json') as f:
    registry = json.load(f)
registry['entries'].append({
    "handoff_id": handoff_id,
    "file": filename,
    "run_id": run_id,
    "workflow_id": "ADHOC",
    "step": "01",
    "from_agent": "ORCH",
    "to_agent": "BACKEND-DEV",
    "created_at": "2026-06-04T01:00:54Z",
    "status": "PENDING",
    "stage": "Onboard acme1 + fix dev redirect URIs"
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)

with open('handoffs/orchestrator.log', 'a') as f:
    f.write('2026-06-04T01:00:54Z | ROUTE | ' + run_id + ' | ' + handoff_id[:8] + ' | ORCH -> BACKEND-DEV | PENDING\n')

print('Handoff created: ' + filename)
print('ID: ' + handoff_id)
