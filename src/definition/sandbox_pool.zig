//! PRM-06 / PRM-07: ephemeral sandbox pool (on-demand variant).
//!
//! Provides a minimal claim/release interface for the assertion re-run
//! pipeline. Sandboxes are PostgreSQL schemas: `claim` provisions a fresh
//! schema (CREATE SCHEMA), and `release` drops it (DROP SCHEMA CASCADE).
//! The pool records every active claim in a process-local table and enforces
//! the configurable `max_concurrent_sandboxes` quota.
//!
//! This is intentionally minimal (Open question OQ-3 in the design): warm
//! pool mechanics described in EXP-702 are a separate future concern; the
//! `claim`/`release` interface is stable regardless of the provisioning
//! strategy that backs it.
//!
//! Design artefact: src/design/prm-batch1-promotion-assertion-rerun.md

const std = @import("std");
const pool_mod = @import("pool");
const tenant_context_mod = @import("tenant_context");
const audit_mod = @import("../obs/audit.zig");

pub const SandboxPoolError = error{
    PoolExhausted,
    QuotaExceeded,
    ProvisionFailed,
    OutOfMemory,
};

pub const SandboxClaim = struct {
    sandbox_id: []const u8, // 36-char UUID; owned by claim, freed by release caller
    schema_name: []const u8, // bare schema name; same ownership rule

    pub fn deinit(self: SandboxClaim, allocator: std.mem.Allocator) void {
        allocator.free(self.sandbox_id);
        allocator.free(self.schema_name);
    }
};

const ActiveClaim = struct {
    sandbox_id: []const u8,
    schema_name: []const u8,
};

