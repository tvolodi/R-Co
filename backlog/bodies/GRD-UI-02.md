> `web/tests/guards/source-scan.spec.ts` SHALL apply every `PATTERNS` entry whose `appliesTo` is `source` or `both` to `web/src/**/*.{ts,tsx,css}`. A match on a path outside that pattern's `allowedPaths` SHALL fail the gate. `allowedPaths` SHALL be honoured exactly: `raw-fetch-outside-client` permits `web/src/api/client.ts` and `literal-colour` permits `web/src/styles/tokens.css`. The scan SHALL run with no network access and SHALL complete within 30 s. `npm run guards` SHALL be a required status check, so a merge SHALL NOT proceed on a scan failure.

**Acceptance Criteria:**
- GIVEN a file under `web/src/` matching any source-applicable pattern outside its `allowedPaths`, WHEN the scan runs, THEN the gate fails and reports the file path, the line number and the pattern name; this is a pure static scan with no HTTP.
- GIVEN `web/src/api/client.ts` containing a direct `fetch` call, WHEN the scan runs, THEN `raw-fetch-outside-client` does not fire, because that path is the pattern's sole allowed entry.
- GIVEN a component under `web/src/components/` containing a direct `axios` call, WHEN the scan runs, THEN the gate fails with pattern name `raw-fetch-outside-client` and that component's path.
- GIVEN a clean tree, WHEN the scan runs on a machine with no network route, THEN it exits 0 within 30 s, since it reads files and matches regexes and issues no request.
- GIVEN a scan failure, WHEN `npm run guards` reports its exit code, THEN it is non-zero and the required status check blocks the merge.

**See:** GRD-UI-01, GRD-UI-03, GRD-UI-05, CMP-UI-02, CMP-UI-06, CAC-UI-01
