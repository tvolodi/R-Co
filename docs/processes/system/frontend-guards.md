# Process: Frontend Architecture and Accessibility Guards

| Field | Value |
|-------|-------|
| Process ID | `sys-frontend-guards` |
| Platform Workflow | PW-16 |
| Owner | Frontend Platform Team / CI |
| Scope | System-wide (`web/src/`, `web/dist/`, `web/tests/guards/`, `web/tests/e2e/a11y/`) |
| Requirements | GRD-UI-01, GRD-UI-02, GRD-UI-03, GRD-UI-04, GRD-UI-05, GRD-UI-06, GRD-UI-07 |
| Source | `docs/workflows.yaml` (PW-16) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §3.4, §3.5 |

## Summary

Replaces reviewer judgement with executable gates. One forbidlist module is the
single source of truth for every banned pattern; a source scan and a post-build
bundle scan both consume it, so a pattern cannot be enforced in source and
smuggled through a dependency. Each pattern carries a META control proving the
guard still catches a synthetic offender and still ignores an innocent
bystander. An accessibility gate runs axe against each canonical surface in a
real browser and fails on any serious or critical violation.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| CI gate | System (GitHub Actions, `npm run guards`) | Runs the source scan, the bundle scan, the META controls and the a11y gate; blocks the merge on any failure |
| FRONTEND-DEV | Agent | Owns the forbidlist, fixes violations, adds a pattern with its META control before adding the rule |
| Vite build | System | Produces `web/dist/assets/*.js` that the bundle scan reads |
| axe-core | System (`@axe-core/playwright`) | Reports violations by impact level against a live Chromium page |
| ORCH | Agent | Routes a guard BLOCKER to FRONTEND-DEV through WF-03 |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `web/tests/guards/forbidlist.ts` | TypeScript module | Exports `PATTERNS: GuardPattern[]`; the only place a pattern is authored |
| `GuardPattern` | object | `{ name, regex, appliesTo: 'source' \| 'bundle' \| 'both', allowedPaths: string[], rationale }` |
| Source tree | files | `web/src/**/*.{ts,tsx,css}` |
| Bundle tree | files | `web/dist/assets/*.js` produced by a real `vite build` |
| META fixtures | files | `web/tests/guards/fixtures/offender/<pattern>.txt`, `web/tests/guards/fixtures/bystander/<pattern>.txt` |
| Canonical surfaces | list | Task Inbox, Instance List, Instance Detail, Definition List, Process Designer, Login |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | FRONTEND-DEV | Author every banned pattern in `web/tests/guards/forbidlist.ts` | Is a regex declared anywhere else in the repository? | A second declaration site fails the single-source assertion in step 3 | GRD-UI-01 |
| 2 | FRONTEND-DEV | Seed the list with `msw-import`, `http-mock-adapter`, `raw-fetch-outside-client`, `literal-colour`, `native-confirm`, `tenant-slug-in-source`, `inline-query-key`, `inline-stale-time`, `missing-query-state-boundary`, `test-only-or-skip` | Every pattern carries a `rationale` naming the directive or requirement it defends? | Missing rationale fails the forbidlist schema check | GRD-UI-01 |
| 3 | CI gate | Assert `forbidlist.ts` is the sole import source for both scans | Either scan defines its own regex? | BLOCKER; the scan is rewritten to import from the forbidlist | GRD-UI-01 |
| 4 | CI gate | Run `web/tests/guards/source-scan.spec.ts` over `web/src/**` for every pattern with `appliesTo` `source` or `both` | Match outside `allowedPaths`? | Failure reporting the file path, line number and pattern name | GRD-UI-02 |
| 5 | CI gate | Honour `allowedPaths` exactly: `raw-fetch-outside-client` permits `web/src/api/client.ts`; `literal-colour` permits `web/src/styles/tokens.css` | Path listed? | Listed path is skipped; every other path is scanned | GRD-UI-02 |
| 6 | CI gate | Run `web/tests/guards/bundle-scan.spec.ts`: `rmSync('web/dist', { recursive: true, force: true })`, then a real `vite build`, then scan `web/dist/assets/*.js` | Did the build produce assets? | Empty `dist/` fails the scan rather than passing vacuously | GRD-UI-03 |
| 7 | CI gate | Apply every pattern with `appliesTo` `bundle` or `both` to the emitted chunks | Match found? | Failure naming the chunk file and the pattern; catches a banned module pulled in through a dependency | GRD-UI-03 |
| 8 | CI gate | Run `web/tests/guards/meta-control.spec.ts` for each pattern against its offender fixture | Guard matches the offender? | A guard that misses its offender fails the META control; the pattern is dead and the gate blocks | GRD-UI-04 |
| 9 | CI gate | Run the same guard against its bystander fixture | Guard matches the bystander? | A match on the bystander fails the META control; the pattern is over-broad and the gate blocks | GRD-UI-04 |
| 10 | CI gate | Assert every entry in `PATTERNS` has both fixtures present | Fixture missing? | Failure naming the pattern; a pattern cannot be added without its control | GRD-UI-04 |
| 11 | CI gate | Emit guard failures as `{ file, line, patternName }` only | Does the report contain the matched substring or surrounding source? | Any content in the report fails the redaction assertion; a secret matched by a pattern is never printed to CI logs | GRD-UI-05 |
| 12 | CI gate | Write the same redacted records to `tests/reports/report-<date>-<run_id>.yaml` | - | Report lists path, line and pattern name for each violation | GRD-UI-05 |
| 13 | CI gate | Run `web/tests/e2e/a11y/<surface>.a11y.e2e.spec.ts` per canonical surface against the real backend | Any violation with impact `serious` or `critical`? | Gate fails listing rule ID, impact and target selector | GRD-UI-06 |
| 14 | CI gate | Keep the `color-contrast` rule enabled | Real Chromium available? | R-Co runs axe through Playwright, so pixel measurement works and `color-contrast` is not disabled | GRD-UI-06 |
| 15 | CI gate | Treat `moderate` and `minor` violations as reported, not blocking | - | Recorded in the run report; routed to WF-03 at severity MINOR | GRD-UI-06 |
| 16 | FRONTEND-DEV | Wire per-field ARIA in `DynamicFormRenderer` and `FieldFactory`: `<label htmlFor>`, `aria-required`, `aria-describedby` to the hint node, `aria-invalid` plus `aria-errormessage` to the error node, `aria-busy` on the form during submit | Every generated field carries the full set? | A field missing any attribute fails the ARIA assertion on the Task Inbox surface | GRD-UI-07 |
| 17 | CI gate | Assert the error node referenced by `aria-errormessage` exists in the DOM whenever `aria-invalid="true"` | Reference dangles? | Failure naming the field key | GRD-UI-07 |
| 18 | ORCH | Route any guard or a11y BLOCKER to FRONTEND-DEV | Fix merged? | Re-run `npm run guards`; the gate clears only when all four suites exit 0 | GRD-UI-02 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Single source of truth | `web/tests/guards/forbidlist.ts` is the only file where a banned pattern is authored; both scans import it |
| Two scans, one list | The source scan proves the repository is clean; the bundle scan proves the shipped artefact is clean, including code arriving through dependencies |
| Real build | The bundle scan deletes `web/dist/` and runs a real `vite build`; it never reads a stale or cached bundle |
| No pattern without a control | Adding an entry to `PATTERNS` without both fixtures fails the gate |
| Control is two-sided | Each META control asserts a match on the synthetic offender and no match on the innocent bystander |
| Redacted reporting | Guard output carries file path, line number and pattern name; it never carries the matched content |
| Serious and critical block | Any axe violation at `serious` or `critical` fails the a11y gate; `moderate` and `minor` are reported at severity MINOR |
| Contrast stays on | `color-contrast` runs because the gate executes in a real Chromium page, not in jsdom |
| ARIA is generated | The five ARIA attributes are emitted by `FieldFactory`, not hand-written per screen, so a new field type inherits them |
| Test substrate | DIRECTIVE T-2 forbids MSW and every form of HTTP mocking; the scans are pure static and bundle analysis with no HTTP, and the a11y gate is a Playwright E2E against the real backend |
| Guards are not advisory | `npm run guards` is a required status check; a merge does not proceed on a guard failure |

