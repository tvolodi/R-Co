> No file under `web/src/` other than `web/src/styles/tokens.css` SHALL contain a literal colour value. The forbidden forms are a six-digit or three-digit hex literal, an `rgb(` or `rgba(` call, and an `hsl(` or `hsla(` call. Component code SHALL reference colour through `var(--color-*)`, `var(--surface-*)`, `var(--text-*)`, `var(--border-*)` or `var(--interactive-*)`. The rule SHALL be enforced by the GRD-UI-01 forbidlist pattern `literal-colour` in both the source scan and the post-build bundle scan.

**Acceptance Criteria:**
- GIVEN a `.ts`, `.tsx` or `.css` file under `web/src/` outside `web/src/styles/tokens.css` containing `#339af0`, WHEN the GRD-UI-02 source scan runs, THEN the scan fails reporting the file path, the line number and pattern name `literal-colour`; this is a pure static scan with no HTTP.
- GIVEN `web/src/styles/tokens.css`, WHEN the same scan runs, THEN the file is skipped because it is the sole entry in the pattern's `allowedPaths`.
- GIVEN a dependency injects an inline `rgba(` style into a shipped chunk, WHEN the GRD-UI-03 bundle scan runs over `web/dist/assets/*.js`, THEN the scan fails naming the chunk and pattern name `literal-colour`; this is a pure post-build scan with no HTTP.
- GIVEN the fixture `web/tests/guards/fixtures/offender/literal-colour.txt`, WHEN the GRD-UI-04 META control runs, THEN the pattern matches it; and GIVEN `web/tests/guards/fixtures/bystander/literal-colour.txt` holding `var(--color-brand-600)` and the string `#hash-anchor`, WHEN the control runs, THEN the pattern does not match it.
- GIVEN a Playwright E2E loads the Definition List against the real backend, WHEN the computed background of a `StatusBadge` with `status="ACTIVE"` is read, THEN it equals the resolved value of `--color-success-light`.

**See:** CMP-UI-01, CMP-UI-03, GRD-UI-01, GRD-UI-02, GRD-UI-03, GRD-UI-04