pub const SandboxPool = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io, // null when max_concurrent == 0 (placeholder pool)
    pool: *pool_mod.Pool,
    max_concurrent: u32,
    active: std.ArrayList(ActiveClaim),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(io: ?std.Io, allocator: std.mem.Allocator, pool: *pool_mod.Pool, max_concurrent: u32) SandboxPool {
        return .{
            .io = io,
            .allocator = allocator,
            .pool = pool,
            .max_concurrent = max_concurrent,
            .active = std.ArrayList(ActiveClaim).empty,
        };
    }

    pub fn deinit(self: *SandboxPool) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        for (self.active.items) |c| {
            self.allocator.free(c.sandbox_id);
            self.allocator.free(c.schema_name);
        }
        self.active.deinit(self.allocator);
    }

    /// Claim a fresh sandbox. Returns a SandboxClaim whose strings are owned
    /// by the caller; the caller must pass them back to `release()` so the
    /// strings can be freed atomically with the schema drop. Blocks for up
    /// to `timeout_ms` milliseconds waiting for a quota slot.
    pub fn claim(
        self: *SandboxPool,
        allocator: std.mem.Allocator,
        timeout_ms: u32,
    ) SandboxPoolError!SandboxClaim {
        // Fast-path: quota 0 means sandbox orchestration is not yet wired in
        // (placeholder route handler uses max_concurrent=0). Return immediately
        // instead of spinning for timeout_ms milliseconds.
        if (self.max_concurrent == 0) return SandboxPoolError.PoolExhausted;

        const io = self.io orelse return SandboxPoolError.PoolExhausted;
        const started: i64 = std.Io.Clock.real.now(io).toMilliseconds();
        while (true) {
            {
                while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                defer self.mutex.unlock();
                if (self.active.items.len < self.max_concurrent) break;
            }
            const elapsed: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds() - started);
            if (elapsed >= timeout_ms) return SandboxPoolError.PoolExhausted;
            std.Thread.yield() catch {};
        }

        // Provision: generate UUID, derive a schema name, CREATE SCHEMA.
        const sandbox_id = generateUuidString(io, allocator) catch return SandboxPoolError.OutOfMemory;
        errdefer allocator.free(sandbox_id);
        const schema_name = std.fmt.allocPrint(allocator, "sandbox_{s}", .{sandbox_id}) catch
            return SandboxPoolError.OutOfMemory;
        errdefer allocator.free(schema_name);

        const conn = self.pool.acquire() catch |err| {
            return switch (err) {
                pool_mod.PoolError.ExhaustedPool => SandboxPoolError.PoolExhausted,
                else => SandboxPoolError.ProvisionFailed,
            };
        };
        defer self.pool.release(conn);

        // Schema name quoted to handle UUID hyphens in the identifier.
        const ddl = std.fmt.allocPrint(allocator, "CREATE SCHEMA \"{s}\"", .{schema_name}) catch
            return SandboxPoolError.OutOfMemory;
        defer allocator.free(ddl);

        conn.simpleQuery(ddl) catch return SandboxPoolError.ProvisionFailed;

        // Create empty copies of the fixture-target tables so tests can
        // INSERT fixture rows into the sandbox without touching organic data.
        const setup_sql = std.fmt.allocPrint(allocator,
            \\DO $body$
            \\BEGIN
            \\  EXECUTE 'CREATE TABLE "{s}".process_definitions (LIKE tenant_default.process_definitions INCLUDING DEFAULTS)';
            \\  EXECUTE 'CREATE TABLE "{s}".variable_schemas (LIKE tenant_default.variable_schemas INCLUDING DEFAULTS)';
            \\  BEGIN
            \\    EXECUTE 'CREATE TABLE "{s}".instances (LIKE tenant_default.instances INCLUDING DEFAULTS)';
            \\  EXCEPTION WHEN undefined_table THEN NULL;
            \\  END;
            \\END $body$;
        , .{ schema_name, schema_name, schema_name }) catch return SandboxPoolError.OutOfMemory;
        defer allocator.free(setup_sql);
        conn.simpleQuery(setup_sql) catch return SandboxPoolError.ProvisionFailed;

        // Record in active list — make owned copies.
        const id_copy = allocator.dupe(u8, sandbox_id) catch return SandboxPoolError.OutOfMemory;
        errdefer allocator.free(id_copy);
        const schema_copy = allocator.dupe(u8, schema_name) catch return SandboxPoolError.OutOfMemory;
        errdefer allocator.free(schema_copy);

        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.active.append(self.allocator, .{ .sandbox_id = id_copy, .schema_name = schema_copy }) catch
            return SandboxPoolError.OutOfMemory;

        return SandboxClaim{
            .sandbox_id = sandbox_id,
            .schema_name = schema_name,
        };
    }

    /// Drop the sandbox schema and remove the claim from the active list.
    /// Returns a PoolExhausted / ProvisionFailed error if the DROP fails;
    /// the caller surfaces the failure (PRM-07 AC2).
    pub fn release(
        self: *SandboxPool,
        sandbox_id: []const u8,
        schema_name: []const u8,
    ) SandboxPoolError!void {
        const conn = self.pool.acquire() catch |err| {
            return switch (err) {
                pool_mod.PoolError.ExhaustedPool => SandboxPoolError.PoolExhausted,
                else => SandboxPoolError.ProvisionFailed,
            };
        };
        defer self.pool.release(conn);

        const ddl = std.fmt.allocPrint(self.allocator, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE", .{schema_name}) catch
            return SandboxPoolError.OutOfMemory;
        defer self.allocator.free(ddl);

        conn.simpleQuery(ddl) catch return SandboxPoolError.ProvisionFailed;

        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.active.items.len) {
            if (std.mem.eql(u8, self.active.items[i].sandbox_id, sandbox_id)) {
                self.allocator.free(self.active.items[i].sandbox_id);
                self.allocator.free(self.active.items[i].schema_name);
                _ = self.active.orderedRemove(i);
                break;
            }
            i += 1;
        }

        // Free the caller-owned strings (these are the same slices we
        // returned from claim()).
        self.allocator.free(sandbox_id);
        self.allocator.free(schema_name);
    }

    /// PRM-07 AC5: reclaim leaked sandboxes whose teardown previously failed.
    ///
    /// Queries `promotion_assertion_runs` for rows with `status = 'teardown_failed'`
    /// and `reaper_claimed_at IS NULL`, drops their schemas, and marks the rows
    /// reaped. Errors for individual rows are silently skipped; the scheduler
    /// retries on the next interval. The `tenant_id` parameter sets the
    /// search_path context for the per-tenant table.
    pub fn reclaimLeakedSandboxes(
        self: *SandboxPool,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
    ) void {
        _ = tenant_id; // platform-wide table; not used to switch search_path

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Phase 1: collect up to 20 leaked run ids and sandbox ids.
        // promotion_assertion_runs is a platform-wide table — always qualify
        // with `public.` so the query resolves regardless of the calling
        // connection's search_path (SCHEMA mode would otherwise route to
        // tenant_default.promotion_assertion_runs, missing rows written by
        // LEGACY_RLS callers and vice versa).
        const conn1 = self.pool.acquire() catch return;
        var query_result = conn1.query(
            aa,
            \\SELECT id::text, sandbox_id::text
            \\  FROM public.promotion_assertion_runs
            \\ WHERE status = 'teardown_failed'
            \\   AND reaper_claimed_at IS NULL
            \\   AND sandbox_id IS NOT NULL
            \\ LIMIT 20
        ,
            &[_][]const u8{},
        ) catch {
            self.pool.release(conn1);
            return;
        };
        self.pool.release(conn1);
        defer query_result.deinit();

        // Phase 2: for each leaked sandbox, drop its schema and mark it reaped.
        for (query_result.rows) |row| {
            const run_id = row[0] orelse continue;
            const sandbox_id = row[1] orelse continue;

            // schema_name is always derivable from sandbox_id (see claim()).
            const schema_name = std.fmt.allocPrint(aa, "sandbox_{s}", .{sandbox_id}) catch continue;
            const drop_ddl = std.fmt.allocPrint(aa, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE", .{schema_name}) catch continue;

            // Use a labeled block so break exits cleanly and defer fires.
            blk: {
                const conn2 = self.pool.acquire() catch break :blk;
                defer self.pool.release(conn2);

                conn2.simpleQuery(drop_ddl) catch break :blk;

                const update_row = conn2.queryRow(
                    aa,
                    \\UPDATE public.promotion_assertion_runs
                    \\   SET reaper_claimed_at = NOW()
                    \\ WHERE id = $1::uuid
                    \\RETURNING id::text
                ,
                    &[_][]const u8{run_id},
                ) catch null;
                if (update_row) |r| {
                    for (r) |col| if (col) |v| aa.free(v);
                    aa.free(r);
                }
            }
        }
    }

    /// SBX-06: Reclaim sandboxes idle for more than 60 minutes.
    ///
    /// Runs inside a single transaction per swept sandbox: SELECT...FOR UPDATE SKIP LOCKED,
    /// UPDATE to released, writeAuditInTx (sandbox.reclaimed). Returns the count of
    /// sandboxes reclaimed in this sweep. Errors for individual rows are silently skipped.
    pub fn reclaimIdleSandboxes(
        self: *SandboxPool,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) pool_mod.PoolError!u32 {
        _ = io;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            pool_mod.PoolError.ExhaustedPool => return pool_mod.PoolError.ExhaustedPool,
            else => return pool_mod.PoolError.QueryFailed,
        };
        defer self.pool.release(conn);

        // Collect idle claimed sandboxes (non-locking read).
        var idle_rows = conn.query(
            aa,
            \\SELECT sandbox_id::text, owner_principal, task_spec_id::text
            \\FROM agent_sandboxes
            \\WHERE status = 'claimed'
            \\  AND last_active_at < NOW() - INTERVAL '60 minutes'
            \\LIMIT 50
        ,
            &[_][]const u8{},
        ) catch return pool_mod.PoolError.QueryFailed;
        defer idle_rows.deinit();

        var reclaimed: u32 = 0;
        for (idle_rows.rows) |row| {
            const sandbox_id = row[0] orelse continue;
            const prior_principal = row[1] orelse continue;
            const task_spec_id = row[2];

            const conn2 = self.pool.acquire() catch continue;
            defer self.pool.release(conn2);

            conn2.begin() catch continue;

            // Re-lock the row with FOR UPDATE SKIP LOCKED to prevent double-reclaim.
            const lock_row = conn2.queryRow(
                aa,
                \\SELECT sandbox_id::text
                \\FROM agent_sandboxes
                \\WHERE sandbox_id = $1::uuid
                \\  AND status = 'claimed'
                \\  AND last_active_at < NOW() - INTERVAL '60 minutes'
                \\FOR UPDATE SKIP LOCKED
            ,
                &[_][]const u8{sandbox_id},
            ) catch {
                conn2.rollback() catch {};
                continue;
            };
            if (lock_row == null) {
                conn2.rollback() catch {};
                continue;
            }
            if (lock_row) |r| {
                for (r) |col| if (col) |c| aa.free(c);
                aa.free(r);
            }

            conn2.exec(
                \\UPDATE agent_sandboxes
                \\SET status = 'released',
                \\    owner_principal = NULL,
                \\    task_spec_id = NULL,
                \\    claimed_at = NULL,
                \\    last_active_at = NULL,
                \\    updated_at = NOW()
                \\WHERE sandbox_id = $1::uuid
            ,
                &[_][]const u8{sandbox_id},
            ) catch {
                conn2.rollback() catch {};
                continue;
            };

            const ts_id_str: []const u8 = task_spec_id orelse "";
            const after = std.fmt.allocPrint(
                aa,
                "{{\"prior_principal\":\"{s}\",\"sandbox_id\":\"{s}\",\"task_spec_id\":\"{s}\"}}",
                .{ prior_principal, sandbox_id, ts_id_str },
            ) catch null;
            if (after) |a| {
                const audit_id = audit_mod.writeAuditInTx(
                    aa, conn2, "", prior_principal,
                    "sandbox.reclaimed", "agent_sandbox", sandbox_id,
                    null, a, null, null,
                ) catch null;
                if (audit_id) |id| aa.free(id);
            }

            conn2.commit() catch {
                conn2.rollback() catch {};
                continue;
            };
            reclaimed += 1;
        }

        return reclaimed;
    }
};

// ── Internal helpers ─────────────────────────────────────────────────────────

fn generateUuidString(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.Io.random(io, &bytes);
    // Set RFC 4122 v4 bits.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex_buf = try allocator.alloc(u8, 36);
    const hex_chars = "0123456789abcdef";
    var idx: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            hex_buf[idx] = '-';
            idx += 1;
        }
        hex_buf[idx] = hex_chars[(b >> 4) & 0x0f];
        hex_buf[idx + 1] = hex_chars[b & 0x0f];
        idx += 2;
    }
    return hex_buf;
}

// `tenant_context_mod` is imported above so the assertion rerun module's
// per-tenant search_path can be re-applied to the sandbox connection. The
// pool layer relies on the caller to call `tenant_context_mod.set` before
// claiming — the sandbox schemas are tenant-scoped.
comptime {
    _ = tenant_context_mod;
}