---

## Outputs

| Output | Description |
|--------|-------------|
| `web/tests/guards/forbidlist.ts` | `PATTERNS` and the `GuardPattern` type |
| `web/tests/guards/source-scan.spec.ts` | Source scan over `web/src/**` |
| `web/tests/guards/bundle-scan.spec.ts` | `rmSync` + real `vite build` + chunk scan |
| `web/tests/guards/meta-control.spec.ts` | Two-sided control per pattern |
| `web/tests/guards/fixtures/offender/`, `.../bystander/` | Synthetic offender and innocent bystander per pattern |
| `web/tests/e2e/a11y/*.a11y.e2e.spec.ts` | One spec per canonical surface using `@axe-core/playwright` |
| `tests/reports/report-<date>-<run_id>.yaml` | Redacted violation records and axe results |
| `tests/specs/PIPELINE-frontend-guards.md` | Step table mapping each guard suite to GRD-UI-01..07 |
| `package.json` script `guards` | Runs source scan, bundle scan, META controls and the a11y gate in that order |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Source scan runtime | Completes within 30 s; it reads files and matches regexes with no network access |
| Bundle scan runtime | Dominated by `vite build`; budgeted at 180 s including the `rmSync` |
| META control runtime | Completes within 5 s; it runs before the two scans so a dead guard is reported first |
| A11y gate runtime | Six surfaces at 30 s each; requires Keycloak, PostgreSQL and the API to be healthy |
| Services unavailable | The a11y gate returns FAIL with severity BLOCKER; ORCH dispatches an ADHOC BACKEND-DEV handoff to start services and redispatches |
| Escalation | Any guard BLOCKER routes to FRONTEND-DEV through WF-03; the fix commit includes the pattern's META control result |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| Dead guard | A pattern no longer matches its offender fixture after a regex edit | META control fails; the regex is repaired before the scans are trusted |
| Over-broad guard | A pattern matches its bystander fixture | META control fails; `allowedPaths` or the regex is narrowed |
| Missing fixture | A pattern added without an offender or bystander file | Gate fails naming the pattern; the fixture pair is added in the same commit |
| Empty bundle | `vite build` produces no assets after `rmSync` | Bundle scan fails rather than passing on an empty directory; the build error is fixed first |
| Banned module via dependency | A transitive package pulls MSW into a chunk | Source scan passes, bundle scan fails naming the chunk and `msw-import`; the dependency is replaced or the import is pruned |
| Content leaked in a report | A guard prints the matched substring | Redaction assertion fails; the reporter is corrected before the run report is published |
| Dangling `aria-errormessage` | A field sets `aria-invalid="true"` with no matching error node | ARIA assertion fails naming the field key; `FieldFactory` is corrected once for all field types |
| Backend down during a11y | Keycloak or the API is unreachable | Gate returns BLOCKER with the service names; ORCH starts services through an ADHOC handoff and redispatches |
| Contrast failure after a brand override | A tenant brand token fails 4.5:1 against `--surface-card` | `color-contrast` reports a serious violation; the tenant brand value is rejected at bootstrap per PW-14 |
