# Process: Shared UI Component Layer and Field Registry

| Field | Value |
|-------|-------|
| Process ID | `sys-shared-ui-component-layer` |
| Platform Workflow | PW-14 |
| Owner | Frontend Platform Team / FRONTEND-DEV |
| Scope | System-wide (`web/src/components/ui/`, `web/src/styles/`, `design-tokens/`) |
| Requirements | CMP-UI-01, CMP-UI-02, CMP-UI-03, CMP-UI-04, CMP-UI-05, CMP-UI-06 |
| Source | `docs/workflows.yaml` (PW-14) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §3.2, §3.3 |

## Summary

Turns `docs/guides/frontend_design_system.md` from a written specification into
running code. The token tables of §2, §3 and §4 become CSS custom properties in
`web/src/styles/tokens.css`, generated from `design-tokens/r-co.tokens.json`.
The component APIs of §5, §6 and §7 become files in `web/src/components/ui/`.
A tenant brand override is applied once at bootstrap and touches only the four
brand tokens. `FieldRegistry.registerField()` becomes the documented extension
surface so a new field type is an additive change that edits no screen.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Tenant Admin | Human | Supplies the tenant brand palette; sees it applied at first paint |
| Business User | SwiftRoute dispatcher, ops manager | Consumes the components; reads status through `StatusBadge` colour and dot |
| SPA Bootstrap | System (`web/src/main.tsx`, `auth/tenantConfig`) | Fetches branding and writes the brand token overrides onto the document root |
| FRONTEND-DEV | Agent | Implements the components, registers field types, records the architecture rule |
| Platform API | System | Serves `GET /api/v1/tenants/{slug}/branding` and the task `form_schema` payloads |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `design-tokens/r-co.tokens.json` | JSON | Single source for every colour, type, space and radius value in design system §2-§4 |
| Tenant branding response | JSON | Keys limited to `brand400`, `brand500`, `brand600`, `brand700`; each a 6-digit hex string |
| `form_schema` | JSON Schema | Delivered per task node; parsed by `utils/formSchemaParser.ts` |
| Field type key | string | The `type` / `format` pair a registry entry claims, e.g. `string:iban` |
| `StatusBadge` domain | enum | `definition` \| `instance` \| `task` \| `timer` \| `dlq` per design system §5.4 |
| Canvas node type | enum | `START`, `END`, `HUMAN_TASK`, `EXCLUSIVE_GATEWAY`, `PARALLEL_GATEWAY`, `SERVICE_TASK`, `TIMER`, `SUB_PROCESS` per §6.1 |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | FRONTEND-DEV | Expand `design-tokens/r-co.tokens.json` to carry every value in design system §2.1, §2.2, §3 and §4 | Any token in the guide missing from the JSON? | Missing token fails the token-parity check in step 3 | CMP-UI-01 |
| 2 | FRONTEND-DEV | Generate `web/src/styles/tokens.css` from the JSON as `:root` custom properties | Generator output differs from the committed file? | `npm run build` emits a token drift error | CMP-UI-01 |
| 3 | CI gate | Compare the `--color-*`, `--text-*`, `--space-*`, `--radius-*` key sets in `tokens.css` against the guide tables | Sets equal? | Unequal -> BLOCKER routed to FRONTEND-DEV | CMP-UI-01 |
| 4 | FRONTEND-DEV | Replace every literal `#rrggbb`, `rgb(` and `hsl(` in `web/src/` with a `var(--token)` reference | Literal remains outside `tokens.css`? | PW-16 forbidlist pattern `literal-colour` fails the source scan | CMP-UI-02 |
| 5 | FRONTEND-DEV | Implement `Button`, `DataTable`, `ConfirmDialog`, `Toast`, `JsonEditor`, `StatusBadge`, `PageLayout`, `FilterBar`, `PaginationControls` in `web/src/components/ui/` | Props match the §7 signatures verbatim? | A renamed or dropped prop fails the component API review | CMP-UI-03 |
| 6 | FRONTEND-DEV | Bind `StatusBadge` background, text and dot colours to the §5.1-§5.3 tables and node geometry to the §6.1-§6.3 tables | Every enumerated status and node type covered? | Uncovered status renders the `DRAFT` neutral treatment and fails the badge coverage test | CMP-UI-03 |
| 7 | FRONTEND-DEV | Route every destructive action (cancel instance, delete definition, revoke token, discard DLQ item) through `ConfirmDialog` | `window.confirm` present anywhere in `web/src/`? | PW-16 forbidlist pattern `native-confirm` fails the source scan | CMP-UI-03 |
| 8 | SPA Bootstrap | Call `GET /api/v1/tenants/{slug}/branding` before the first React render | Response received inside 400 ms? | Timeout leaves the default brand palette and the app renders on schedule | CMP-UI-04 |
| 9 | SPA Bootstrap | Write `--color-brand-400/500/600/700` onto `document.documentElement.style` | Response carries a key outside the four brand tokens? | Key is dropped and counted in `brandOverride.rejected`; no neutral, semantic, type or space token is writable by a tenant | CMP-UI-04 |
| 10 | Tenant Admin | Load any page after a brand change | Primary buttons and focus rings show the tenant hue? | Screen shows `Button variant="primary"` filled with the tenant brand 600 value; error and success badges keep the platform semantic colours | CMP-UI-04 |
| 11 | FRONTEND-DEV | Add `FieldRegistry` with `registerField(typeKey, component)` and `resolveField(typeKey)` in `web/src/components/forms/FieldRegistry.ts` | `FieldFactory.tsx` resolves through the registry? | `FieldFactory` keeps its switch only as the registry seed for the §7.6 built-in mappings | CMP-UI-05 |
| 12 | FRONTEND-DEV | Register the built-in mappings from design system §7.6 as registry entries at module load | All seven built-in mappings registered? | An unregistered `type`/`format` pair renders `<UnsupportedFieldNotice>` instead of throwing | CMP-UI-05 |
| 13 | FRONTEND-DEV | Add a new field type by calling `registerField` once | Did any file under `web/src/pages/` change? | A changed page file means the extension point was bypassed; the handoff is FAILED | CMP-UI-05 |
| 14 | SPA Renderer | Render a task form through `DynamicFormRenderer` using `resolveField` | Registry entry found for each schema property? | Unknown property renders the notice and the rest of the form stays submittable | CMP-UI-05 |
| 15 | FRONTEND-DEV | Record the generic-interpreter rule in `docs/guides/frontend_design_system.md` §10 | Rule recorded verbatim? | Rule text: "The SPA is a generic interpreter of server-delivered definitions; it contains no hand-coded screen for any tenant entity." | CMP-UI-06 |
| 16 | FRONTEND-DEV | Record the directory contract alongside the rule | - | `components/renderers/` holds rendering logic, `pages/` are thin route shells, `components/canvas/` is definition-authoring only | CMP-UI-06 |
| 17 | CI gate | Assert no file under `web/src/pages/` contains a tenant slug literal or a per-tenant branch | Match found? | PW-16 forbidlist pattern `tenant-slug-in-source` fails the source scan | CMP-UI-06 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| One token source | `design-tokens/r-co.tokens.json` is the only place a colour, type, space or radius value is authored; `tokens.css` is generated from it |
| No literal colour in components | Component code references `var(--color-*)`; the only file holding hex values is `web/src/styles/tokens.css` |
| Tenant override is brand-only | `--color-brand-400`, `--color-brand-500`, `--color-brand-600`, `--color-brand-700` are the complete set of tenant-writable tokens |
| Semantic colours are platform-owned | `--color-success`, `--color-warning`, `--color-error`, `--color-info` and every neutral stay identical across all tenants so status reads the same everywhere |
| Override timing | Brand tokens are written before the first React render; no page repaints from a default palette to a tenant palette |
| Destructive actions | Cancel, delete, discard and revoke use `ConfirmDialog` with `confirmVariant="danger"`; `window.confirm` and `window.alert` are forbidden |
| Component API fidelity | Prop names and enum values match design system §5.4, §7.1-§7.6 character for character |
| Registry is the extension surface | A new field type is added by one `registerField` call; adding one edits no file under `web/src/pages/` |
| Generic interpreter | No screen is hand-coded for a tenant entity; tenant behaviour arrives as a server-delivered schema or definition |
| Test substrate | DIRECTIVE T-2 forbids MSW and HTTP mocking; branding and field-registry behaviour are proven by Playwright E2E against the real branding endpoint and real task payloads |

