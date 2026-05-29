# tools/ — Pipeline support scripts

This directory holds Python utilities used by the multi-agent pipeline. They fall into three buckets:

| Bucket | Files | Used by |
|---|---|---|
| **Linters** | `lint_design_artefact.py`, `lint_frontend_conventions.py`, `lint_test_isolation.py` | CODE-DESIGN-VALIDATOR, TEST-DESIGN-VALIDATOR, BACKEND-DEV / FRONTEND-DEV self-review |
| **Codegen** | `codegen_migration.py`, `codegen_error_mapper.py`, `codegen_crud_endpoint.py`, `codegen_list_page.py`, `codegen_react_flow_node.py` | BACKEND-DEV / FRONTEND-DEV (run against `templates/specs/*.yaml`) |
| **Pipeline ops** | `create_*_handoffs.py`, `retro_*.py`, `clean_test_db.py` | ORCH (handoff creation), DOC-UPDATER (retrospectives), TEST-RUNNER (DB cleanup) |

---

## Linters

All linters share a common pattern: zero issues = exit 0, any BLOCKER/MAJOR = exit 1, MINOR-only = exit 0. Add `--json` for machine-readable output.

### `lint_design_artefact.py`

Validates design artefacts before BACKEND-DEV / FRONTEND-DEV picks them up.

```bash
python3 tools/lint_design_artefact.py src/design/api-02-definition-crud.md
python3 tools/lint_design_artefact.py templates/specs/oidc35.crud-endpoint.yaml
python3 tools/lint_design_artefact.py --all      # everything under src/design/ + templates/specs/
```

Issue code prefixes:
- `E0xx` — markdown design artefact (Type E)
- `Y1xx` — migration YAML (Type C)
- `Y2xx` — CRUD endpoint YAML (Type A)
- `Y3xx` — list page YAML (Type B)
- `Y4xx` — React Flow node YAML (Type D)

### `lint_frontend_conventions.py`

Enforces frontend conventions in `web/src/` and `web/tests/`.

```bash
python3 tools/lint_frontend_conventions.py
python3 tools/lint_frontend_conventions.py --json
```

Issue codes: `F010` raw fetch/axios, `F020` MSW reference (BLOCKER), `F030` inline query keys, `F040` test.skip in Playwright spec (BLOCKER), `F050` disabled-instead-of-hidden role gating.

### `lint_test_isolation.py`

Enforces fixture isolation in `tests/integration/`.

```bash
python3 tools/lint_test_isolation.py
python3 tools/lint_test_isolation.py tests/integration/xc03_configuration_repository_test.zig
```

Issue codes: `T010` hardcoded UUID, `T020` module-level mutable var, `T030` allocation without defer, `T040` skip on MUST (BLOCKER), `T050` integration test missing BPM_TEST_DB_URL reference.

---

## Codegen

Each `codegen_*.py` script reads a YAML spec from `templates/specs/` and emits a target source file. All codegen scripts share these flags:

```bash
python3 tools/codegen_migration.py templates/specs/myfeature.migration.yaml
python3 tools/codegen_migration.py templates/specs/myfeature.migration.yaml --dry-run
python3 tools/codegen_migration.py templates/specs/myfeature.migration.yaml --output-dir migrations/
```

`--dry-run` prints the generated content to stdout without writing. CODE-DESIGN-VALIDATOR uses this mode to preview output during review.

Generated files contain `CUSTOM:` blocks that the implementer fills in. Do not edit outside `CUSTOM:` blocks — if the boilerplate is wrong, change the template instead and regenerate.

---

## Conventions for new tools

1. Single-file Python scripts. No third-party deps beyond PyYAML.
2. Run from the repo root: `python3 tools/<name>.py`.
3. `--json` flag for machine output; default output is human-readable.
4. Exit 0 on success, 1 on detected issues, 2 on bad invocation.
5. Cite line numbers as `file:line` so editors can jump to them.
6. Do not write to the filesystem outside the directory the user asked for (codegen takes an explicit `--output-dir`; lints never write).
