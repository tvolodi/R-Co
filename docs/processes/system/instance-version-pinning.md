# Process: Instance Version Pinning

| Field | Value |
|-------|-------|
| Process ID | `sys-instance-version-pinning` |
| Owner | Platform (Instance Executor) / Tenant Admin |
| Scope | System-wide (per-tenant instances) |
| Platform Workflow | PW-03 |
| Requirements | PIN-01, PIN-02, PIN-03, PIN-04, PIN-05 |
| Source | `docs/workflows.yaml` (PW-03) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.2 |

## Summary

Resolves every versioned artefact an instance depends on -- service catalog
entries, variable schema, and Stage 15 `module_ref` sub-process modules -- once
at instance start, and records the resolved set in the `INSTANCE_STARTED` event
payload. The engine reads dependencies through that pin set for the whole life
of the instance and never falls back to the latest version, so a months-long
instance cannot pick up a newer catalog entry or module mid-flight. PD-08
already pins the process graph via `definition_snapshot`; this process extends
the same guarantee to the definition kinds added since.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Instance Initiator | Human, agent or start event | Requests instance creation |
| BPM Platform | System | Enumerates and resolves versioned references, writes the pin set into the start event |
| Instance Executor | System | Resolves every dependency through the pin set at each node execution |
| Tenant Admin | Human | Rebinds pins on a running instance as an explicit, audited operation |
| Event Log | System | Sole store of the pin set; reconstruction reads pins from `INSTANCE_STARTED` |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `tenant_id` | UUID | Must refer to an active tenant |
| `process_key` | string | Must have an `active` definition version in this tenant |
| `parent_instance_id` | UUID (optional) | Present for a sub-process child; drives pin inheritance |
| `business_key` | string (optional) | Caller-supplied correlation value |
| `variables` | JSON | Initial process variables; validated against the pinned variable schema |
| `pin_overrides` | object (optional) | Explicit `{kind, ref, version}` entries; each override is recorded with `source = override` |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Instance Initiator | `POST /api/v1/instances` with `process_key` and `variables` | Caller holds `instance.start` for this tenant? | -> 403 Forbidden if not | PIN-01 |
| 2 | Platform | Load the active definition version and copy the graph JSON into `definition_snapshot` (PD-08) | No active version for `process_key`? | -> 422 `NoActiveDefinition`; no instance row is written | PIN-01 |
| 3 | Platform | Enumerate every versioned reference inside the snapshot: service catalog refs on SERVICE_TASK nodes, the definition's `variable_schema`, and `module_ref` semver ranges on sub-process nodes | Enumeration finds zero references? | The pin set contains only the variable schema entry | PIN-01 |
| 4 | Platform | Resolve each service catalog ref to `{catalog_entry_id, version}` against the tenant's catalog as of now | Ref names no entry, or the entry has no active version? | -> 422 `UnresolvedCatalogRef` naming the node and the ref | PIN-01 |
| 5 | Platform | Resolve each `module_ref` semver range to one exact module version | Range matches no published module version? | -> 422 `UnresolvedModuleRef` naming the node, the range, and the versions available | PIN-01 |
| 6 | Platform | Resolve `variable_schema` to its exact schema version and validate the supplied `variables` against it | Variables violate the pinned schema? | -> 422 `VariableSchemaViolation` listing each failing field | PIN-01 |
| 7 | Platform | Apply `pin_overrides`, replacing the resolved version for the named refs | An override names a version that does not exist? | -> 422 `UnresolvedPinOverride`; the whole start is rejected | PIN-01 |
| 8 | Platform | Inherit the parent's pin set when `parent_instance_id` is present; a child adds pins only for refs the parent's set does not carry | Child ref conflicts with an inherited pin? | The inherited pin wins; the child records the conflict in the event payload | PIN-04 |
| 9 | Platform | Build `pinned_versions[]`, one entry per ref: `{kind, ref, resolved_id, version, source}` with `kind` in `catalog_entry`, `variable_schema`, `module` and `source` in `resolved`, `override`, `inherited` | -- | Pin set is complete and ordered by `kind` then `ref` | PIN-02 |
| 10 | Platform | Append `INSTANCE_STARTED` carrying `definition_snapshot` and `pinned_versions[]` in the same transaction as the instance row insert | Append fails? | The transaction rolls back; no instance exists with an unpinned dependency | PIN-02 |
| 11 | Instance Executor | At each node, read the dependency version from the reconstructed pin set | Pin set carries no entry for this ref? | Raise typed `PinMissing`; the step fails into the standard retry then dead-letter path. The executor never resolves the latest version instead | PIN-03 |
| 12 | Instance Executor | Invoke the service catalog entry, sub-process module or schema at the pinned version | Pinned version has since been retired in the catalog? | Execution proceeds on the pinned version; retirement blocks new pins, not existing ones | PIN-03 |
| 13 | Platform | Publish a new catalog entry or module version | In-flight instances hold pins on the prior version? | Publication succeeds; in-flight instances continue on their pins; new instances resolve the new version at step 4 or 5 | PIN-03 |
| 14 | Platform | Reconstruct instance state by replaying the event log | Reconstruction needs a dependency version? | It reads `pinned_versions[]` from `INSTANCE_STARTED` and the latest `INSTANCE_PINS_REBOUND`; it never queries the live catalog | PIN-04 |
| 15 | Tenant Admin | `GET /api/v1/instances/{id}/pins` | -- | -> 200 with the effective pin set and the event ID each entry came from | PIN-04 |
| 16 | Tenant Admin | `POST /api/v1/instances/{id}/rebind-pins` with explicit `{kind, ref, version}` entries and a reason | Instance is `COMPLETED`, `CANCELLED` or `FAILED`? | -> 409 `InstanceNotRebindable` | PIN-05 |
| 17 | Platform | Append `INSTANCE_PINS_REBOUND` carrying the prior version, the new version and the reason for each changed entry | Rebind names a ref absent from the current pin set? | -> 422 `UnknownPinRef`; no partial rebind is applied | PIN-05 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Resolve once | Every versioned reference is resolved during instance start. No reference is resolved later than the `INSTANCE_STARTED` append |
| Pins live in the event log | The pin set is a field of `INSTANCE_STARTED`, not a side table. The platform is event-sourced and the start event is the record of record |
| Same transaction | The pin set is appended in the transaction that inserts the instance row. A committed instance always has a committed pin set |
| No latest fallback | A missing pin raises `PinMissing`. Resolving the current active version in its place is a defect |
| Retirement does not break pins | Retiring a catalog entry or module version stops new pins on it; instances already pinned continue to completion |
| Children inherit | A sub-process child inherits the parent's pin set. Where the parent carries a pin, the child cannot resolve a different version |
| Overrides are recorded | An entry supplied through `pin_overrides` is stored with `source = override`, so an audit reads which versions were chosen rather than resolved |
| Rebind is explicit | Pins change only through `rebind-pins` with named versions and a reason. There is no automatic upgrade of a running instance |
| Rebind is all-or-nothing | A rebind request that names an unknown ref applies none of its entries |
| Ordering | `pinned_versions[]` is ordered by `kind` then `ref`, so two starts of the same definition against the same catalog produce byte-identical payloads |
| Graph pinning unchanged | `definition_snapshot` continues to pin the process graph per PD-08; this process adds the non-graph kinds beside it |

