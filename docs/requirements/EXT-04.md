---
id: EXT-04
title: Variable transformer
stage: 6
priority: SHOULD
status: RELEASED
---

# EXT-04 — Variable transformer `[SHOULD]`

> Process definitions SHALL support declaration of CEL variable transformation expressions on edges, allowing field mapping or computation between task output and next task input without a gateway node.

**Acceptance Criteria:**
- GIVEN an edge in a process definition with a `transform` CEL expression, WHEN the execution token traverses that edge, THEN the CEL expression is evaluated against the current instance variables, and the result (which MUST be a JSON object) is merged into the instance variables per EE-09.
- GIVEN the CEL expression returns a non-object type, THEN the transform is an error and EE-10 is applied.
- CEL transformer expressions are validated at definition activation time (PD-02); invalid CEL syntax is rejected at definition time.
- Transformer expressions are evaluated AFTER task output merge (EE-09) and BEFORE next-node activation.

**See:** EE-09 (merge used for transformer output), PD-06 (CEL expressions validated at definition time), EE-05 (CEL evaluation context is the same)

**Edge cases:**
- Expression accesses a variable that doesn't exist yet: CEL returns a runtime error → EE-10.
- Empty transform expression `""`: treated as no transformer; edge is followed without transformation.
