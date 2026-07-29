> `docs/guides/frontend_design_system.md` §10 SHALL record the architecture rule verbatim: "The SPA is a generic interpreter of server-delivered definitions; it contains no hand-coded screen for any tenant entity." The same section SHALL record the directory contract: `web/src/components/renderers/` holds rendering logic, `web/src/pages/` holds thin route shells, and `web/src/components/canvas/` is definition-authoring only. No file under `web/src/` SHALL contain a tenant slug literal or a branch on tenant identity, which the GRD-UI-01 forbidlist pattern `tenant-slug-in-source` SHALL enforce.

**Acceptance Criteria:**
- GIVEN `docs/guides/frontend_design_system.md`, WHEN §10 is read, THEN it contains the rule sentence above verbatim and the three-directory contract; a pure static documentation check fails on absence.
- GIVEN a file under `web/src/` containing the literal `swiftroute`, `vortex` or `meridian`, WHEN the GRD-UI-02 source scan runs, THEN the scan fails reporting the file path and pattern name `tenant-slug-in-source`; this is a pure static scan with no HTTP.
- GIVEN a file under `web/src/pages/` calling `fetch` or `axios` directly, WHEN the source scan runs, THEN the scan fails with pattern name `raw-fetch-outside-client`, since a route shell reads through `web/src/api/client.ts` alone.
- GIVEN the fixture `web/tests/guards/fixtures/bystander/tenant-slug-in-source.txt` containing the word `vortexes` inside a comment about vector maths, WHEN the GRD-UI-04 META control runs, THEN the pattern does not match it.
- GIVEN a Playwright E2E signs in as SwiftRoute and then as Vortex against the real backend, WHEN the same route is rendered for both, THEN the component tree is identical and the difference between the two screens comes from server-delivered schema and definition payloads alone.

**See:** CMP-UI-05, CMP-UI-04, GRD-UI-01, GRD-UI-02, PD-UI-07
