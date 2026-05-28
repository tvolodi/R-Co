const std = @import("std");
const realm_seed = @import("../oidc/realm_seed.zig");

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    const result = realm_seed.validateSeedFile(gpa, "infrastructure/keycloak/realms/bpm-default.json") catch |err| {
        std.debug.print("REALM_SEED_VALIDATION|status=fail|error={s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print(
        "REALM_SEED_VALIDATION|status={s}|valid={s}|importable={s}|deterministic={s}|digest={s}\n",
        .{
            if (result.valid) "ok" else "fail",
            if (result.valid) "true" else "false",
            if (result.importable) "true" else "false",
            if (result.deterministic) "true" else "false",
            result.digest_sha256_hex,
        },
    );

    if (!result.valid or !result.importable or !result.deterministic) {
        return error.ValidationFailed;
    }
}
