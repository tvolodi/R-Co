> The platform SHALL build a typed environment for expression validation from the definition's own declarations: the `variable_schema`, the declared result schemas of referenced service catalog entries (REPO-07, SVC-01), the declared output schemas of referenced `module_ref` modules (PLC-01), and the field types of each human task's form schema. The declared type names map as follows: `string`, `text` and `enum` to string; `integer`, `decimal` and `money` to number; `boolean` to bool; `date` and `datetime` to timestamp; `list<T>` to a list of the mapped element type; `object` to map.

**Acceptance Criteria:**
- GIVEN `variable_schema` declares a type name outside the mapping table, WHEN the environment is built, THEN the platform returns HTTP 422 `UnknownVariableType` naming the variable and the type.
- GIVEN a SERVICE_TASK references a catalog entry that declares no result schema, WHEN the environment is built, THEN the platform returns HTTP 422 `UndeclaredResultSchema` naming the node and the reference.
- GIVEN two form fields in one human task scope declare the same name with different types, WHEN the environment is built, THEN the platform returns HTTP 422 `ConflictingFieldType` naming both declarations.
- The environment is derived from declarations only; no instance variable value contributes a type.
- A node output type is visible only to expression sites on nodes reachable after that node, and a form field type only inside its own human task scope.

**See:** PD-06, EE-05, REPO-07, SVC-01, PLC-01, VLD-02
