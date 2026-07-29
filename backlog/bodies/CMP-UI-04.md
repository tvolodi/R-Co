> **Extends:** ONB-UI-01, giving a provisioned tenant a visual identity in the SPA.

> The SPA bootstrap SHALL call `GET /api/v1/tenants/{slug}/branding` before the first React render with a budget of 400 ms, and SHALL write the returned values onto `document.documentElement.style` as `--color-brand-400`, `--color-brand-500`, `--color-brand-600` and `--color-brand-700`. Those four are the complete set of tenant-writable tokens; a response key outside the set SHALL be dropped and counted in `brandOverride.rejected`. Semantic tokens `--color-success`, `--color-warning`, `--color-error` and `--color-info`, every neutral, every type token and every spacing token SHALL be identical across all tenants so status colour carries the same meaning everywhere. A timeout SHALL leave the default brand palette and SHALL NOT delay the first render past the budget.

**Acceptance Criteria:**
- GIVEN a Playwright E2E signs in to SwiftRoute against the real backend where a branding row is seeded, WHEN the first contentful paint is captured, THEN the computed background of a `Button variant="primary"` already equals the tenant `brand600` value and no later repaint changes it.
- GIVEN the same E2E switches to Vortex whose branding row differs, WHEN the primary button background is read again, THEN it equals the Vortex `brand600` value while the computed value of `--color-error` is unchanged between the two tenants.
- GIVEN the real branding endpoint returns a payload carrying `neutral900` alongside the four brand keys, WHEN the bootstrap applies it, THEN `--color-neutral-900` is unchanged, `brandOverride.rejected` equals 1, and the rejected key is recorded in the platform audit log rather than in a user-facing toast.
- GIVEN the branding endpoint returns a non-hex string for `brand500`, WHEN the bootstrap applies the response, THEN `--color-brand-500` keeps its default value, the other three overrides are applied, and `brandOverride.rejected` equals 1.
- GIVEN the branding request exceeds 400 ms against the real backend, WHEN the render proceeds, THEN the default brand palette is in effect and the app renders without waiting further.
- GIVEN a tenant brand value that fails a 4.5:1 contrast ratio against `--surface-card`, WHEN it is submitted, THEN it is rejected at bootstrap and the GRD-UI-06 `color-contrast` rule reports no `serious` violation on the resulting page.

**See:** CMP-UI-01, ONB-UI-01, ADM-UI-01, GRD-UI-06, IDN-05
