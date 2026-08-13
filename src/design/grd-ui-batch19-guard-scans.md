# Design: GRD-UI Guard Scan Infrastructure (Batch 19)

**Requirements:** GRD-UI-01 (prerequisite, inline), GRD-UI-02, GRD-UI-03, GRD-UI-04, GRD-UI-05  
**Type:** E — Novel / cross-cutting frontend infrastructure  
**Stage:** F8  
**Run:** WF02-grd-ui-batch19-20260813  

---

## 1. Module Purpose

This design covers the complete guard-scan infrastructure for the BPM Platform frontend.
The system enforces architectural invariants at CI time by scanning source files and the built
bundle for patterns that violate directives (no MSW, no direct fetch outside the API client,
no inline colour literals, etc.). Every banned pattern is authored exactly once in a central
forbidlist; all scans import from that single source of truth. Violations are reported with
redacted output (file + line + pattern name only — no matched content) and written to a dated
YAML report.

The execution order for `npm run guards` is fixed:

```
meta-control (≤ 5 s)  →  source-scan (≤ 30 s)  →  bundle-scan (≤ 180 s)
```

A failure at any stage blocks the merge via a required status check.

---

## 2. File Map

| File | Created by | Purpose |
|---|---|---|
| `web/tests/guards/forbidlist.ts` | GRD-UI-01 | Single source of truth for all banned patterns |
| `web/tests/guards/source-scan.spec.ts` | GRD-UI-02 | Static scan of web/src/**/*.{ts,tsx,css} |
| `web/tests/guards/bundle-scan.spec.ts` | GRD-UI-03 | Post-build scan of web/dist/assets/*.js |
| `web/tests/guards/meta-control.spec.ts` | GRD-UI-04 | Two-sided META control for every pattern |
| `web/tests/guards/reporter.ts` | GRD-UI-05 | Redacted violation reporter + YAML writer |
| `web/tests/guards/fixtures/offender/<pattern>.txt` | GRD-UI-04 | Synthetic text that MUST match the pattern |
| `web/tests/guards/fixtures/bystander/<pattern>.txt` | GRD-UI-04 | Synthetic text that MUST NOT match the pattern |

> **Open Question OQ-1 (path conflict):** The requirement body for GRD-UI-01 names the forbidlist
> at `web/tests/guards/forbidlist.ts`. The handoff task description names it at `web/src/guards/forbidlist.ts`.
> This design uses the requirement-authoritative path (`web/tests/guards/forbidlist.ts`). If
> ORCH intended `web/src/guards/`, the requirement must be amended before BACKEND-DEV implements.

---

## 3. GRD-UI-01 Prerequisite — `web/tests/guards/forbidlist.ts`

### 3.1 Type Shape

```typescript
// Shape only — no implementation values
type Applicability = 'source' | 'bundle' | 'both';

interface GuardPattern {
  /** Unique kebab-case identifier used in violation reports and fixture file names. */
  name: string;
  /** The regular expression applied to file content. No regex literals appear outside this file. */
  regex: RegExp;
  /** Which scan phases apply this pattern. */
  appliesTo: Applicability;
  /**
   * Workspace-relative paths excluded from enforcement.
   * An empty array means no exclusions.
   * Paths are compared with String.startsWith against the normalised file path.
   */
  allowedPaths: string[];
  /** Directive ID or requirement ID that this pattern defends. Must be non-empty. */
  rationale: string;
}

