> The `loading` state SHALL render `web/src/components/ui/SkeletonLayout.tsx` with `aria-busy="true"` on the content region and five skeleton rows whose column widths match the column widths the resolved `DataTable` will use. On resolution to `success`, `aria-busy` SHALL be removed and `DataTable` SHALL receive `isLoading={false}`. No frame between navigation and resolution SHALL render an empty content region.

**Acceptance Criteria:**
- GIVEN a Playwright E2E navigates to the Instance List against the real backend, WHEN the first frame after navigation is captured, THEN `SkeletonLayout` is already mounted and the content region carries `aria-busy="true"`.
- GIVEN the same E2E waits for the query to resolve, WHEN the resolved frame is captured, THEN `aria-busy` is absent from the content region and the skeleton rows are unmounted.
- GIVEN the skeleton frame and the resolved frame are both captured in that E2E, WHEN the bounding box of each table column is compared between the two frames, THEN each column width is identical and no horizontal shift occurs.
- GIVEN a page renders `DataTable` with `isLoading={true}` outside a `QueryStateBoundary`, WHEN the GRD-UI-02 source scan runs, THEN the scan fails with pattern name `missing-query-state-boundary`; this is a pure static scan with no HTTP.
- The skeleton rows draw from `--color-neutral-200` and `--color-neutral-100` and hold no literal colour value, which the GRD-UI-02 scan asserts under pattern name `literal-colour`.

**See:** RND-UI-01, CMP-UI-01, CMP-UI-03, GRD-UI-02, IN-UI-05
