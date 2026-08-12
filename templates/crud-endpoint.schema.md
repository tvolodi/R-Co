# CRUD endpoint template (Lego Type A) — schema reference

Authoritative description of every field in `templates/specs/crud-endpoint.template.yaml` and any concrete `templates/specs/<name>.crud-endpoint.yaml` parameter file produced from it.

The codegen tool `tools/codegen_crud_endpoint.py` consumes this format and emits one file:

- `src/api/routes/<resource_name>.zig` — handler stubs, request/response types, error switch, and a routing comment block to paste into `src/api/router.zig`.

**What codegen produces vs. what the implementer writes:**  
Everything outside a `// CUSTOM:` block is generated boilerplate — struct shapes, the error switch skeleton, the `HandlerResult` return type, and the routing comment. The implementer fills in only the `// CUSTOM:` blocks: store calls, serialisation logic, and any input validation beyond what the YAML captures. Never edit the boilerplate; re-run codegen to regenerate it after a spec change.

---

## Top-level fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | int | yes | Template version. Currently `1`. Bump only when the YAML schema itself changes. |
| `resource_name` | string | yes | snake_case identifier used as the Zig filename stem (`src/api/routes/<resource_name>.zig`) and in generated comment headers. |
| `store_module` | string | yes | Workspace-relative path to the backing store file (e.g. `src/comment/store.zig`). Used in the generated `@import`. |
| `store_struct` | string | yes | Zig type expression for the store (e.g. `comment_store.Store`). Used as the type of the `*store` parameter in each handler. |
| `requirement_ids` | list[string] | yes | MUST requirement IDs this endpoint satisfies. Used by lint to cross-check the requirements doc. |
| `purpose` | string (multi-line) | yes | One-paragraph rationale. Emitted as the file-level doc comment. |
| `endpoints` | list[Endpoint] | yes (min 1) | One entry per HTTP route. See **Endpoint** below. |
| `default_error_map` | map[string → int] | no | Fallback HTTP status for error variants not listed in an endpoint's own `error_map`. Codegen merges (endpoint over global). |

---

## Endpoint

Each entry in `endpoints` becomes one `pub fn handle<Verb>(...)` in the generated file.

| Field | Type | Required | Notes |
|---|---|---|---|
| `method` | enum: `GET`, `POST`, `PUT`, `PATCH`, `DELETE` | yes | HTTP verb. |
| `path` | string | yes | Route path, e.g. `/api/v1/comments/:id`. Path params must match `path_param`. |
| `operation` | enum: `create`, `read`, `list`, `update`, `delete`, `custom` | yes | Semantic label. Codegen uses this to choose a handler name suffix and default parameter shape. Use `custom` when the operation does not fit standard CRUD (e.g. full-text search, promote, archive). |
| `path_param` | string | no | Name of a `:param` segment in `path`. Required when the route has a path parameter. |
| `path_param_type` | enum: `uuid`, `string`, `u32` | no | Codegen emits a parse helper call matching this type. |
| `body_type` | string | no | Name of the request body struct codegen will synthesise. Required when the endpoint accepts a request body. |
| `body_fields` | list[Field] | when body_type set | Fields in the synthesised body struct. See **Field** below. |
| `query_params` | list[Field] | no | URL query parameters. Each becomes a field in a generated `<Verb>QueryParams` struct. See **Field** below. |
| `store_method` | string | yes | The store method called by this handler, e.g. `store.create`. Written into the `// CUSTOM:` block as a call site comment. |
| `actor_required` | bool | no | When `true`, the generated handler signature includes an `actor_id: []const u8` parameter. |
| `success_status` | int | yes | HTTP status code on success (200, 201, 204, etc.). |
| `error_map` | map[string → int] | yes | Maps Zig error names to HTTP status codes. Codegen emits one `switch` arm per entry. |

### Field

Used for both `body_fields` and `query_params`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | snake_case field name. |
| `type` | string | yes | Zig type expression. Optional fields use `?T` (e.g. `?[]const u8`, `?u16`). |
| `required` | bool | no | Informational for `query_params`; used in generated validation comment. Defaults to `true`. |

---

## Generated output structure

