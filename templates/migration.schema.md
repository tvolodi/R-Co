# Migration template (Lego Type C) — schema reference

Authoritative description of every field in `templates/specs/migration.template.yaml` and any concrete `templates/specs/<name>.migration.yaml` parameter file produced from it.

The codegen tool `tools/codegen_migration.py` consumes this format and emits two files:

- `migrations/<migration_number>_<name>.sql` — DDL only, fully formed.
- `tests/integration/<name>_test.zig` — fixtures wired up, one `test` block per `test_cases[]` entry, assertion bodies marked `// CUSTOM:` for the implementer to fill in.

---

## Top-level fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | int | yes | Template version. Currently `1`. Bump only when the YAML schema itself changes. |
| `migration_number` | int | yes | Next free `NNN` under `migrations/`. Determined by CODE-DESIGNER scanning the directory. **Write plain decimal (`57`, not `057`)** — PyYAML 1.1 parses `057` as octal 47. Codegen zero-pads when writing the filename. |
| `name` | string | yes | snake_case identifier used in filenames and the integration test module name. |
| `requirement_ids` | list[string] | yes | MUST requirement IDs this migration satisfies. Used by lint to cross-check the requirements doc. |
| `purpose` | string (multi-line) | yes | One-paragraph rationale. Goes into the SQL file header comment. |
| `tables` | list[Table] | yes | One or more tables created or altered. See **Table** below. |
| `fixtures` | list[Fixture] | yes (may be empty) | Per-test fixtures wired into the integration test scaffold. See **Fixture** below. |
| `test_cases` | list[TestCase] | yes (min 1) | One test block per case. See **TestCase** below. |
| `rollback_strategy` | string | yes | Append-only policy reminder; informational. |

---

## Table

| Field | Type | Required | Notes |
|---|---|---|---|
| `mode` | enum: `create`, `alter` | yes | `create` for new tables, `alter` to add columns to existing ones. |
| `name` | string | yes | Unqualified table name. Schema-qualifying (`public.x`) is forbidden — see anti-patterns. |
| `columns` (create) | list[Column] | yes when mode=create | Initial schema. |
| `add_columns` (alter) | list[Column] | yes when mode=alter | Columns to add. Wrapped with `IF NOT EXISTS`. |
| `drop_columns` (alter) | list[string] | no | **Avoid.** Append-only policy. Codegen emits a warning if non-empty. |
| `constraints` | list[Constraint] | no | UNIQUE, CHECK, EXCLUDE, etc. PRIMARY KEY is declared inline on the column instead. |
| `indexes` | list[Index] | no | All indexes are created with `IF NOT EXISTS`. |

### Column

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | snake_case. |
| `type` | string | yes | PostgreSQL type. `uuid`, `text`, `timestamptz`, `jsonb`, etc. Multi-word types must be quoted: `"varchar(64)"`. |
| `pk` | bool | no | `true` adds `PRIMARY KEY` and forces `NOT NULL`. At most one column per table may set this. |
| `not_null` | bool | no | Default `false`. Required (`true`) for FK columns by project convention. |
| `default` | string | no | Raw SQL expression. Do NOT quote string literals here — codegen emits the value verbatim. |
| `fk` | string | no | Format `"<table>(<column>)"`. Codegen renders as `REFERENCES <table>(<column>)` and adds `ON DELETE NO ACTION` by default. |

### Constraint

| Field | Type | Notes |
|---|---|---|
| `kind` | enum: `unique`, `check`, `exclude`, `foreign_key` | |
| `columns` | list[string] | For `unique`. |
| `expression` | string | For `check`. Raw SQL boolean. |
| `name` | string | Optional explicit constraint name. If omitted, PostgreSQL auto-names. Explicit names recommended for tests that match on constraint name. |

### Index

| Field | Type | Notes |
|---|---|---|
| `name` | string | Convention: `idx_<table>_<columns>`. |
| `columns` | list[string] | Index column list. |
| `where` | string | Optional partial-index predicate. |
| `unique` | bool | Optional. |

---

## Fixture

Fixtures are wired into the test's setup block by the codegen. They are accessible inside `arrange` / `act` strings as `fx.<name>`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Identifier used in `fx.<name>`. |
| `kind` | enum: `uuid`, `random_string`, `timestamp_now`, `sql_setup`, `sql_literal` | yes | See below. |
| `sql` | string | when kind=sql_setup | Raw SQL run during setup. `defer` cleanup is auto-generated. |
| `params` | list[string] | when kind=sql_setup | Reference other fixtures by name or supply SQL literals in quotes. |
| `value` | string | when kind=sql_literal | A raw SQL literal value used directly. |

`uuid` produces a fresh `gen_random_uuid()` value per test (every integration test uses per-test UUIDs — see `docs/anti-patterns.md`).

---

## TestCase

Each `TestCase` becomes a Zig `test "<name>" { ... }` block.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Test name (snake_case or human-readable both fine). |
| `description` | string | yes | One-line description; codegen emits as a leading comment. |
| `requirement_ref` | string | yes | MUST ID this test exercises. Lint verifies the ID appears in `requirement_ids`. |
| `arrange` | string (Zig snippet) | no | Goes into the test body before `act`. May reference `fx.*`. |
| `act` | string (Zig snippet) | yes | The action under test. Typically calls a store method. |
| `assertions` | string | yes | Body of the assertions section. **Codegen wraps this content in a `// CUSTOM:` comment block** — assertion logic is human/agent work, never auto-generated. |

---

## Lint rules (enforced by `tools/lint_design_artefact.py` and `tools/codegen_migration.py --dry-run`)

The validator FAILs if any of these are violated:

1. `migration_number` matches an existing file under `migrations/`.
2. `name` is not snake_case.
3. Any `Table.name` includes `public.` or another schema prefix.
4. Any FK target table does not exist in earlier migrations (string match, not authoritative; warning only).
5. Any `Column.default` quotes a string literal incorrectly (codegen tries to detect single-quote balance).
6. `drop_columns` is non-empty for any `alter` table.
7. `test_cases` is empty.
8. Any `test_case.requirement_ref` is not in `requirement_ids`.
9. Any `test_case.assertions` block looks like a real assertion (`try expect...`) instead of a `// CUSTOM:` placeholder — **assertions must be hand-written by the implementer**.

---

## Worked example

- `templates/specs/migration.template.yaml` — full annotated example, fictional `task_priority_overrides`.

Real-codebase candidates that would have been Type C if this template existed:
- `migrations/052_xc03_configuration_repository.sql` (column additions; would have needed `mode: alter` × 1 + create view as Type E)
- `migrations/056_onboarding_registry.sql`
