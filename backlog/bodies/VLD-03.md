> The platform SHALL report every semantic validation finding from a single pass in one HTTP 422 response. Each finding carries `node_id`, `expression_path`, `source`, `error_kind` and `message`. `error_kind` is one of `UnknownVariable`, `TypeMismatch`, `OperandTypeError`, `UnknownVariableType`, `UndeclaredResultSchema`, `ConflictingFieldType`, `EmptyExpression`.

**Acceptance Criteria:**
- GIVEN a definition with three failing expression sites, WHEN validation runs, THEN one HTTP 422 response contains three findings; validation does not stop at the first failure.
- GIVEN any finding, WHEN it is serialised, THEN it carries `node_id`, `expression_path`, `source`, `error_kind` and `message`.
- GIVEN a finding of kind `UnknownVariable`, WHEN the message is built, THEN it names the referenced identifier and the nearest declared identifier by edit distance.
- Findings are ordered by `node_id` then `expression_path`, so two validations of the same definition produce identical ordering.
- No `error_kind` value outside the enumerated set is emitted.

**See:** VLD-01, VLD-02, VLD-04, PD-06
