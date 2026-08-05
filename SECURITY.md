# Security Policy

## Reporting a vulnerability

Please report security issues privately via [GitHub Security Advisories](https://github.com/tvolodi/R-Co/security/advisories/new) rather than opening a public issue.

## About the credentials in this repository

This repository contains credential-shaped strings. **All of them are local development fixtures**, verified during the 2026-08-05 pre-publication audit. None grants access to any real system.

| Value | Where | What it is |
|---|---|---|
| `admin-user` / `admin-pass`, `task-worker-pass` | integration + E2E tests | Accounts created by the local Keycloak dev realm on first start |
| `BPM_KEYCLOAK_SECRET=admin` | `.env.example`, dev scripts | The local Keycloak container's dev password |
| `postgres://bpm:bpm@localhost:5432/…` | `.env.example`, tests | The `docker-compose.yml` Postgres containers, bound to localhost |
| `super-secret`, `admin-token` | `src/identity/provider/test_oidc02_keycloak_adapter.zig` | Test doubles for the adapter's secret resolver |
| `eyJhbGciOiJub25lIn0.…` | `tests/unit/test_*.zig` | An unsigned `{"alg":"none"}` JWT — a standard parser fixture, not a valid token |
| `BPM_BOOTSTRAP_TOKEN=change-me-in-production` | `.env.example` | Placeholder; the name is the instruction |

These exist because **DIRECTIVE T-1/T-2 forbid mocks**: every integration and E2E test runs against a real PostgreSQL instance and a real Keycloak, so the tests need real (local) credentials. Replacing them with indirection would make the suite harder to run without making anything safer.

### Verified absent from the entire git history

- `.env` or any non-example environment file
- Private keys (`.pem`, `.key`, `.p12`, `.pfx`, `id_rsa`)
- Cloud provider credentials (AWS, GCP, Azure)
- API tokens (GitHub `gh[pousr]_`, OpenAI `sk-`, Slack `xox[baprs]-`)
- Connection strings pointing anywhere other than `localhost` / the compose network

Screenshots under `web/tests/screenshots/` that show a filled login form render the password field **masked**; only the fixture username is legible.

## Running this project safely

`.env` is git-ignored (`.gitignore:16-18`); `.env.example` is the tracked template. Copy it and edit locally:

```bash
cp .env.example .env
```

Before any real deployment, replace **every** value in `.env` — particularly `BPM_BOOTSTRAP_TOKEN` and `BPM_KEYCLOAK_SECRET`. The defaults are for a laptop, not a server.

## Security posture of the codebase

Enforced by directives in `CLAUDE.md` and checked by linters under `tools/`:

- **No SQL string interpolation.** All queries use `$1`/`$2` placeholders via prepared statements; `tools/lint_sql_param_types.py` checks parameter typing.
- **No secrets in source.** Credentials are read from the environment; `BPM_IDP_ADMIN_CREDENTIALS_REF` uses an indirection (`env:VAR_NAME`) rather than an inline value.
- **Secrets at rest** are encrypted with AES-256-GCM envelope encryption (`src/secrets/crypto.zig`).
- **No `catch unreachable` on realistic failure paths** — typed error sets instead, so error handling is explicit rather than a panic.
