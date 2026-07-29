---
id: SPC-01
title: Declared input/output contract for SUB_PROCESS nodes
stage: 15
priority: SHOULD
status: DRAFT
---

# SPC-01 — Declared input/output contract for SUB_PROCESS nodes `[SHOULD]`

> **Extends:** EXT-05. **Preserves:** existing SUB_PROCESS behaviour (full
> parent variable map copied to child; full child variable map merged back)
> for any node that omits the contract — fully backward compatible.

> A SUB_PROCESS node MAY declare an `interface` object with `inputs` (array of
> `{name, json_schema, required}`) and `outputs` (array of `{name, json_schema,
> required}`). When declared, only the input variables named in `inputs` are
> copied into the child instance's initial variable map (instead of the full
> parent map), each validated against its `json_schema` before the child is
> created. On child completion, only the variables named in `outputs` are
> merged into the parent's variable map per EE-09; any other variable the
> child produced is discarded. If `interface` is omitted, EXT-05 behaviour
> applies unchanged.

**Acceptance Criteria:**
- GIVEN a SUB_PROCESS node with a declared `interface.inputs` list, WHEN the
  node activates, THEN only the named variables are copied into the child
  instance's initial variable map; other parent variables are not visible to
  the child.
- GIVEN a required input variable declared in `interface.inputs` is absent
  from the parent's variable map at activation time, WHEN the node activates,
  THEN the parent instance transitions to ERROR status per EE-10 with a
  structured reason identifying the missing input, and no child instance is
  created.
- GIVEN an input variable present but failing its declared `json_schema`,
  WHEN the node activates, THEN the parent instance transitions to ERROR
  status per EE-10 before any child instance is created (no orphaned child).
- GIVEN a SUB_PROCESS node with a declared `interface.outputs` list, WHEN the
  child instance reaches COMPLETED, THEN only the named output variables are
  merged into the parent's variable map per EE-09; variables produced by the
  child that are not named in `outputs` are discarded, not merged.
- GIVEN a required output variable declared in `interface.outputs` is absent
  from the child's final variable state, WHEN the child completes, THEN the
  parent instance transitions to ERROR status per EE-10.
- GIVEN a SUB_PROCESS node with no `interface` object, WHEN activated, THEN
  behaviour is identical to EXT-05 (full parent variable map copied to child;
  full child variable map merged back).

**See:** EXT-05 (sub-process support), EE-09 (variable merge semantics),
EE-10 (execution error handling), PD-05 (node type attribute validation),
SPC-02 (definition-time validation of the interface schemas), PLC-01
(catalog reference reuses this contract)

**Edge cases:**
- `interface.inputs` is an empty array: the child starts with an empty
  initial variable map regardless of parent state.
- A required output is renamed in a later version of the child definition:
  this is a cross-definition compatibility concern, not a runtime validation
  concern — see PLC-03.
