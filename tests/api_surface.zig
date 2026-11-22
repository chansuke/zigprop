//! The public API surface, pinned (design v0.3 §7.5; verification
//! pipeline plan §2-3): zigprop's pub declarations, the Report and
//! Failure tags, and the Config and Limits fields with whether each has a
//! default. This pins names and shapes only; it says nothing about
//! behaviour. `zigprop.internal` is pinned by name, not by content.
//!
//! Zig 0.17.1's `@typeInfo` lists a struct's pub declarations in
//! `decl_names`, so additions and removals are both detected.

const std = @import("std");
const zigprop = @import("zigprop");

const changed_message =
    "public API surface changed: update the expected list in tests/api_surface.zig AND record it in docs " ++
    "(design §5.8 breaking-change list / README); additions of defaulted fields are compatible, " ++
    "removals and variant additions are breaking";

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Fails with the added and removed names when `actual` and `expected`
/// differ as sets.
fn expectSurface(what: []const u8, expected: []const []const u8, actual: []const []const u8) !void {
    var same = true;
    for (actual) |n| if (!contains(expected, n)) {
        if (same) std.debug.print("{s}\n{s}:\n", .{ changed_message, what });
        same = false;
        std.debug.print("  added:   {s}\n", .{n});
    };
    for (expected) |n| if (!contains(actual, n)) {
        if (same) std.debug.print("{s}\n{s}:\n", .{ changed_message, what });
        same = false;
        std.debug.print("  removed: {s}\n", .{n});
    };
    try std.testing.expect(same);
}

fn declNames(comptime T: type) []const []const u8 {
    const names = @typeInfo(T).@"struct".decl_names;
    var out: [names.len][]const u8 = undefined;
    for (names, 0..) |n, i| out[i] = n;
    const final = out;
    return &final;
}

fn tagNames(comptime U: type) []const []const u8 {
    const names = @typeInfo(@typeInfo(U).@"union".tag_type.?).@"enum".field_names;
    var out: [names.len][]const u8 = undefined;
    for (names, 0..) |n, i| out[i] = n;
    const final = out;
    return &final;
}

/// Each field as "<name> (defaulted)" or "<name> (required)".
fn fieldSurface(comptime T: type) []const []const u8 {
    const info = @typeInfo(T).@"struct";
    var out: [info.field_names.len][]const u8 = undefined;
    for (info.field_names, info.field_types, info.field_attrs, 0..) |n, ft, a, i|
        out[i] = n ++ if (a.defaultValue(ft) != null) " (defaulted)" else " (required)";
    const final = out;
    return &final;
}

test "api surface: zigprop's pub declarations" {
    try expectSurface("zigprop pub declarations", &.{
        "Choice",            "Limits",         "GenContext",        "Generator",
        "GeneratorWith",     "generate",       "generator_version", "max_depth_cap",
        "Case",              "PropertyWith",   "Failure",           "check",
        "checkCustom",       "checkWith",      "checkOrError",      "checkCustomOrError",
        "checkWithOrError",  "Config",         "Report",            "Origin",
        "RegressionSummary", "StaleReason",    "StaleEntry",        "ShrinkOutcome",
        "Regression",        "RegressionFile", "Fingerprint",       "FingerprintMismatch",
        "internal",
    }, comptime declNames(zigprop));
}

test "api surface: Report and Failure tags" {
    try expectSurface("Report tags", &.{ "passed", "failed", "gave_up" }, comptime tagNames(zigprop.Report));
    try expectSurface("Failure tags", &.{ "returned_false", "returned_error" }, comptime tagNames(zigprop.Failure));
}

test "api surface: Config and Limits fields and defaults" {
    try expectSurface("Config fields", &.{
        "seed (defaulted)",          "max_cases (defaulted)",     "max_discards (defaulted)",
        "shrink_budget (defaulted)", "limits (defaulted)",        "regressions (defaulted)",
        "regression_id (defaulted)", "fail_on_stale (defaulted)",
    }, comptime fieldSurface(zigprop.Config));
    try expectSurface("Limits fields", &.{
        "max_len (defaulted)",   "max_total_elements (defaulted)",
        "max_draws (defaulted)", "max_depth (defaulted)",
    }, comptime fieldSurface(zigprop.Limits));
}

// v0.4 (design v0.4 D61): the Case methods, the report's payload and the
// fingerprint are promised surface from v0.4 on.

test "api surface: Case declarations and fields" {
    try expectSurface("Case pub declarations", &.{ "generate", "index", "choose", "steps", "Steps" }, comptime declNames(zigprop.Case));
    try expectSurface("Case fields", &.{ "allocator (required)", "impl (defaulted)" }, comptime fieldSurface(zigprop.Case));
}

test "api surface: Report.Failed and Fingerprint fields" {
    try expectSurface("Report.Failed fields", &.{
        "allocator (required)",      "origin (required)",         "failure (required)",
        "choices (required)",        "shrunk_choices (required)", "fingerprint (required)",
        "original_value (required)", "shrunk_value (required)",   "shrink_evaluations (required)",
        "shrink_outcome (required)", "regressions (required)",    "original_draws (defaulted)",
        "shrunk_draws (defaulted)",  "reproduced (defaulted)",
    }, comptime fieldSurface(zigprop.Report.Failed));
    try expectSurface("Fingerprint fields", &.{
        "type_hash (required)",        "max_len (required)",         "max_depth (required)",
        "custom_generator (required)", "property_draws (defaulted)",
    }, comptime fieldSurface(zigprop.Fingerprint));
}

test "api surface: checkWith's signature" {
    // A generic function's type equals no hand-written function type in
    // Zig 0.17.1, so the signature is pinned by its type name (v0.4 M0
    // research note §4.4-4, alternative 1). The name also carries
    // internal file and declaration names: an internal rename turns this
    // red too, and then only the expected string needs updating.
    try std.testing.expectEqualStrings(
        "fn (mem.Allocator, comptime type, comptime type, anytype, anytype, anytype, runner.Config) @typeInfo(@typeInfo(@TypeOf(runner.checkWith)).@\"fn\".return_type.?).error_union.error_set!runner.Report",
        @typeName(@TypeOf(zigprop.checkWith)),
    );
}
