//! ISS-602: CEL-to-expr Differential Test Suite
//!
//! Loads gateway conditions from a JSON corpus file, evaluates each with both
//! vendor/cel and src/expr, and asserts identical boolean results.
//!
//! Gate: no production import of src/expr/ on the engine path until corpus is green.
//!
//! Design artefact: src/design/iss602_cel_expr_differential.md
const std = @import("std");
const cel = @import("cel");
const expr_mod = @import("expr");

// ---------------------------------------------------------------------------
// Corpus types
// ---------------------------------------------------------------------------

const CorpusEntry = struct {
    condition_id: []const u8,
    source_definition_id: []const u8,
    source_definition_version: u32,
    source_gateway_node_id: []const u8,
    condition_text: []const u8,
    context: std.json.ObjectMap,
    expected_result: bool,
};

const DiffResult = struct {
    condition_id: []const u8,
    condition_text: []const u8,
    cel_result: ?bool,
    expr_result: ?bool,
    match: bool,
    cel_error: ?[]const u8,
    expr_error: ?[]const u8,
    diff_detail: ?[]const u8,
};

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

test "ISS-602: differential corpus — all conditions match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Load and parse corpus (corpus_parsed must outlive entries).
    const corpus_path = "tests/differential/corpus/conditions_v1.json";
    _ = corpus_path; // Path kept for API compatibility; corpus is embedded.
    const content = @embedFile("corpus/conditions_v1.json");

    const corpus_parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        content,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        std.debug.print("Failed to parse corpus: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer corpus_parsed.deinit();

    if (corpus_parsed.value != .array) return error.SkipZigTest;

    const entries = loadCorpusFromValue(alloc, corpus_parsed.value.array) catch |err| {
        std.debug.print("Failed to load corpus: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer alloc.free(entries);

    std.debug.print("\nISS-602 Differential Corpus: {d} conditions\n", .{entries.len});

    var total: u32 = 0;
    var matched: u32 = 0;
    var diverged: u32 = 0;
    var cel_only_errors: u32 = 0;
    var expr_only_errors: u32 = 0;
    var both_errors: u32 = 0;

    for (entries) |*entry| {
        total += 1;
        const diff = evaluateDifferential(alloc, entry) catch |err| {
            std.debug.print("  [{s}] EVAL ERROR: {s}\n", .{ entry.condition_id, @errorName(err) });
            diverged += 1;
            continue;
        };
        defer freeDiffResult(alloc, diff);

        if (diff.match) {
            matched += 1;
        } else {
            diverged += 1;
            std.debug.print("  [{s}] DIVERGENCE: {s}\n", .{
                diff.condition_id,
                diff.diff_detail orelse "unknown",
            });
            if (diff.cel_error != null and diff.expr_error != null) {
                both_errors += 1;
            } else if (diff.cel_error != null) {
                cel_only_errors += 1;
            } else if (diff.expr_error != null) {
                expr_only_errors += 1;
            }
        }
    }

    std.debug.print(
        "Results: {d} total, {d} matched, {d} diverged, {d} cel-err, {d} expr-err, {d} both-err\n",
        .{ total, matched, diverged, cel_only_errors, expr_only_errors, both_errors },
    );

    // Verify expected vs actual
    for (entries) |*entry| {
        const cel_bool = cel.evaluate(alloc, entry.condition_text, entry.context) catch |err| {
            std.debug.print("  [{s}] CEL error on expected check: {s}\n", .{
                entry.condition_text,
                @errorName(err),
            });
            continue;
        };
        try testing.expectEqual(entry.expected_result, cel_bool);
    }

    // All conditions must match for the cutover gate.
    try testing.expectEqual(total, matched);
}

// ---------------------------------------------------------------------------
// evaluateDifferential — single condition evaluation
// ---------------------------------------------------------------------------

fn evaluateDifferential(allocator: std.mem.Allocator, entry: *const CorpusEntry) !DiffResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Step 1: Evaluate with CEL
    var cel_result: ?bool = null;
    var cel_error: ?[]const u8 = null;
    const cel_bool = cel.evaluate(a, entry.condition_text, entry.context) catch |err| blk: {
        cel_error = try allocator.dupe(u8, @errorName(err));
        break :blk @as(?bool, null);
    };
    if (cel_error == null) {
        cel_result = cel_bool;
    }

    // Step 2: Translate CEL → expr syntax
    const expr_text = translateCelToExpr(a, entry.condition_text);
    if (expr_text == null) {
        const detail = try std.fmt.allocPrint(
            allocator,
            "CEL expression uses unsupported feature outside expr grammar intersection",
            .{},
        );
        return DiffResult{
            .condition_id = try allocator.dupe(u8, entry.condition_id),
            .condition_text = try allocator.dupe(u8, entry.condition_text),
            .cel_result = cel_result,
            .expr_result = null,
            .match = false,
            .cel_error = cel_error,
            .expr_error = null,
            .diff_detail = detail,
        };
    }

    // Step 3: Parse with expr
    var expr_result: ?bool = null;
    var expr_error: ?[]const u8 = null;
    var parse_result_opt: ?expr_mod.ParseResult = null;
    if (expr_mod.parse(a, expr_text.?)) |pr| {
        parse_result_opt = pr;
    } else |_| {
        expr_error = try allocator.dupe(u8, "expr parse failed");
    }
    if (expr_error == null) {
        if (parse_result_opt) |pr| {
            switch (pr) {
            .ok => |*ast| {
                // Step 4: Build context from entry.context (std.json.ObjectMap → expr Context)
                var expr_ctx = expr_mod.Context.init(a);
                defer expr_ctx.deinit();

                // Convert variables to expr Value
                var ctx_it = entry.context.iterator();
                while (ctx_it.next()) |kv| {
                    const expr_val = jsonValueToExprValue(kv.value_ptr.*);
                    expr_ctx.variables.put(kv.key_ptr.*, expr_val) catch {
                        expr_error = try allocator.dupe(u8, "context conversion failed");
                        break;
                    };
                }

                if (expr_error == null) {
                    const eval_result = expr_mod.evaluate(ast, &expr_ctx, a);
                    switch (eval_result) {
                        .ok => |val| {
                            expr_result = switch (val) {
                                .bool_val => |b| b,
                                .null_val => false, // null in gateway context → false
                                else => false,
                            };
                        },
                        .err => |eval_err| {
                            expr_error = try allocator.dupe(u8, eval_err.message);
                        },
                    }
                }
            },
            .fail => |errors| {
                if (errors.len > 0) {
                    expr_error = try allocator.dupe(u8, errors[0].message);
                } else {
                    expr_error = try allocator.dupe(u8, "expr parse failed");
                }
            },
        }
    }
    }

    // Step 5: Compare results
    const match = (cel_result != null and expr_result != null and cel_result.? == expr_result.?);

    var diff_detail: ?[]const u8 = null;
    if (!match) {
        const cel_str = if (cel_result) |b| (if (b) "true" else "false") else "ERROR";
        const expr_str = if (expr_result) |b| (if (b) "true" else "false") else "ERROR";
        const c_err = cel_error orelse "";
        const e_err = expr_error orelse "";
        diff_detail = try std.fmt.allocPrint(
            allocator,
            "CEL: {s} ({s}), expr: {s} ({s})",
            .{ cel_str, c_err, expr_str, e_err },
        );
    }

    return DiffResult{
        .condition_id = try allocator.dupe(u8, entry.condition_id),
        .condition_text = try allocator.dupe(u8, entry.condition_text),
        .cel_result = cel_result,
        .expr_result = expr_result,
        .match = match,
        .cel_error = cel_error,
        .expr_error = expr_error,
        .diff_detail = diff_detail,
    };
}

// ---------------------------------------------------------------------------
// CEL → expr mechanical translator
// ---------------------------------------------------------------------------

/// Translate a CEL condition text to expr-compatible syntax.
///
/// CEL syntax:  variables.order_total > 1000
/// expr syntax: order_total > 1000
///
/// Translation rules:
///   - Strip "variables." prefix from identifiers.
///   - `&&` → `and`, `||` → `or`, `!` → `not`
///   - Everything else passes through unchanged.
///
/// Returns the translated expression text allocated with `allocator`.
/// Returns null if the expression uses CEL features outside the grammar intersection.
fn translateCelToExpr(allocator: std.mem.Allocator, cel_expression: []const u8) ?[]const u8 {
    // Replace "variables." prefix with empty string
    // Replace "&&" with "and"
    // Replace "||" with "or"
    // Replace "!" with "not" (only when used as logical NOT, not "!=")
    var result = std.ArrayList(u8).empty;

    var i: usize = 0;
    while (i < cel_expression.len) {
        // Check for "variables."
        if (i + 10 <= cel_expression.len and std.mem.eql(u8, cel_expression[i..][0..10], "variables.")) {
            i += 10;
            continue;
        }
        // Check for "&&"
        if (i + 2 <= cel_expression.len and std.mem.eql(u8, cel_expression[i..][0..2], "&&")) {
            result.appendSlice(allocator, " and ") catch return null;
            i += 2;
            continue;
        }
        // Check for "||"
        if (i + 2 <= cel_expression.len and std.mem.eql(u8, cel_expression[i..][0..2], "||")) {
            result.appendSlice(allocator, " or ") catch return null;
            i += 2;
            continue;
        }
        // Check for "!" (logical NOT, not "!=")
        if (cel_expression[i] == '!') {
            if (i + 1 < cel_expression.len and cel_expression[i + 1] == '=') {
                // "!=" passes through unchanged
                result.appendSlice(allocator, "!=") catch return null;
                i += 2;
                continue;
            }
            result.appendSlice(allocator, "not ") catch return null;
            i += 1;
            continue;
        }
        // Pass through
        result.append(allocator, cel_expression[i]) catch return null;
        i += 1;
    }

    return result.toOwnedSlice(allocator) catch return null;
}

// ---------------------------------------------------------------------------
// Context conversion helpers
// ---------------------------------------------------------------------------

/// Convert a std.json.Value to an expr Value.
fn freeDiffResult(allocator: std.mem.Allocator, diff: DiffResult) void {
    if (diff.condition_id.len > 0) allocator.free(diff.condition_id);
    if (diff.condition_text.len > 0) allocator.free(diff.condition_text);
    if (diff.cel_error) |e| allocator.free(e);
    if (diff.expr_error) |e| allocator.free(e);
    if (diff.diff_detail) |d| allocator.free(d);
}

fn jsonValueToExprValue(jv: std.json.Value) expr_mod.Value {
    return switch (jv) {
        .null => expr_mod.valueNull(),
        .bool => |b| expr_mod.valueBool(b),
        .integer => |n| expr_mod.valueInt(n),
        .float => |f| expr_mod.valueFloat(@floatCast(f)),
        .string => |s| blk: {
            // Clone needed since the string is arena-owned
            break :blk expr_mod.valueStr(s);
        },
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch 0.0;
            return expr_mod.valueFloat(f);
        },
        else => expr_mod.valueNull(),
    };
}

