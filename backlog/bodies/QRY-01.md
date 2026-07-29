> **Extends:** API-06, generalizing cursor-paged reads from fixed endpoints to tenant-defined entity projections.

> The platform SHALL expose one structured query surface over entity projections at `POST /api/v1/entities/{entity_key}/query`. The request body carries `filters` as an array of `{field, op, value}` nodes, `sort` as an array of `{field, dir}` nodes, `page_size`, and `cursor`. `op` is an enum over `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `in`, `contains`; `dir` is an enum over `asc`, `desc`. No request field is concatenated into statement text: the compiler emits allowlisted column and key references and binds every literal as a positional parameter. The surface reads committed typed projection tables `ent_<entity_key>` and performs no write.

**Acceptance Criteria:**
- GIVEN a filter node with `op` outside the enum, WHEN the request is parsed, THEN the platform returns HTTP 400 `operator_not_recognised` naming the received value, and no statement is executed.
- GIVEN a filter value containing `' OR 1=1 --`, WHEN the query executes, THEN the value is bound as a positional parameter, the result set is the rows whose column equals that literal string, and the statement text contains no part of the value.
- GIVEN a request body carrying a raw SQL fragment in any field, WHEN it is parsed, THEN it is rejected by the request model before compilation; the surface accepts no field whose contents reach the database as statement text.
- GIVEN a valid query, WHEN it executes, THEN it reads only `ent_<entity_key>` in the caller's tenant and issues no INSERT, UPDATE, or DELETE.
- GIVEN the entity projection is rebuilt from the event log, WHEN the same query is re-issued, THEN the request document is unchanged and remains valid; the query surface holds no per-record state and defines no record placement states.
- `EntityQueryExecuted` is appended with `entity_key`, the filter field names, and the row count; filter values are not recorded.

**See:** API-06, API-10, ADP-09, TNT-01, QRY-02, QRY-03, QRY-04, QRY-05