```
src/api/routes/<resource_name>.zig
├── file-level doc comment  (from `purpose`)
├── imports                 (@import("std"), @import("<store_module>"), etc.)
├── Public types section
│   ├── <Verb>QueryParams structs  (one per endpoint with query_params)
│   ├── <body_type> structs        (one per endpoint with body_type)
│   └── HandlerResult              (shared: { status_code: u16, body: []const u8 })
├── Public handler functions section
│   └── pub fn handle<Verb>(store, allocator, ...) HandlerResult
│       ├── [generated] parse path/query params
│       ├── // CUSTOM: call store method and serialise response
│       └── [generated] error switch → errorResult(...)
└── // ROUTING SNIPPET (paste into src/api/router.zig):
    //   METHOD  <path>  →  handle<Verb>
```

---

## CUSTOM: blocks in generated handler files

Codegen marks two regions as implementer-owned:

1. **Store call and response serialisation** — the core of each handler:

```zig
// CUSTOM: call store.<method> and serialise the response.
// Example:
//   const result = try store.create(allocator, actor_id, body);
//   defer result.deinit(allocator);
//   const json = try std.json.stringifyAlloc(allocator, result, .{});
//   return HandlerResult{ .status_code = 201, .body = json };
_ = store;
return errorResult(allocator, 501, "not implemented");
```

2. **Error variant comments** — each `switch` arm that maps to a generated-but-wrong status is annotated:

```zig
// CUSTOM: verify this status — codegen inferred 422 from the name 'ValidationFailed'
error.ValidationFailed => return errorResult(allocator, 422, "validation failed"),
```

**Rule:** Never delete a `// CUSTOM:` comment. Never hand-edit lines outside `// CUSTOM:` blocks — re-run codegen instead. If boilerplate is wrong, fix the template YAML or the codegen script, then re-run.

---

## Lint rules (enforced by `tools/lint_design_artefact.py` and `tools/codegen_crud_endpoint.py --dry-run`)

The validator FAILs if any of these are violated:

1. `resource_name` is not snake_case.
2. `store_module` path does not start with `src/`.
3. Any `endpoint.method` is not a recognised HTTP verb.
4. Any `endpoint.success_status` is outside the 2xx range.
5. Any `endpoint.error_map` key contains characters outside `[A-Za-z]`.
6. Any `endpoint.path_param` is set but `path_param_type` is absent.
7. `endpoints` list is empty.
8. Any `endpoint.operation` is `custom` but `store_method` is absent.

---

## Worked example

**Spec:** `templates/specs/pd10-definition-search.crud-endpoint.yaml`  
**Requirement:** `PD-10` (full-text definition search)  
**Generated file:** `src/api/routes/definition_search.zig`

The spec declares one `GET` endpoint with `operation: custom`, three query params (`q`, `limit`, `offset`), and a three-entry `error_map`. Codegen emits:

```zig
//! HTTP route handlers for definition_search.
//! Full-text search over process definition names and descriptions, …

const std = @import("std");
const Store = @import("../../definition/store.zig");

pub const SearchQueryParams = struct {
    q:      ?[]const u8,
    limit:  ?u32,
    offset: ?u32,
};

pub const HandlerResult = struct {
    status_code: u16,
    body:        []const u8,
};

/// GET /api/v1/definitions/search
pub fn handleSearch(
    store: *Store,
    allocator: std.mem.Allocator,
    params: SearchQueryParams,
) HandlerResult {
    // CUSTOM: call store.search and serialise the response.
    _ = store; _ = params;
    return errorResult(allocator, 501, "not implemented");
}
```

The implementer replaces the `// CUSTOM:` block with the real `store.search(...)` call, the JSON serialisation, and query validation (empty `q`, `q` > 512 chars → 422).

**Partial-fit note:** PD-10 uses `operation: custom` precisely because the handler needs per-field query validation that the standard `read` operation does not model. This is acceptable inside Type A — the deviation is isolated to one `// CUSTOM:` block. If the handler also needed mid-flight business logic (rank override based on tenant tier, async enrichment, etc.) it would become Type E.

---

## Real-codebase candidates that would have been Type A

- `GET /api/v1/definitions/:id` (PD-07 read by id — `operation: read`, no custom logic)
- `GET /api/v1/definitions` (PD-07 list with cursor — `operation: list`, standard pagination)
- `POST /api/v1/definitions/:id/deprecate` (PD-07 lifecycle — `operation: custom`, one store call)
