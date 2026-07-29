> The platform SHALL compile every CEL expression carried by a definition against the VLD-01 typed environment visible at that expression's site. The sites are transition guards, human-task assignment expressions, timer delay expressions, service-task input mappings, and form `visible_when` and `computed_from` expressions. Compilation runs only after the PD-02 structure check and the PD-06 syntax check pass. Required result types are bool for a guard, duration or timestamp for a timer delay, and the declared field type for `computed_from`.

**Acceptance Criteria:**
- GIVEN a transition guard that compiles to a type other than bool, WHEN it is checked, THEN the platform records `TypeMismatch` naming bool as expected and the compiled type as actual.
- GIVEN an expression referencing an identifier absent from the environment, WHEN it is compiled, THEN the platform records `UnknownVariable` naming the identifier.
- GIVEN an expression adding a string operand to a number operand, WHEN it is compiled, THEN the platform records `OperandTypeError` naming the operator and both operand types.
- GIVEN the PD-06 syntax check fails, WHEN validation runs, THEN semantic compilation does not execute and the response carries the PD-06 diagnostics only.
- GIVEN an expression site holding an empty or whitespace-only string, WHEN it is checked, THEN the platform records `EmptyExpression` rather than passing the site.

**See:** PD-02, PD-06, EE-05, VLD-01, VLD-03, VLD-04
