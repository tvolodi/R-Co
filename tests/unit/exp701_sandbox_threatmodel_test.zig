const std = @import("std");
const testing = std.testing;
const doc_embed = @import("exp701_doc_embed");

const threat_model_doc = doc_embed.threat_model_doc;
const backend_arch_doc = doc_embed.backend_arch_doc;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |idx| {
        count += 1;
        start = idx + needle.len;
    }
    return count;
}

fn expectSectionWithKeywords(doc: []const u8, section_header: []const u8, keywords: []const []const u8) !void {
    const section_start = std.mem.indexOf(u8, doc, section_header) orelse return error.SectionMissing;
    const after = doc[section_start + section_header.len ..];
    const next_header_rel = std.mem.indexOf(u8, after, "\n## ") orelse after.len;
    const section_body = after[0..next_header_rel];

    for (keywords) |keyword| {
        try testing.expect(std.mem.indexOf(u8, section_body, keyword) != null);
    }
}

test "TC-EXP-701-01: threat model contains all 7 required sections" {
    try testing.expect(contains(threat_model_doc, "## 1. Lua Host-API Surface"));
    try testing.expect(contains(threat_model_doc, "## 2. Wasm Host-API Surface"));
    try testing.expect(contains(threat_model_doc, "## 3. Agent Pipeline Auth and Session Binding"));
    try testing.expect(contains(threat_model_doc, "## 4. Threat Enumeration"));
    try testing.expect(contains(threat_model_doc, "## 5. Error Cases"));
    try testing.expect(contains(threat_model_doc, "## 6. Mitigations Per Threat"));
    try testing.expect(contains(threat_model_doc, "## 7. Go-Live Gate Checklist"));
}

test "TC-EXP-701-02: go-live checklist contains at least 20 items" {
    // Checklist rows are encoded as stable IDs in table cells.
    const l_items = countOccurrences(threat_model_doc, "| L-");
    const w_items = countOccurrences(threat_model_doc, "| W-");
    const a_items = countOccurrences(threat_model_doc, "| A-");
    const x_items = countOccurrences(threat_model_doc, "| X-");
    const total_items = l_items + w_items + a_items + x_items;

    try testing.expect(total_items >= 20);
}

test "TC-EXP-701-03: architecture document references sandbox threat model" {
    try testing.expect(contains(backend_arch_doc, "docs/sandbox_threat_model.md"));
}

test "TC-EXP-701-04: all five technical acceptance criteria have dedicated section coverage" {
    try expectSectionWithKeywords(threat_model_doc, "## 1. Lua Host-API Surface", &[_][]const u8{
        "host",
        "API",
        "Lua",
    });
    try expectSectionWithKeywords(threat_model_doc, "## 2. Wasm Host-API Surface", &[_][]const u8{
        "host",
        "API",
        "Wasm",
    });
    try expectSectionWithKeywords(threat_model_doc, "### 1.7 Capability Gating", &[_][]const u8{
        "capability",
        "CapabilitySet",
    });
    try expectSectionWithKeywords(threat_model_doc, "### 1.5 Execution Fuel / Instruction Limit", &[_][]const u8{
        "instruction",
        "LUA_MASKCOUNT",
    });
    try expectSectionWithKeywords(threat_model_doc, "### 1.4 Allocator Policy", &[_][]const u8{
        "memory",
        "limit",
    });
    try expectSectionWithKeywords(threat_model_doc, "### 1.6 Wall-Clock Timeout", &[_][]const u8{
        "timeout",
    });
    try expectSectionWithKeywords(threat_model_doc, "### 3.3 Sandbox-Control Auth", &[_][]const u8{
        "sandbox",
        "auth",
    });
}

test "TC-EXP-701-05: release go-live status file exists or test is skipped pre-release" {
    const allocator = std.testing.allocator;
    const release_path = "docs/status/release-exp701-20260614.yaml";

    const release_status = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        release_path,
        allocator,
        std.Io.Limit.limited(128 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(release_status);
}
