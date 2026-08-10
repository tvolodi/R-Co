# BPM Platform R-Co (Robotized Company)

A business process management platform built with Zig (backend) and React/TypeScript (frontend).

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (for Keycloak + PostgreSQL)
- [Zig 0.16](https://ziglang.org/download/) (backend)
- [Node.js 20+](https://nodejs.org/) (frontend)

---

## Quick start

**Primary path (Windows/PowerShell):** this repo has a single command surface,
`make.ps1`, that wraps infrastructure startup, migrations, and test/e2e runs with a
real service-readiness wait instead of a "check that it's healthy" instruction. Run
`./make.ps1 help` for the full subcommand list. The steps below show both the
`make.ps1` form and the raw command it expands to, since a fresh checkout may not yet
have PowerShell execution policy configured.

### 1. Start infrastructure

```powershell
./make.ps1 up
```

`make.ps1 up` runs `docker compose up -d`, then polls each service's Docker health
status (reusing the healthchecks already defined in `docker-compose.yml`) up to 10
times before failing clearly — you do not need to separately check `docker compose ps`
by hand. Raw form, if you are not on PowerShell:

```bash
docker compose up -d
```

This starts:

| Service | URL | Credentials |
|---|---|---|
| Keycloak | http://localhost:8081 | admin / admin |
| PostgreSQL (dev) | localhost:5432 | bpm / bpm, db: bpm_dev |
| PostgreSQL (test) | localhost:5433 | bpm / bpm, db: bpm_test |

If you started the stack with the raw `docker compose` form, wait for it to be healthy
yourself (first startup imports the `bpm-default` realm automatically):

```bash
docker compose ps   # all services should show "healthy"
```

### 2. Run database migrations

```powershell
./make.ps1 migrate
```

`make.ps1 migrate` sources `BPM_DB_URL` from `.env` itself, so nothing needs to be
exported by hand. Raw form:

```bash
BPM_DB_URL=postgres://bpm:bpm@localhost:5432/bpm_dev zig build migrate
```

On Windows PowerShell without the wrapper:

```powershell
$env:BPM_DB_URL = "postgres://bpm:bpm@localhost:5432/bpm_dev"
zig build migrate
```

### 3. Start the backend

```powershell
$env:BPM_DB_URL = "postgres://bpm:bpm@localhost:5432/bpm_dev"
zig build run
```

The API server starts on **http://localhost:8080**.

### 4. Start the frontend

```bash
cd web
npm install
npm run dev
```

The web UI is available at **http://localhost:5173**.

---

## Logging in

The app uses **Keycloak OIDC** for authentication. When you open the web UI, you are automatically redirected to the Keycloak login page. Enter your credentials there, and you'll be redirected back to the app.

### Test accounts

| Username | Password | Role | Can do |
|---|---|---|---|
| `admin-user` | `admin-pass` | `PLATFORM_ADMIN` | Full access — all features |
| `designer-user` | `designer-pass` | `PROCESS_DESIGNER` | Create/edit process definitions |
| `worker-user` | `worker-pass` | `TASK_WORKER` | View and complete assigned tasks |

### How it works

1. Open **http://localhost:5173** in your browser.
2. The app detects no active session and redirects you to the Keycloak login page.
3. Enter any test account credentials from the table above.
4. Keycloak authenticates you and redirects back to the app.
5. You're now logged in and can use the app.

> **Session expiry**: Keycloak tokens expire after 5 minutes by default. If your session expires, the app automatically redirects you back to the Keycloak login page for re-authentication.

---

## Environment variables (backend)

See `.env.example` for the full, documented list (consuming file and unset-behaviour
for every variable). Summary of the required ones:

| Variable | Required | Default | Description |
|---|---|---|---|
| `BPM_DB_URL` | Yes | — | PostgreSQL connection string |
| `BPM_PORT` | No | `8080` | HTTP listen port |
| `BPM_IDP_PROVIDER_TYPE` | Yes | — | Identity provider backend (`keycloak` or `stub`) |
| `BPM_IDP_BASE_URL` | Yes | — | Keycloak base URL, e.g. `http://localhost:8081` |
| `BPM_IDP_ADMIN_CREDENTIALS_REF` | Yes | — | `env:<VAR>` pointer to the Keycloak secret var |
| `BPM_KEYCLOAK_SECRET` | Yes | — | Keycloak admin/client secret (matches `docker-compose.yml`) |
| `BPM_IDP_DEFAULT_REALM_OR_TENANT` | Yes | — | Default Keycloak realm, e.g. `bpm-default` |
| `BPM_API_URL` | Yes (UAT-RUNNER) | — | BPM API base URL used by UAT-RUNNER evidence collection |
| `BPM_UAT_TOKEN` | Yes (UAT-RUNNER) | — | Bearer token UAT-RUNNER uses against `BPM_API_URL` |
| `BPM_E2E_ADMIN_USERNAME` / `BPM_E2E_ADMIN_PASSWORD` | No | `admin-user` / `admin-pass` | Playwright E2E login credentials |

---

## Development commands

**Single command surface:** `./make.ps1 <command>` (PowerShell) wraps the commands
below with env vars sourced from `.env` and a real service-readiness wait where
relevant — run `./make.ps1 help` for the list. See
`src/design/unified-command-surface.md` for what each subcommand does and why.

| `make.ps1` command | Wraps | What it does |
|---|---|---|
| `./make.ps1 up` | `docker compose up -d` | Starts infrastructure, polls all services until healthy (up to 10x) |
| `./make.ps1 migrate` | `zig build migrate` | Applies pending migrations, `BPM_DB_URL` sourced from `.env` |
| `./make.ps1 test` | `zig build test` | Run all unit tests |
| `./make.ps1 test-live` | `zig build test-integration` | Waits for Postgres + Keycloak, then runs integration tests, `BPM_TEST_DB_URL` sourced from `.env` |
| `./make.ps1 e2e` | `cd web && npm run test:e2e` | Run E2E tests against a running stack |
| `./make.ps1 check` | `zig build check` | PI-03 gate (GH-293/ISS-0078): build (error sets fail via exit code) + `zig fmt --check` scoped to this branch's changed files |

Raw commands, if not on PowerShell or working outside `make.ps1`:

| Command | What it does |
|---|---|
| `zig build` | Compile only |
| `zig build run` | Compile and start server |
| `zig build test` | Run all unit tests |
| `zig build migrate` | Apply pending migrations |
| `zig build bench` | Run performance benchmarks |
| `cd web && npm run dev` | Start frontend dev server |
| `cd web && npm run type-check` | TypeScript type check |
| `cd web && npm run test` | Run frontend unit tests |
| `cd web && npx playwright test` | Run E2E tests (requires running backend + Keycloak) |

---

## Onboarding a new company tenant

The platform provides an onboarding API to provision new company tenants end-to-end. The endpoint creates a tenant, provisions a Keycloak realm, sets up an admin user and OIDC client, binds a custom hostname, and verifies readiness — all in a single idempotent call.

### `POST /api/v1/onboarding`

```bash
curl -s -X POST http://localhost:8080/api/v1/onboarding \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H "Authorization: Bearer <admin-token>" \
  -d '{
    "slug": "acme-corp",
    "display_name": "Acme Corp",
    "admin_email": "admin@acme.com",
    "admin_username": "admin",
    "hostname": "bpm.acme.com"
  }' | python3 -m json.tool
```

Response (201 Created):
```json
{
  "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
  "tenant_id": "550e8400-e29b-41d4-a716-446655440001",
  "idp_realm_id": "acme-corp",
  "client_id": "bpm-platform-api",
  "admin_user_id": "550e8400-e29b-41d4-a716-446655440002",
  "hostname": "bpm.acme.com",
  "oidc_authority": "http://keycloak:8081/realms/acme-corp",
  "discovery_url": "http://keycloak:8081/realms/acme-corp/.well-known/openid-configuration",
  "created": true
}
```

On idempotent replay (same `Idempotency-Key`): returns 200 with `"created": false`.

See `src/design/oidc35-onboarding.md` for full request/response schemas and the data flow diagram.

---

## Keycloak admin console

Manage users, roles, and clients at http://localhost:8081 — log in with **admin / admin**, then select the `bpm-default` realm.
