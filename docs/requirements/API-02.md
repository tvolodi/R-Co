---
id: API-02
title: Process definition CRUD
stage: 4
priority: MUST
status: RELEASED
---

# API-02 — Process definition CRUD `[MUST]`

> The API SHALL expose: `POST /definitions`, `GET /definitions`, `GET /definitions/:id`, `PUT /definitions/:id` (full replacement of DRAFT only), `PATCH /definitions/:id` (partial update of DRAFT only), `DELETE /definitions/:id` (hard delete of DRAFT; archive of ACTIVE/DEPRECATED), `POST /definitions/:id/activate`.

**Acceptance Criteria:**
- `POST /definitions`: creates a definition; returns HTTP 201 with definition ID. Requires PROCESS_DESIGNER or PLATFORM_ADMIN.
- `GET /definitions`: lists definitions, paginated (API-06), filterable by `status` and `name`. Any authenticated role.
- `GET /definitions/:id`: returns definition. HTTP 404 if not found. Any authenticated role.
- `PUT /definitions/:id`: full replacement; only valid for DRAFT definitions. HTTP 409 if `status ≠ DRAFT`. Requires PROCESS_DESIGNER or PLATFORM_ADMIN.
- `PATCH /definitions/:id`: partial update; only valid for DRAFT. HTTP 409 if `status ≠ DRAFT`. Requires PROCESS_DESIGNER or PLATFORM_ADMIN.
- `DELETE /definitions/:id`: hard delete of never-activated DRAFT (HTTP 204); archive of ACTIVE or DEPRECATED (HTTP 200). HTTP 404 if not found. Requires PLATFORM_ADMIN.
- `POST /definitions/:id/activate`: transitions DRAFT → ACTIVE. HTTP 409 if `status ≠ DRAFT`. Triggers PD-02 graph re-validation. Requires PROCESS_DESIGNER or PLATFORM_ADMIN.
- All write operations trigger PD-02 graph validation; validation failures return HTTP 422.

**See:** PD-01..PD-08 (business rules for each operation), API-01 (conventions), API-07 (validation), API-08 (auth)

**Edge cases:**
- PUT/PATCH on an ACTIVE definition: rejected with HTTP 409.
- DELETE on an ACTIVE definition: triggers archive (not hard delete), HTTP 200.