---

## Outputs

| Output | Description |
|--------|-------------|
| `instance_id` | UUID of the started instance |
| `pinned_versions[]` | Entries of `{kind, ref, resolved_id, version, source}` inside the `INSTANCE_STARTED` payload |
| `definition_snapshot` | Graph JSON pinned at start (PD-08) |
| Event log entries | `INSTANCE_STARTED` with the pin set, `INSTANCE_PINS_REBOUND` on every rebind |
| Pin read surface | `GET /api/v1/instances/{id}/pins` returning the effective set and its source event IDs |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Pin resolution | Runs inside the instance-start request; the platform NFR of <= 500 ms write covers resolution plus append |
| Catalog unavailable at start | Resolution fails with 503 `CatalogUnavailable`; no instance is created and the caller retries |
| `PinMissing` at execution | The step enters the standard retry schedule; after the retry budget it lands in the dead-letter queue with the ref name |
| Long-running instance | No timer expires a pin. An instance holds its pins until it completes or an admin rebinds |
| Rebind audit | Every `INSTANCE_PINS_REBOUND` is visible on the instance timeline with actor, reason, prior version and new version |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 403 Forbidden | Caller lacks `instance.start` on the tenant | Authenticate with a principal holding the permission |
| 422 `NoActiveDefinition` | `process_key` has no active version | Publish or promote a version first (PW-01) |
| 422 `UnresolvedCatalogRef` | A SERVICE_TASK names a catalog entry with no active version | Register or activate the catalog entry, then start the instance |
| 422 `UnresolvedModuleRef` | A `module_ref` semver range matches no published module version | Publish a matching module version or widen the range in the definition |
| 422 `VariableSchemaViolation` | Initial variables fail the pinned variable schema | Correct the variables and resubmit |
| 422 `UnresolvedPinOverride` | An override names a nonexistent version | Supply a version present in the catalog or module registry |
| 422 `UnknownPinRef` | Rebind names a ref the instance does not pin | Read `GET .../pins` and rebind an existing ref |
| 409 `InstanceNotRebindable` | Rebind on a `COMPLETED`, `CANCELLED` or `FAILED` instance | Start a new instance; a terminal instance keeps its historical pins |
| `PinMissing` | Engine reached a node whose ref has no pin entry | Rebind the instance with the intended version, then retry the dead-lettered step |
| 503 `CatalogUnavailable` | Catalog read failed during resolution | Retry the start; nothing was written |