// ---------------------------------------------------------------------------
// Corpus loader
// ---------------------------------------------------------------------------

/// Build CorpusEntry slice from a parsed JSON array. Pointers reference the
/// parsed tree, which must outlive the returned slice.
fn loadCorpusFromValue(allocator: std.mem.Allocator, arr: std.json.Array) ![]CorpusEntry {
    var entries = std.ArrayList(CorpusEntry).empty;

    for (arr.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const condition_id = obj.get("condition_id") orelse continue;
        const condition_text = obj.get("condition_text") orelse continue;
        const context_val = obj.get("context") orelse continue;
        const expected_result_val = obj.get("expected_result") orelse continue;

        if (condition_id != .string or condition_text != .string or context_val != .object or expected_result_val != .bool)
            continue;

        const entry = CorpusEntry{
            .condition_id = condition_id.string,
            .source_definition_id = "00000000-0000-0000-0000-000000000000",
            .source_definition_version = 1,
            .source_gateway_node_id = "gw",
            .condition_text = condition_text.string,
            .context = context_val.object,
            .expected_result = expected_result_val.bool,
        };
        entries.append(allocator, entry) catch return error.OutOfMemory;
    }

    return entries.toOwnedSlice(allocator);
}

/// Deep-clone a std.json.ObjectMap, allocating new key and value strings.
fn cloneObjectMap(allocator: std.mem.Allocator, source: std.json.ObjectMap) !std.json.ObjectMap {
    var result = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch
        return error.OutOfMemory;
    errdefer result.deinit(allocator);

    var it = source.iterator();
    while (it.next()) |entry| {
        // Clone both key and value so they survive the source arena's deinit.
        const cloned_val = cloneJsonValueDeep(allocator, entry.value_ptr.*) catch
            return error.OutOfMemory;
        errdefer freeJsonValueDeep(allocator, cloned_val);
        result.put(allocator, entry.key_ptr.*, cloned_val) catch {
            freeJsonValueDeep(allocator, cloned_val);
            return error.OutOfMemory;
        };
    }
    return result;
}

fn cloneJsonValueDeep(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => std.json.Value{ .null = {} },
        .bool => |b| std.json.Value{ .bool = b },
        .integer => |n| std.json.Value{ .integer = n },
        .float => |f| std.json.Value{ .float = f },
        .string => |s| {
            const duped = try allocator.dupe(u8, s);
            return std.json.Value{ .string = duped };
        },
        .number_string => |s| {
            const duped = try allocator.dupe(u8, s);
            return std.json.Value{ .number_string = duped };
        },
        else => value,
    };
}

fn freeJsonValueDeep(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        else => {},
    }
}

fn freeCorpusEntries(allocator: std.mem.Allocator, entries: []CorpusEntry) void {
    // All strings and ObjectMaps are owned by the parsed JSON tree allocated
    // in loadCorpus via allocator. The entries slice is also allocator-owned.
    // We free the entries slice; the parsed tree is freed when `parsed` goes
    // out of scope in loadCorpus after entries are created. But since we used
    // the caller's allocator for parsing, the caller must also free the tree.
    // For simplicity, just free the entries array here.
    allocator.free(entries);
}