export type { GuardPattern, Applicability };
export declare const PATTERNS: GuardPattern[];
```

### 3.2 Seed Pattern Catalogue

Ten patterns required by GRD-UI-01. The `regex` column describes the semantic intent; the
implementor writes the actual `RegExp` literal.

| # | `name` | `appliesTo` | `allowedPaths` | `rationale` | Regex intent |
|---|---|---|---|---|---|
| 1 | `msw-import` | `both` | `[]` | `DIRECTIVE T-2` | matches `import … from 'msw'`, `from 'msw/node'`, or reference to `setupServer` |
| 2 | `http-mock-adapter` | `both` | `[]` | `DIRECTIVE T-2` | matches `import … from 'axios-mock-adapter'` or `new MockAdapter` |
| 3 | `raw-fetch-outside-client` | `source` | `['web/src/api/client.ts']` | `CMP-UI-02` | matches bare `fetch(` or `axios(` call (not an import statement) |
| 4 | `literal-colour` | `both` | `['web/src/styles/tokens.css']` | `CMP-UI-06` | matches hex colour literals (`#[0-9a-fA-F]{3,8}\b`) or `rgba?(` or `hsl?(` outside tokens |
| 5 | `native-confirm` | `source` | `[]` | `CMP-UI-02` | matches `window\.confirm(`, `window\.alert(`, `window\.prompt(` — does NOT match `confirmVariant` |
| 6 | `tenant-slug-in-source` | `source` | `[]` | `CAC-UI-01` | matches hard-coded tenant slug string literals (pattern defined in terms of the known slug format) |
| 7 | `inline-query-key` | `source` | `['web/src/api/queryKeys.ts']` | `CAC-UI-01` | matches an inline string array used as a TanStack Query `queryKey` outside the keys catalogue |
| 8 | `inline-stale-time` | `source` | `['web/src/api/queryKeys.ts']` | `CAC-UI-01` | matches `staleTime:` with a numeric literal outside the keys catalogue |
| 9 | `missing-query-state-boundary` | `source` | `[]` | `GRD-UI-02` | matches a component that calls `useQuery` but is not wrapped in a Suspense / ErrorBoundary import |
| 10 | `test-only-or-skip` | `source` | `[]` | `DIRECTIVE T-1` | matches `it.only(`, `test.only(`, `describe.only(`, `it.skip(`, `test.skip(` in non-fixture source |

> **Note on `status-read-outside-classifier`:** the handoff task description lists this as an
> initial pattern. It does not appear in GRD-UI-01's seed list. It is recorded here as
> **Open Question OQ-2** — the requirement must be amended to add it, or ORCH must remove the
> reference from the task description before implementation.

### 3.3 Invariant: no regex elsewhere

No file under `web/tests/guards/` other than `forbidlist.ts` may contain a `RegExp` literal
or a `new RegExp(...)` expression. `meta-control.spec.ts` and the two scan specs read
`PATTERNS[n].regex` by reference. The meta-control suite itself enforces this invariant
by asserting the source text of every other guards file against a regex-detector.

---

## 4. GRD-UI-02 — `web/tests/guards/source-scan.spec.ts`

### 4.1 Violation Record Shape

```typescript
interface Violation {
  file: string;        // normalised workspace-relative path, e.g. "web/src/components/Foo.tsx"
  line: number;        // 1-based line number of the first match on that line
  patternName: string; // GuardPattern.name — never contains matched content
  // NO additional keys — enforced by the redaction assertion in reporter.ts
}
```

### 4.2 File-walking Contract

| Concern | Decision |
|---|---|
| Glob pattern | `web/src/**/*.{ts,tsx,css}` relative to workspace root |
| Glob library | `fast-glob` (add to `devDependencies` if absent) or `node:fs` recursive walk |
| Encoding | `utf8` |
| Network | none — pure filesystem read |
| Timeout | 30 000 ms (vitest `timeout` per test) |

### 4.3 Scan Algorithm (structure, no code)

```
for each pattern in PATTERNS where appliesTo in ['source', 'both']:
  for each file in glob(web/src/**/*.{ts,tsx,css}):
    normalise file path to workspace-relative
    if file starts with any entry in pattern.allowedPaths → skip
    for each line (1-based) in file content:
      if pattern.regex.test(line):
        push Violation { file, line, patternName: pattern.name }
reporter.writeViolations(violations, runId)
assert violations.length === 0
```

### 4.4 allowedPaths Semantics

- Comparison: `normalisedFilePath.startsWith(allowedEntry)` where both sides are forward-slash
  separated and lower-cased on case-insensitive file systems.
- An `allowedPaths` entry of `'web/src/api/client.ts'` exempts that exact file.
- An entry ending in `/` exempts a whole directory subtree.

---

## 5. GRD-UI-03 — `web/tests/guards/bundle-scan.spec.ts`

### 5.1 Build-then-Scan Contract

```
Phase 1 — clean:
  rmSync('web/dist', { recursive: true, force: true })   // node:fs

Phase 2 — build:
  spawnSync or execSync: npm run build    // cwd: web/  — inherits stdio
  exit non-zero → gate fails, no scan

Phase 3 — discover:
  assetFiles = glob('web/dist/assets/*.js')
  if assetFiles.length === 0 → gate fails with "no build assets found" (GRD-UI-03 empty guard)

Phase 4 — scan:
  for each pattern in PATTERNS where appliesTo in ['bundle', 'both']:
    for each file in assetFiles:
      if pattern.regex.test(fileContent):
        push Violation { file, line: 0, patternName: pattern.name }
        // line: 0 = not applicable for minified bundles
  reporter.writeViolations(violations, runId)
  assert violations.length === 0
```

> **Note on `line` in bundle violations:** minified assets do not have meaningful line numbers.
> The violation record MUST still include a `line` key (value `0` or `1`) to satisfy the
> `Violation` shape and the redaction assertion. This keeps the reporter shape uniform.

### 5.2 Timeout

180 000 ms (vitest `timeout` per test), covering `rmSync` + `vite build` + scan.

---

## 6. GRD-UI-04 — `web/tests/guards/meta-control.spec.ts`

### 6.1 Fixture Layout

```
web/tests/guards/fixtures/
├── offender/
│   ├── msw-import.txt
│   ├── http-mock-adapter.txt
│   ├── raw-fetch-outside-client.txt
│   ├── literal-colour.txt
│   ├── native-confirm.txt
│   ├── tenant-slug-in-source.txt
│   ├── inline-query-key.txt
│   ├── inline-stale-time.txt
│   ├── missing-query-state-boundary.txt
│   └── test-only-or-skip.txt
└── bystander/
    ├── msw-import.txt
    ├── http-mock-adapter.txt
    ├── raw-fetch-outside-client.txt
    ├── literal-colour.txt
    ├── native-confirm.txt        // contains "confirmVariant" — must NOT match
    ├── tenant-slug-in-source.txt
    ├── inline-query-key.txt
    ├── inline-stale-time.txt
    ├── missing-query-state-boundary.txt
    └── test-only-or-skip.txt
```

Fixture files are **plain text** (UTF-8, no TypeScript syntax required). Their content is a
minimal synthetic snippet containing the offending or innocent construct — enough to exercise
the regex, nothing more.

### 6.2 Meta-Control Test Structure

```
for each pattern in PATTERNS:

  test `${pattern.name}: offender fixture exists`
    assert readFileSync(offenderPath) does not throw ENOENT

  test `${pattern.name}: bystander fixture exists`
    assert readFileSync(bystanderPath) does not throw ENOENT

  test `${pattern.name}: regex matches offender`
    content = readFileSync(offenderPath, 'utf8')
    assert pattern.regex.test(content) === true

  test `${pattern.name}: regex does NOT match bystander`
    content = readFileSync(bystanderPath, 'utf8')
    assert pattern.regex.test(content) === false

test: no regex literals in scan files (single-source invariant)
  for each file in [source-scan.spec.ts, bundle-scan.spec.ts]:
    sourceText = readFileSync(file, 'utf8')
    assert sourceText does not contain a RegExp literal (/.../)
    assert sourceText does not contain 'new RegExp('
```

### 6.3 Timeout

5 000 ms. Meta controls are pure filesystem reads with no build step.

---

## 7. GRD-UI-05 — `web/tests/guards/reporter.ts`

### 7.1 Violation Shape (canonical)

This is the authoritative definition. All other references to `Violation` in this design
resolve to this shape.

```typescript
interface Violation {
  file: string;        // workspace-relative path
  line: number;        // 1-based; 0 for bundle violations where line is not applicable
  patternName: string; // GuardPattern.name
  // MUST NOT contain: matchedText, snippet, context, content, raw, or any superset key
}
```

### 7.2 Run Report Shape

```typescript
interface RunReport {
  runId: string;              // value of env GUARD_RUN_ID; falls back to ISO timestamp
  date: string;               // YYYY-MM-DD UTC
  evaluatedPatterns: string[]; // name of EVERY pattern evaluated, even those with zero hits
  violations: Violation[];    // empty array when clean
}
```

### 7.3 Reporter Interface (exported, no bodies)

```typescript
/**
 * Write violations to tests/reports/report-<date>-<runId>.yaml.
 * Serialises RunReport as YAML. No matched content is written.
 */
export declare function writeViolations(
  violations: Violation[],
  evaluatedPatterns: string[],
  runId: string,
): void;

/**
 * Assert that every entry in violations has exactly the keys: file, line, patternName.
 * Throws if any entry carries an additional key or is missing a required key.
 * Called by source-scan and bundle-scan after collecting results.
 */
export declare function assertRedacted(violations: Violation[]): void;
```

### 7.4 Report File Path

```
tests/reports/report-<date>-<runId>.yaml
```

- `<date>` = `YYYY-MM-DD` in UTC (from `new Date().toISOString().slice(0,10)`)
- `<runId>` = value of `process.env.GUARD_RUN_ID` if set; otherwise the same ISO timestamp slug

### 7.5 YAML Report Schema (structure)

```yaml
runId: "WF02-grd-ui-batch19-20260813"
date: "2026-08-13"
evaluatedPatterns:
  - msw-import
  - http-mock-adapter
  - raw-fetch-outside-client
  - literal-colour
  - native-confirm
  - tenant-slug-in-source
  - inline-query-key
  - inline-stale-time
  - missing-query-state-boundary
  - test-only-or-skip
violations: []    # or a list of { file, line, patternName } records
```

YAML library: use `js-yaml` (add to `devDependencies` if absent).

---

## 8. `npm run guards` Script

Add to `web/package.json` under `"scripts"`:

```json
"guards": "vitest run tests/guards/meta-control.spec.ts tests/guards/source-scan.spec.ts tests/guards/bundle-scan.spec.ts --reporter=verbose"
```

The three spec files are listed in dependency order (meta first, bundle last). Vitest runs them
sequentially in the order given. The `GUARD_RUN_ID` environment variable SHOULD be set by CI
before invoking this script; reporter falls back to a timestamp slug if absent.

---

## 9. Data Flow Diagram

```
                  ┌──────────────────────────────────┐
                  │  web/tests/guards/forbidlist.ts   │
                  │  PATTERNS: GuardPattern[]         │
                  └────────────┬─────────────────────┘
                               │  import PATTERNS (read-only)
          ┌────────────────────┼────────────────────────┐
          │                    │                         │
          ▼                    ▼                         ▼
  meta-control.spec.ts  source-scan.spec.ts    bundle-scan.spec.ts
  reads fixtures        walks web/src/**        rmSync(web/dist)
          │             *.{ts,tsx,css}           vite build
          │                    │                 web/dist/assets/*.js
          │                    │                         │
          │             Violation[]              Violation[]
          │                    │                         │
          │                    └────────────┬────────────┘
          │                                 │
          │                                 ▼
          │                    web/tests/guards/reporter.ts
          │                    assertRedacted(violations)
          │                    writeViolations(...)
          │                                 │
          │                                 ▼
          │                    tests/reports/report-<date>-<runId>.yaml
          │
  fixture completeness
  + regex match/no-match
  assertions (no output file)
```

---

## 10. Dependencies (new packages to add to `web/package.json` devDependencies)

| Package | Version constraint | Purpose |
|---|---|---|
| `fast-glob` | `^3.3.0` | File globbing in source-scan and bundle-scan (if `node:fs` recursive walk is not preferred) |
| `js-yaml` | `^4.1.0` | YAML serialisation in reporter.ts |
| `@types/js-yaml` | `^4.0.0` | TypeScript types for js-yaml |

> The implementor may use `node:fs`'s `readdirSync` with `{ recursive: true }` (Node 18.17+)
> instead of `fast-glob`; in that case `fast-glob` is not required. Confirm the Node version
> available in CI before choosing.

---

## 11. Error Taxonomy

| Error Code | Trigger | Behaviour |
|---|---|---|
| `E-GUARD-01` | Pattern regex does not match its offender fixture | `meta-control` gate fails naming pattern + fixture path |
| `E-GUARD-02` | Pattern regex matches its bystander fixture | `meta-control` gate fails naming pattern + fixture path |
| `E-GUARD-03` | Offender or bystander fixture file missing | `meta-control` gate fails naming pattern + missing path |
| `E-GUARD-04` | Regex literal found in a non-forbidlist guards file | `meta-control` single-source assertion fails naming the file |
| `E-GUARD-05` | Source file matches a pattern outside its `allowedPaths` | `source-scan` gate fails; violation record emitted |
| `E-GUARD-06` | Bundle asset matches a pattern | `bundle-scan` gate fails; violation record emitted |
| `E-GUARD-07` | `web/dist/assets/` is empty after vite build | `bundle-scan` gate fails with "no build assets found" |
| `E-GUARD-08` | `vite build` exits non-zero | `bundle-scan` gate fails before scan phase |
| `E-GUARD-09` | Violation record carries a key other than `{file, line, patternName}` | `reporter.assertRedacted` throws before report is written |

---

## 12. Files NOT to Change

The guard infrastructure is additive. The following files MUST NOT be modified:

- `web/src/**` — all application source files (no guard logic in src/)
- `web/vite.config.ts` — build configuration unchanged
- `web/tsconfig.json`, `web/tsconfig.app.json`, `web/tsconfig.node.json` — TypeScript config unchanged
- Any existing test files outside `web/tests/guards/`
- `tests/reports/` — written to by reporter; never hand-edited

---

## 13. Acceptance Criteria Cross-Reference

| Acceptance Criterion (from handoff) | Satisfied by Section |
|---|---|
| `src/design/grd-ui-batch19-guard-scans.md` created | This document |
| GRD-UI-01 PATTERNS structure specified inline | §3 |
| GRD-UI-02 source-scan spec structure specified | §4 |
| GRD-UI-03 bundle-scan spec structure specified | §5 |
| GRD-UI-04 meta-control fixture structure specified | §6 |
| GRD-UI-05 redacted reporter interface specified | §7 |
| `npm run guards` script added to spec | §8 |
| No implementation code in design | All sections use shape/contract notation only |

---

## 14. Open Questions

| ID | Description | Blocking? |
|---|---|---|
| OQ-1 | Path conflict: GRD-UI-01 body says `web/tests/guards/forbidlist.ts`; handoff task says `web/src/guards/forbidlist.ts`. This design uses the requirement-authoritative path. REQ-ANALYST must reconcile. | Yes — implementor cannot proceed until resolved |
| OQ-2 | `status-read-outside-classifier` appears in the handoff task description but not in GRD-UI-01's ten-seed list. Is it a new pattern to add to GRD-UI-01, or a ORCH drafting error? | No — the ten seeds are sufficient to implement; this can be added via a follow-up requirement |
| OQ-3 | Node.js version in CI: if < 18.17, `readdirSync` lacks `recursive` option and `fast-glob` is required. Implementor must confirm. | No — `fast-glob` fallback specified |
