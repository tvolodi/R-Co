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