---

## Outputs

| Output | Description |
|--------|-------------|
| `design-tokens/r-co.tokens.json` | Complete token source covering design system §2-§4 |
| `web/src/styles/tokens.css` | Generated `:root` custom properties; the only file with literal colour values |
| `web/src/components/ui/*.tsx` | `Button`, `DataTable`, `ConfirmDialog`, `Toast`, `JsonEditor`, `StatusBadge`, `PageLayout`, `FilterBar`, `PaginationControls` |
| `web/src/components/forms/FieldRegistry.ts` | `registerField` / `resolveField` and the built-in seed registrations |
| `web/src/auth/tenantConfig.ts` | Brand override fetch, allowlist filter, `brandOverride.rejected` counter |
| `docs/guides/frontend_design_system.md` §10 | Generic-interpreter rule and directory contract |
| `web/tests/e2e/pipelines/tenant-branding.pipeline.e2e.spec.ts` | Chained Playwright test for the `platform-tenant-branding-applied` scenario |
| `tests/specs/PIPELINE-tenant-branding.md` | Step table mapping each `pl.step()` to CMP-UI-01..06 |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Branding fetch budget | 400 ms; on timeout the default brand palette is used and the app renders without waiting further |
| Token drift | A `tokens.css` that differs from the generator output blocks `npm run build` |
| Rejected override key | Counted in `brandOverride.rejected` and reported through the platform audit log, not through a user-facing toast |
| Unsupported field type | `<UnsupportedFieldNotice>` renders inline; the surrounding form stays submittable for the remaining fields |
| Escalation | A literal colour, a `window.confirm`, or a tenant slug in `web/src/` is a PW-16 BLOCKER routed to FRONTEND-DEV through WF-03 |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| Branding endpoint 404 | Tenant has no branding row | Default brand palette applies; the page renders with platform blue |
| Branding endpoint 403 | Session token lacks the tenant claim | Default palette applies; `QueryStateBoundary` handles the page's own queries per PW-13 |
| Malformed hex value | Branding response carries a non-hex string | Value is dropped, counted in `brandOverride.rejected`, and that single token keeps its default |
| Token drift | `r-co.tokens.json` edited without regenerating `tokens.css` | Build fails; regenerate and commit both files together |
| Duplicate registration | `registerField` called twice for the same type key | Second call throws `DuplicateFieldTypeError` at module load, before the first render |
| Unknown field type | `form_schema` property has a `type`/`format` pair with no registry entry | `<UnsupportedFieldNotice>` renders naming the type key; the form still submits the remaining fields |
| Missing status mapping | `StatusBadge` receives a status outside the §5.1-§5.3 tables | Renders the neutral `DRAFT` treatment and fails the badge coverage test in CI |
