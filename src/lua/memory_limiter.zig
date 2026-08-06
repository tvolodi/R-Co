//! Memory allocation limits for Lua (LUA-09).
//!
//! A bounded `lua_Alloc` that tracks total memory usage against a
//! per-execution ceiling.
//!
//! ## ISS-0169 tranche 1 makes this file COMPILE and nothing more
//!
//! Diagnosis E4: `mutex: std.Thread.Mutex` did not compile — that namespace
//! does not exist in Zig 0.16 ("root source file struct 'Thread' has no member
//! named 'Mutex'"). The whole file had therefore never been analysed under
//! Zig 0.16, and no gate reported it because `src/lua_test_root.zig` pins it
//! with a bare TYPE reference and Zig resolves struct field types lazily
//! (ISS-0172 / GH #500).
//!
//! **This limiter is installed by no code path.** `executor.executeScript`
//! creates its state with `defaultAlloc`, a plain malloc/realloc/free wrapper
//! with no ceiling. LUA-09 has no enforcement. Tranche 2 owns installing it.

const std = @import("std");

pub const MemoryLimiter = struct {
    max_memory_bytes: u64,
    /// Atomic: `alloc` below is a `callconv(.c)` `lua_Alloc` reached from
    /// LuaJIT, so it cannot take a lock that needs a parameter (see the note
    /// on the removed mutex field).
    current_memory_bytes: std.atomic.Value(u64),
    peak_memory_bytes: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    /// ISS-0169: the struct previously carried `mutex: std.Thread.Mutex`, which
    /// does not exist in Zig 0.16 and is why this file did not compile
    /// (diagnosis E4).
    ///
    /// The 0.16 replacement, `std.Io.Mutex`, is NOT a drop-in here: its
    /// `lock`/`unlock` both require an `Io` instance
    /// (`pub fn lock(m: *Mutex, io: Io)`), and `alloc` below is a
    /// `callconv(.c)` function invoked by LuaJIT through a C function pointer
    /// with `ud` as its only carrier — there is nowhere to thread an `Io`
    /// through, and inventing one inside a C callback would be worse than the
    /// bug. Atomic counters give the same guarantee this code actually needs
    /// (a consistent running total under concurrent LuaJIT allocation) with no
    /// blocking primitive at all.
    ///
    /// A single `lua_State` is per-invocation (LUA-02) and is not shared across
    /// threads, so the contended case does not currently arise; the atomics
    /// keep the counters correct if that ever changes.
    pub fn init(allocator: std.mem.Allocator, max_memory_bytes: u64) MemoryLimiter {
        return MemoryLimiter{
            .max_memory_bytes = max_memory_bytes,
            .current_memory_bytes = std.atomic.Value(u64).init(0),
            .peak_memory_bytes = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    /// Lua allocator function (callconv(.c) required for C interop).
    /// ud: user data (limiter pointer)
    /// ptr: pointer to old block (null for new allocation)
    /// osize: size of old block
    /// nsize: size of new block (0 = free)
    pub fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
        if (ud == null) return null;

        // ISS-0153: Zig 0.11 made @ptrCast single-argument (destination type
        // comes from the result location); the two-arg form here was written
        // for Zig 0.10 and never compiled since.
        const limiter: *MemoryLimiter = @ptrCast(@alignCast(ud));

        if (nsize == 0) {
            // Deallocation request
            if (ptr != null and osize > 0) {
                const current = limiter.current_memory_bytes.load(.monotonic);
                if (current >= osize) {
                    _ = limiter.current_memory_bytes.fetchSub(osize, .monotonic);
                }
                const old_base: [*]align(1) u8 = @ptrCast(ptr);
                const old_slice = old_base[0..osize];
                limiter.allocator.free(old_slice);
            }
            return null;
        }

        // Allocation or reallocation request
        const size_delta = if (nsize > osize) nsize - osize else 0;

        if (limiter.current_memory_bytes.load(.monotonic) + size_delta > limiter.max_memory_bytes) {
            // Allocation would exceed limit
            return null;
        }

        var result: ?*anyopaque = null;

        if (ptr != null) {
            // Reallocation
            const old_base: [*]align(1) u8 = @ptrCast(ptr);
            const old_slice = old_base[0..osize];
            if (limiter.allocator.resize(old_slice, nsize)) {
                result = ptr;
            } else {
                // Could not resize in-place; allocate new and copy
                const new_ptr = limiter.allocator.alloc(u8, nsize) catch return null;
                const copy_len = if (osize < nsize) osize else nsize;
                @memcpy(new_ptr[0..copy_len], old_slice[0..copy_len]);
                limiter.allocator.free(old_slice);
                result = new_ptr.ptr;
            }
        } else {
            // New allocation
            const new_ptr = limiter.allocator.alloc(u8, nsize) catch return null;
            result = new_ptr.ptr;
        }

        if (result != null) {
            const updated = limiter.current_memory_bytes.fetchAdd(size_delta, .monotonic) + size_delta;
            // Raise the high-water mark, retrying if another allocation moved
            // it in between.
            var peak = limiter.peak_memory_bytes.load(.monotonic);
            while (updated > peak) {
                peak = limiter.peak_memory_bytes.cmpxchgWeak(
                    peak,
                    updated,
                    .monotonic,
                    .monotonic,
                ) orelse break;
            }
        }

        return result;
    }

    pub fn getCurrentMemory(self: *const MemoryLimiter) u64 {
        return self.current_memory_bytes.load(.monotonic);
    }

    pub fn getPeakMemory(self: *const MemoryLimiter) u64 {
        return self.peak_memory_bytes.load(.monotonic);
    }

    pub fn wasLimitExceeded(self: *const MemoryLimiter) bool {
        return self.getCurrentMemory() > self.max_memory_bytes;
    }
};
