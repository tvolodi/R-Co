> `web/tests/guards/forbidlist.ts` SHALL be the only file in the repository in which a banned frontend pattern is authored. It SHALL export `PATTERNS: GuardPattern[]` where `GuardPattern` is `{ name, regex, appliesTo: 'source' | 'bundle' | 'both', allowedPaths: string[], rationale }`, and `rationale` SHALL name the directive or requirement the pattern defends. The list SHALL be seeded with `msw-import`, `http-mock-adapter`, `raw-fetch-outside-client`, `literal-colour`, `native-confirm`, `tenant-slug-in-source`, `inline-query-key`, `inline-stale-time`, `missing-query-state-boundary` and `test-only-or-skip`. Both the source scan and the bundle scan SHALL import from this module and SHALL declare no regex of their own.

**Acceptance Criteria:**
- GIVEN `web/tests/guards/source-scan.spec.ts` and `web/tests/guards/bundle-scan.spec.ts`, WHEN each is parsed, THEN neither contains a regular expression literal and both import `PATTERNS` from `forbidlist.ts`; this is a pure static check with no HTTP.
- GIVEN every entry in `PATTERNS`, WHEN the schema check runs, THEN each carries a non-empty `name`, `regex`, `appliesTo`, `allowedPaths` and `rationale`, and each `rationale` names a directive or a requirement ID.
- GIVEN the ten seed pattern names above, WHEN `PATTERNS` is read, THEN each is present exactly once and no name is duplicated.
- GIVEN the pattern `msw-import` whose `rationale` cites DIRECTIVE T-2, WHEN it is applied, THEN it matches an import of `msw`, `msw/node` or `setupServer`, since R-Co forbids MSW and every form of HTTP mocking outright.
- GIVEN a regex declared in any file under `web/tests/guards/` other than `forbidlist.ts`, WHEN the single-source assertion runs, THEN it fails naming that file.

**See:** GRD-UI-02, GRD-UI-03, GRD-UI-04, GRD-UI-05, CMP-UI-02
