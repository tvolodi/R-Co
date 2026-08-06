//! Memory allocation limits for Lua (LUA-09).
//!
//! Replaces Lua's default allocator with a bounded allocator that tracks
//! total memory usage and enforces a per-execution ceiling.

const std = @import("std");

pub const MemoryLimiter = struct {
    max_memory_bytes: u64,
    current_memory_bytes: u64,
    peak_memory_bytes: u64,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, max_memory_bytes: u64) MemoryLimiter {
        return MemoryLimiter{
            .max_memory_bytes = max_memory_bytes,
            .current_memory_bytes = 0,
            .peak_memory_bytes = 0,
            .allocator = allocator,
            .mutex = .{},
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

        limiter.mutex.lock();
        defer limiter.mutex.unlock();

        if (nsize == 0) {
            // Deallocation request
            if (ptr != null and osize > 0) {
                if (limiter.current_memory_bytes >= osize) {
                    limiter.current_memory_bytes -= osize;
                }
                const old_base: [*]align(1) u8 = @ptrCast(ptr);
                const old_slice = old_base[0..osize];
                limiter.allocator.free(old_slice);
            }
            return null;
        }

        // Allocation or reallocation request
        const size_delta = if (nsize > osize) nsize - osize else 0;

        if (limiter.current_memory_bytes + size_delta > limiter.max_memory_bytes) {
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
            limiter.current_memory_bytes += size_delta;
            if (limiter.current_memory_bytes > limiter.peak_memory_bytes) {
                limiter.peak_memory_bytes = limiter.current_memory_bytes;
            }
        }

        return result;
    }

    pub fn getCurrentMemory(self: *const MemoryLimiter) u64 {
        return self.current_memory_bytes;
    }

    pub fn getPeakMemory(self: *const MemoryLimiter) u64 {
        return self.peak_memory_bytes;
    }

    pub fn wasLimitExceeded(self: *const MemoryLimiter) bool {
        return self.current_memory_bytes > self.max_memory_bytes;
    }
};
