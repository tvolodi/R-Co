---
id: SPC-02
title: Contract validated at definition-time
stage: 15
priority: SHOULD
status: DRAFT
---

# SPC-02 — Contract validated at definition-time `[SHOULD]`

> On creation or update of a definition containing a SUB_PROCESS node with a
> declared `interface`, the platform SHALL validate that every `json_schema`
> under `inputs`/`outputs` is itself a well-formed JSON Schema, rejecting the
> definition with HTTP 422 otherwise. The platform does not validate at this
> point that the referenced child definition actually produces the declared
> outputs — parent and child may be authored and versioned independently;
> that cross-definition check is addressed by PLC-03.

**Acceptance Criteria:**
- GIVEN a SUB_PROCESS node whose `interface.inputs` or `interface.outputs`
  contains a malformed `json_schema`, WHEN the definition is created or
  updated, THEN HTTP 422 is returned identifying the offending schema and its
  node.
- GIVEN a SUB_PROCESS node with a well-formed `interface` on all entries,
  WHEN the definition is created, THEN validation succeeds under the existing
  PD-02 graph validation rules and the interface is persisted as part of the
  node's attributes.

**See:** PD-02 (graph validation), PD-05 (node type specifications), SPC-01
(the contract this validates)
