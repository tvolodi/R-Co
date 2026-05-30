pub const packages = struct {
    pub const @"vendor/cel" = struct {
        pub const build_root = "C:\\Users\\tvolo\\dev\\ai-dala\\My-Fab\\vendor/cel";
        pub const build_zig = @import("vendor/cel");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"vendor/http" = struct {
        pub const build_root = "C:\\Users\\tvolo\\dev\\ai-dala\\My-Fab\\vendor/http";
        pub const build_zig = @import("vendor/http");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"vendor/pg" = struct {
        pub const build_root = "C:\\Users\\tvolo\\dev\\ai-dala\\My-Fab\\vendor/pg";
        pub const build_zig = @import("vendor/pg");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "pg", "vendor/pg" },
    .{ "http", "vendor/http" },
    .{ "cel", "vendor/cel" },
};
