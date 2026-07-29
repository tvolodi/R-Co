> A guard violation SHALL be reported as `{ file, line, patternName }` and SHALL NOT carry the matched substring or any surrounding source text, so a credential or token caught by a pattern is never printed to a CI log. The same redacted records SHALL be written to `tests/reports/report-<date>-<run_id>.yaml`. A redaction assertion SHALL run over the reporter output as part of the guard suite.

**Acceptance Criteria:**
- GIVEN a source file containing the string `sk-live-0123456789abcdef` that a pattern matches, WHEN the source scan reports the violation, THEN the report contains the file path, the line number and the pattern name and does not contain the matched string; this is a pure static check with no HTTP.
- GIVEN any guard failure, WHEN the reporter output is inspected by the redaction assertion, THEN each record has exactly the keys `file`, `line` and `patternName` and no additional key.
- GIVEN a reporter change that emits the matched content, WHEN the redaction assertion runs, THEN the gate fails before the run report is published.
- GIVEN a completed guard run with violations, WHEN `tests/reports/report-<date>-<run_id>.yaml` is read, THEN it lists the same redacted records in YAML and carries no matched content.
- GIVEN a completed guard run with no violations, WHEN the report is read, THEN the violation list is empty and the report still names every pattern that was evaluated.

**See:** GRD-UI-02, GRD-UI-03, GRD-UI-04, ENV-01
