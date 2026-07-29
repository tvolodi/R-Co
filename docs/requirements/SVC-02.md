---
id: SVC-02
title: Plugin handlers declare scope and optional owner tenant at registration
stage: 13
priority: MUST
status: RELEASED
---

# SVC-02 — Plugin handlers declare scope and optional owner tenant at registration `[MUST]`

> Every plugin handler registered via the plugin interface (EXT-03) SHALL
> declare a `scope` (`global` or `tenant`) and, when `scope = tenant`, an
> `owner_tenant_id`. The plugin dispatch path SHALL check scope before invoking
> a handler: a tenant-scoped plugin is only invoked for its owning tenant's
> process instances. Global plugins are invoked for all tenants.

**Acceptance Criteria:**
- GIVEN the `PluginRegistration` struct, THEN it gains fields:
  - `scope: PluginScope` where `PluginScope = enum { global, tenant }`
  - `owner_tenant_id: ?Uuid` (null for global, required for tenant-scoped)
- GIVEN `registerPlugin()` is called with `scope = .tenant` and
  `owner_tenant_id = null`, THEN registration fails with
  `error.TenantScopedPluginRequiresOwnerId` before `freezePluginRegistry()`.
- GIVEN a SERVICE_TASK node executes for an instance belonging to tenant T,
  WHEN the plugin registry is consulted, THEN only plugins with
  `scope = .global` OR `(scope = .tenant AND owner_tenant_id == T)` are
  eligible for dispatch.
- GIVEN a tenant-scoped plugin P is registered for tenant T, WHEN a
  SERVICE_TASK executes for tenant U (U ≠ T), THEN plugin P is not invoked;
  the built-in handler or a global plugin takes precedence per EXT-03 priority
  rules.
- GIVEN a global plugin and a tenant-scoped plugin are both registered for the
  same node type, and the executing instance belongs to the tenant-scoped
  plugin's owning tenant, THEN the tenant-scoped plugin takes precedence over
  the global one.
- `freezePluginRegistry()` validates that no two tenant-scoped plugins share
  the same `(node_type, owner_tenant_id)` combination; duplicate registration
  is a fatal startup error.
- The plugin registry remains in-process and startup-only (EXT-03 constraint
  unchanged); tenant scoping is a filter on dispatch, not a dynamic loading
  mechanism.

**See:** SVC-01 (service catalog scope model — same pattern applied to
plugins), EXT-03 (plugin interface base requirement), SVC-03 (definition
activation checks plugin availability)

**Edge cases:**
- A global plugin is registered for a node type that also has a built-in
  handler: global plugin takes precedence over built-in (EXT-03 rule unchanged).
- A tenant-scoped plugin's owner tenant is deprovisioned at runtime: the plugin
  remains registered (in-process, frozen) but its `owner_tenant_id` no longer
  resolves to an active tenant; dispatch silently falls through to the global
  plugin or built-in. A startup-time warning is logged if a registered plugin's
  owner tenant does not exist in `public.tenant`.
