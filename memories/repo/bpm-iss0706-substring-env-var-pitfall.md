# Regression-test pitfall: substring matching of env var names

## Symptom
A static-assertion regression test "verifies env-var ordering" passes only the first
time, then fails when extra `environ_map.get("BPM_X")` calls appear elsewhere in the
file (e.g. in main() or a fallback helper). Or it fails because the search substring
matches a *longer* env var name.

## Concrete failure (ISS-0706 / step-03 regression test)
`std.mem.indexOf(u8, haystack, "\"BPM_DB_URL\"")` matched inside `BPM_BENCH_DB_URL` and
`BPM_TEST_DB_URL`, producing a position BEFORE the actual `BPM_DB_URL` line in bench.zig.

The test was trying to verify that `bench.zig::resolveDbUrl` orders its three
`environ_map.get(...)` calls as `BPM_BENCH_DB_URL` < `BPM_DB_URL` < `BPM_TEST_DB_URL`.
But `std.mem.indexOf` returns the **first** occurrence of the substring anywhere in the
file — and `BPM_BENCH_DB_URL` contains `BPM_DB_URL` as a substring.

## Fix patterns

1. **Anchor with a function start**: `std.mem.indexOfPos(u8, haystack, fn_start_pos, needle)`
   — scope the search to after `fn resolveDbUrl` so the earlier `BPM_TEST_DB_URL` call
   in `main()` (line ~50) doesn't skew the result.

2. **Use exact qualified strings**: search for
   `"environ_map.get(\"BPM_DB_URL\")"` (with the surrounding `(` and `)` and quote) — but
   only if the file consistently uses the same call shape around the env var.

3. **Avoid bare env var names as anchors**: never use `BPM_DB_URL` alone as a search
   needle if `BPM_BENCH_DB_URL` or `BPM_TEST_DB_URL` also exist in the file.

## Verified lesson
- `BPM_DB_URL` substring of `BPM_BENCH_DB_URL` ✓
- `BPM_DB_URL` substring of `BPM_TEST_DB_URL` ✓
- `BPM_BENCH_DB_URL` substring of `BPM_TEST_DB_URL` ✗ (no)
- `BPM_TEST_DB_URL` substring of `BPM_BENCH_DB_URL` ✗ (no)

Always pair the regex/indexOf search with a check that the surrounding
quote/parenthesis context matches the expected call shape. Or better: check
the position of the *full call expression* (`environ_map.get("BPM_DB_URL")`) which
cannot nest-match across different env var names.

## Also: `readFileAlloc` is on `Dir`, not `File`
Zig 0.16 API: `std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(N))`.
`file.readFileAlloc` does NOT exist on `Io.File` — use `Dir.readFileAlloc` directly without
opening a File first.
