---
id: EXT-03
title: Plugin interface
stage: 6
priority: SHOULD
status: RELEASED
---

# EXT-03 — Plugin interface `[SHOULD]`

> The platform SHALL define a stable internal interface for registering custom node type handlers. A handler receives the current instance context and returns an outcome. Handlers are registered at startup.

**Acceptance Criteria:**
- GIVEN a plugin is registered at platform startup, WHEN execution reaches a node with the plugin's registered type, THEN the platform calls the plugin handler with the current instance context (variables, node config).
- Plugin handlers MUST return one of: `COMPLETE` (with optional output variables), `ERROR` (with a reason string).
- GIVEN a plugin handler panics, WHEN the panic is caught by the platform, THEN it is treated as `ERROR` outcome and EE-10 is applied.
- Plugins are registered in-process at startup only; no dynamic loading at runtime.
- A stable Zig interface type is defined; changes to it constitute a breaking API change requiring a major version bump.

**See:** EE-10 (ERROR outcome from plugin triggers this), EE-09 (COMPLETE with output variables uses this merge)

**Edge cases:**
- Plugin registered for a node type that also has a built-in handler: plugin takes precedence; built-in is shadowed.
