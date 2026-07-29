> Every entry in `PATTERNS` SHALL carry a two-sided META control in `web/tests/guards/meta-control.spec.ts`. The control SHALL assert that the pattern matches `web/tests/guards/fixtures/offender/<pattern>.txt`, a synthetic offender, and that it does not match `web/tests/guards/fixtures/bystander/<pattern>.txt`, an innocent bystander. A pattern added without both fixtures SHALL fail the gate. The META controls SHALL run before the source scan and the bundle scan, so a dead or over-broad guard is reported before its clean result is trusted.

**Acceptance Criteria:**
- GIVEN a pattern whose regex was edited so it no longer matches its offender fixture, WHEN the META control runs, THEN the gate fails naming the pattern as unmatched against its offender; this is a pure static check with no HTTP.
- GIVEN a pattern whose regex was widened so it matches its bystander fixture, WHEN the control runs, THEN the gate fails naming the pattern as over-broad against its bystander.
- GIVEN an entry added to `PATTERNS` with no offender file or no bystander file, WHEN the fixture completeness check runs, THEN the gate fails naming the pattern and the missing fixture path.
- GIVEN the full guard suite, WHEN `npm run guards` executes, THEN the META controls complete within 5 s and run before the source scan and the bundle scan in that order.
- GIVEN `web/tests/guards/fixtures/bystander/native-confirm.txt` containing the identifier `confirmVariant` and a comment about a confirmation dialog, WHEN the `native-confirm` control runs, THEN the pattern does not match it, since it targets `window.confirm` and `window.alert` alone.

**See:** GRD-UI-01, GRD-UI-02, GRD-UI-03, GRD-UI-05
