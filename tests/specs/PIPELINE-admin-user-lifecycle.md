# Pipeline Spec: admin-user-lifecycle — Admin User Lifecycle

**Requirements covered:** ADM-UI-01, ADM-UI-02, ADM-UI-03, ADM-UI-04  
**Actor:** Platform administrator  
**Starting state:** Administrator is authenticated; no test user exists  
**Ending state:** Test user created during the pipeline is deactivated (INACTIVE status)

## Workflow narrative

A platform administrator opens the Users section, verifies the user list is correctly
structured, creates a new user account, updates the user's profile and role assignments,
then deactivates the account. This is the core admin user management journey — every
step depends on the previous one having succeeded. A role cannot be assigned to a user
that doesn't exist yet; a user cannot be deactivated before it is created. Testing each
screen in isolation does not verify that state flows correctly between them.

## Chain topology

```
login (admin token obtained once, reused throughout)
  → [1] verify user list columns and search  (ADM-UI-01)
  → [2] create user                          (ADM-UI-02)  → produces: userId, username
  → [3] update display name and email        (ADM-UI-03a) → reads: userId
  → [4] assign role                          (ADM-UI-03b) → reads: userId
  → [5] verify group memberships visible     (ADM-UI-03c) → reads: userId
  → [6] deactivate user                      (ADM-UI-04)  → reads: userId  ← also cleanup
```

A failure at any step aborts all subsequent steps. The `pl.onCleanup()` handler runs
unconditionally after the chain regardless of whether it completed or aborted.

---

## Steps

### Step 1 — ADM-UI-01: user list columns and search

**Given:** Administrator is logged in; the Users admin page is reachable at `/admin/users`  
**When:** The administrator navigates to `/admin/users` and enters a search term  
**Then:** The page shows a heading "Users"; the table is visible with columns: Username,
Display name, Email, Status; a search for "admin" returns results without error  
**Gate condition:** none — this step verifies read-only UI structure; nothing is produced  
**Produces:** nothing

---

### Step 2 — ADM-UI-02: create user

**Given:** Administrator is on the Users list page; a unique username and email generated
for this pipeline run do not yet exist in the system  
**When:** The administrator clicks "New user", fills in username, display name, email, and
password, then clicks "Create user"  
**Then:** The browser navigates to `/admin/users/{id}`; the user detail form is visible;
the URL contains a non-empty UUID as the user ID  
**Gate condition:** `userId` extracted from the URL must be a non-empty string — if this
fails, steps 3–6 cannot run because there is no user to act on  
**Produces:** `userId` (UUID), `username` (string)

---

### Step 3 — ADM-UI-03a: update display name and email

**Given:** The administrator is on the user detail page for `userId`; the user detail form
is loaded  
**When:** The administrator updates the display name to include "(updated)" and changes the
email to `<username>.updated@example.com`, then clicks Save  
**Then:** A "Saved" confirmation message appears in `[data-testid="admin-user-submit-message"]`  
**Gate condition:** none  
**Produces:** nothing (side effect: user record updated in the database)

---

### Step 4 — ADM-UI-03b: assign role

**Given:** The administrator is on the user detail page for `userId`; the Role assignments
section is visible  
**When:** The administrator checks the first available role checkbox and clicks Save  
**Then:** A "Saved" confirmation message appears; if no roles are available in the system,
this step passes silently (role availability is not under test here)  
**Gate condition:** none  
**Produces:** nothing

---

### Step 5 — ADM-UI-03c: verify group memberships section visible

**Given:** The administrator is on the user detail page for `userId`  
**When:** The administrator navigates to the user detail page  
**Then:** A "Group memberships" heading is visible on the page  
**Gate condition:** none  
**Produces:** nothing

---

### Step 6 — ADM-UI-04: deactivate user

**Given:** The user identified by `userId` is currently ACTIVE; the administrator is on
the user detail page  
**When:** The administrator clicks "Deactivate", reads the confirmation dialog text, then
confirms the action  
**Then:** The confirmation dialog contains the text "Active tasks assigned to this user
remain assigned" and "cannot complete them while INACTIVE"; after confirmation, the status
field shows INACTIVE  
**Gate condition:** `[data-testid="admin-user-status"]` must contain "INACTIVE" — confirms
the deactivation persisted  
**Produces:** nothing (this step is also the primary cleanup action)

---

## Cleanup

**Handler:** registered via `pl.onCleanup()` — runs unconditionally after the chain,
whether it completed, aborted mid-way, or threw an unexpected error  
**Action:** `PATCH /api/v1/admin/users/{userId}` with body `{ status: "INACTIVE", is_active: false }`  
**Fallback:** if `userId` is empty (chain aborted before step 2 produced it), no API call
is made and cleanup is a no-op — no user was created so there is nothing to clean up

---

## Failure behaviour

| Step that fails | Steps skipped | System state left behind | Cleanup needed |
|---|---|---|---|
| Step 1 | Steps 2–6 | Nothing created | No |
| Step 2 | Steps 3–6 | User may be partially created | Yes — cleanup handler deactivates |
| Step 3 | Steps 4–6 | User exists, profile not updated | Yes — cleanup handler deactivates |
| Step 4 | Steps 5–6 | User exists, role not assigned | Yes — cleanup handler deactivates |
| Step 5 | Step 6 | User exists, group section not verified | Yes — cleanup handler deactivates |
| Step 6 | — | Step 6 IS the deactivation — if it fails, user remains ACTIVE | Yes — cleanup handler retries deactivation via API |
