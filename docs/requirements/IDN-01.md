---
id: IDN-01
title: User registry
stage: 5
priority: MUST
status: VALIDATED
---

# IDN-01 — User registry `[MUST]`

> The platform SHALL maintain a registry of users with: `user_id` (UUID), `username`, `display_name`, `email`, `status` (ACTIVE/INACTIVE), and `created_at`. Authentication of human users (login, passwords, SSO) is out of scope for this platform; users are created programmatically via API and identified in task assignments and audit logs.

**Acceptance Criteria:**
- GIVEN an authorised PLATFORM_ADMIN creates a user with `username`, `display_name`, `email`, and `status = ACTIVE`, THEN the platform returns HTTP 201 with a platform-assigned UUID `user_id` and `created_at`.
- `username` MUST be unique across all users; a duplicate username MUST be rejected with HTTP 409.
- `email` MUST be a valid email format; invalid format MUST be rejected with HTTP 422.
- GIVEN a user's status is set to INACTIVE, WHEN that user's token is used for authentication, THEN HTTP 401 is returned.
- `user_id` is assigned by the platform; callers MUST NOT specify it.

**See:** IDN-02 (users are members of groups), IDN-03 (users hold roles), IDN-04 (tokens are scoped to users), API-08 (authentication uses tokens, not user credentials)

**Edge cases:**
- Creating a user with `status = INACTIVE`: permitted (pre-registering future users).
- Deleting a user: not supported; use `status = INACTIVE` to deactivate.
