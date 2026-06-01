# Pipeline Spec: admin-groups-tokens — Admin Groups and API Tokens Lifecycle

**Requirements covered:** ADM-UI-05, ADM-UI-06, ADM-UI-07, ADM-UI-08  
**Actor:** Platform administrator  
**Starting state:** Administrator is authenticated; no test group or token exists  
**Ending state:** Test group deleted; test token revoked; test user deactivated

## Workflow narrative

A platform administrator creates a user group, adds a member to it, then issues an API
token for a test user. The administrator verifies the token appears in the list without
exposing its raw value, confirms the one-time reveal modal works, and finally revokes the
token. The group is deleted once empty. This journey validates the full admin access
management loop: groups first (membership controls what tasks users see), tokens second
(service account access). Neither step is meaningful without the other — a token issued
to a user in no group has restricted access; a group with no members does nothing.

## Chain topology

```
login (admin token obtained once)
  → [1] create user fixture (API)                  → produces: userId
  → [2] verify groups list structure  (ADM-UI-05a) → reads: —
  → [3] create group via UI           (ADM-UI-05b) → produces: groupId, groupName
  → [4] add user as group member      (ADM-UI-05c) → reads: groupId, userId
  → [5] remove member and delete group(ADM-UI-05d) → reads: groupId  ← group cleanup
  → [6] issue API token via UI        (ADM-UI-07)  → produces: tokenId, tokenValue
  → [7] verify token list metadata    (ADM-UI-06)  → reads: tokenId, userId
  → [8] revoke token                  (ADM-UI-08)  → reads: tokenId  ← token cleanup
  → cleanup: deactivate user          (API)        → reads: userId
```

A failure at any step aborts all subsequent steps. The `pl.onCleanup()` handler
runs unconditionally and handles any combination of partial state.

---

## Steps

### Step 1 — create user fixture

**Given:** Administrator is authenticated  
**When:** A test user is created via the admin API (`POST /api/v1/users`)  
**Then:** Response is 200/201 with a `id` field  
**Gate condition:** `userId` must be a non-empty string — steps 4 and 8 cannot run without it  
**Produces:** `userId`, `username`, `email`

---

### Step 2 — ADM-UI-05a: verify groups list structure

**Given:** Administrator is logged in and navigates to `/admin/groups`  
**When:** The page loads  
**Then:** Heading "Groups" is visible; table has columns: Name, Display name, Members,
Description, Actions  
**Gate condition:** none  
**Produces:** nothing

---

### Step 3 — ADM-UI-05b: create group via UI

**Given:** Administrator is on `/admin/groups`; a unique group name was generated for this run  
**When:** The administrator clicks "+ New Group", fills in name, display name, description,
and clicks Save  
**Then:** The new group row appears in the table showing the display name and member count "0"  
**Gate condition:** `groupId` extracted from the API response (intercepted via `waitForResponse`)
must be a non-empty string — steps 4 and 5 depend on it  
**Produces:** `groupId`, `groupName`, `groupDisplayName`

---

### Step 4 — ADM-UI-05c: add user as group member

**Given:** The group row for `groupId` is visible; `userId` exists from step 1  
**When:** The administrator clicks "Manage members" on the group row, selects the test user
from the dropdown, and clicks "Add member"  
**Then:** The member dialog shows the test user's display name in the member list  
**Gate condition:** none  
**Produces:** nothing (side effect: user is now a group member)

---

### Step 5 — ADM-UI-05d: remove member and delete group

**Given:** The group has one member (the test user from step 4)  
**When:** The administrator removes the member, closes the dialog, then clicks Delete on
the group row and confirms the deletion dialog  
**Then:** The group row disappears from the table  
**Gate condition:** none  
**Produces:** nothing (this step is also the primary group cleanup)

---

### Step 6 — ADM-UI-07: issue API token via UI (one-time reveal modal)

**Given:** Administrator navigates to `/admin/tokens`; `userId` exists from step 1  
**When:** The administrator clicks "+ Issue token", selects the test user, enters roles
"TASK_WORKER, PROCESS_OPERATOR", and clicks "Issue token"  
**Then:** An "Issued token" dialog appears containing the raw token value and the text
"This value will not be shown again."; the Copy button works; closing the dialog hides
the raw value  
**Gate condition:** `tokenId` and `tokenValue` extracted from the API response must be
non-empty — step 7 and 8 need `tokenId`  
**Produces:** `tokenId`, `tokenValue`

---

### Step 7 — ADM-UI-06: verify token list metadata

**Given:** Administrator is on `/admin/tokens`; `tokenId` from step 6 is in the system  
**When:** The page loads and the token list is visible  
**Then:** The row for the test user shows: display name, roles "TASK_WORKER, PROCESS_OPERATOR",
expiry "Never", status "ACTIVE"; the raw token value from step 6 does NOT appear anywhere
on the page  
**Gate condition:** none  
**Produces:** nothing

---

### Step 8 — ADM-UI-08: revoke token

**Given:** The token row for `tokenId` is visible and shows status "ACTIVE"  
**When:** The administrator clicks "Revoke" on the token row and confirms the dialog  
**Then:** The row shows status "REVOKED" with strikethrough styling; the Revoke button
is no longer present on the row  
**Gate condition:** none (this step is also the primary token cleanup)  
**Produces:** nothing

---

## Cleanup

**Handler:** registered via `pl.onCleanup()` — runs unconditionally  
**Actions (in order):**
1. If `tokenId` is set: `DELETE /api/v1/auth/tokens/{tokenId}` (idempotent — 404 is OK)
2. If `groupId` is set: `DELETE /api/v1/admin/groups/{groupId}` (idempotent — 404 is OK)
3. If `userId` is set: `PATCH /api/v1/users/{userId}` with `{ status: "INACTIVE" }`

---

## Failure behaviour

| Step that fails | Steps skipped | System state left behind | Cleanup needed |
|---|---|---|---|
| Step 1 | Steps 2–8 | Nothing created | No |
| Step 2 | Steps 3–8 | User created | Yes — deactivate user |
| Step 3 | Steps 4–8 | User created; group may be partial | Yes — delete group, deactivate user |
| Step 4 | Steps 5–8 | User + group created; no member | Yes — delete group, deactivate user |
| Step 5 | Steps 6–8 | Group deletion failed; may still exist | Yes — delete group, deactivate user |
| Step 6 | Steps 7–8 | Group deleted; token not issued | Yes — deactivate user |
| Step 7 | Step 8 | Token issued but not revoked | Yes — revoke token, deactivate user |
| Step 8 | — | Token revocation step itself failed | Yes — cleanup handler revokes via API |
