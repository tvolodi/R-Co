# fn:run-nfr-benchmarks

**Category:** TEST  
**Used by:** `RELEASE-VALIDATOR`  
**Calls:** —

```
1. Run: zig build bench
2. For each NFR with a measurable target (NFR-01, NFR-02, NFR-04):
   - Compare actual result against target threshold
   - Record: {nfr_id, target, actual, passed: bool}
3. Return report; any failed NFR is a BLOCKER for release
```

## Benchmark Output Contract

`zig build bench` emits one machine-readable line per metric:

```
NFR_RESULT|<NFR-ID>|<metric>|target=<expr>|actual=<number>|unit=<unit>|passed=<true|false>
```

Expected metrics:

- `NFR_RESULT|NFR-01|p99_read_ms|target=<=200|...`
- `NFR_RESULT|NFR-01|p99_write_ms|target=<=500|...`
- `NFR_RESULT|NFR-02|append_throughput_eps|target=>=1000|...`
- `NFR_RESULT|NFR-04|replay_10000_ms|target=<=5000|...`

Final summary line:

```
NFR_BENCH_SUMMARY|overall_passed=<true|false>|run_id=<id>
```

Release-validator interpretation:

1. Parse all `NFR_RESULT` lines.
2. Verify each expected metric exists.
3. Any `passed=false` is a release BLOCKER.
4. `zig build bench` exiting non-zero also indicates a BLOCKER.
