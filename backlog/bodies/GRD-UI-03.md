> `web/tests/guards/bundle-scan.spec.ts` SHALL delete the build output with `rmSync('web/dist', { recursive: true, force: true })`, run a real `vite build`, and apply every `PATTERNS` entry whose `appliesTo` is `bundle` or `both` to `web/dist/assets/*.js`. The scan SHALL fail rather than pass when the build produces no assets, so an empty directory cannot yield a vacuous pass. The bundle scan exists because a banned module can enter the shipped artefact through a dependency without appearing in `web/src/`.

**Acceptance Criteria:**
- GIVEN a populated `web/dist/` from an earlier run, WHEN the scan starts, THEN the directory is deleted before `vite build` runs, so no stale chunk is scanned; this is a pure post-build scan with no HTTP.
- GIVEN `vite build` produces no file under `web/dist/assets/`, WHEN the scan evaluates its input set, THEN the gate fails naming the empty output rather than reporting zero violations.
- GIVEN a transitive dependency that bundles `msw` into a chunk while no file under `web/src/` imports it, WHEN the scan runs, THEN the source scan passes, the bundle scan fails naming the chunk file and pattern name `msw-import`, and the merge is blocked.
- GIVEN a chunk containing an inline `rgba(` literal injected by a dependency, WHEN the scan runs, THEN the gate fails with pattern name `literal-colour` and the chunk file name.
- GIVEN a clean build, WHEN the scan runs, THEN it exits 0 within a 180 s budget covering the `rmSync` and the `vite build`.

**See:** GRD-UI-01, GRD-UI-02, GRD-UI-04, GRD-UI-05, CMP-UI-02
