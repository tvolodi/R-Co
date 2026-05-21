# fn:apply-migrations

**Category:** CODE  
**Used by:** `BACKEND-DEV`  
**Calls:** —

```
1. Ensure BPM_DB_URL environment variable is set
2. Run: zig build migrate
3. Verify exit code == 0
4. Return PASS or FAIL with error detail
Note: Migrations are idempotent; safe to run multiple times
```
