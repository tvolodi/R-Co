const std = @import("std");
const reference = @import("reference.zig");

pub const SecretError = error{
    RedactionViolation,
    InvalidReference,
    OutOfMemory,
};

pub fn redactSecretRefForLog(allocator: std.mem.Allocator, ref_text: []const u8) ![]u8 {
    const parsed = reference.parseSecretRef(ref_text) catch return error.InvalidReference;
    return std.fmt.allocPrint(allocator, "sec://tenant/{s}/{s}/{s}#***", .{ parsed.tenant_id, parsed.namespace, parsed.name });
}

pub fn assertNoSecretMaterialInLogFields(fields_json: []const u8) SecretError!void {
    const lowered = fields_json;
    if (containsInsensitive(lowered, "secret") or containsInsensitive(lowered, "password") or containsInsensitive(lowered, "client_secret") or containsInsensitive(lowered, "token")) {
        return error.RedactionViolation;
    }
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

test "EXP-501 redactSecretRefForLog masks key id" {
    const allocator = std.testing.allocator;
    const out = try redactSecretRefForLog(allocator, "sec://tenant/default/webhook/main#k2");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("sec://tenant/default/webhook/main#***", out);
}
