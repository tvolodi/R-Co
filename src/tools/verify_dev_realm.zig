const std = @import("std");
const realm_seed = @import("../oidc/realm_seed.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const compose = try std.fs.cwd().readFileAlloc(allocator, "docker-compose.yml", 1024 * 1024);
    defer allocator.free(compose);
    if (std.mem.indexOf(u8, compose, "keycloak") == null) {
        std.debug.print("DEV_REALM_VERIFY|status=fail|reason=keycloak_service_missing\n", .{});
        return error.ComposeMissingKeycloak;
    }

    const seed_result = realm_seed.validateSeedFile(allocator, "infrastructure/keycloak/realms/bpm-default.json") catch |err| {
        std.debug.print("DEV_REALM_VERIFY|status=fail|reason=seed_invalid|error={s}\n", .{@errorName(err)});
        return err;
    };

    const users_ok = std.mem.indexOf(u8, compose, "bpm-default") != null;
    std.debug.print(
        "DEV_REALM_VERIFY|status={s}|seed_valid={s}|seed_importable={s}|compose_mentions_seed={s}\n",
        .{
            if (seed_result.valid and seed_result.importable and users_ok) "ok" else "fail",
            if (seed_result.valid) "true" else "false",
            if (seed_result.importable) "true" else "false",
            if (users_ok) "true" else "false",
        },
    );

    if (!(seed_result.valid and seed_result.importable and users_ok)) return error.VerificationFailed;
}
