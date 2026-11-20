//! v0.3 M4b: the general entry point, failure kinds, named reports,
//! display regeneration and the regression-entry workflow (design
//! v0.3 §5, D26-D32, D36).

const std = @import("std");
const zigprop = @import("zigprop");
const GenContext = zigprop.GenContext;
const Case = zigprop.Case;

fn singleDraw(ctx: *GenContext) anyerror!u32 {
    return @intCast(ctx.range(1 << 32));
}

fn smallOnly(x: u32) bool {
    return x < 10;
}

// ---------------------------------------------------------------------
// Property errors (§5.3) and failure kinds (§5.4)
// ---------------------------------------------------------------------

fn oomWhenBig(_: void, _: *Case, x: u32) anyerror!bool {
    if (x >= 10) return error.OutOfMemory;
    return true;
}

fn invalidWhenBig(_: void, _: *Case, x: u32) anyerror!bool {
    if (x >= 10) return error.InvalidGeneration;
    return true;
}

test "api: property errors are failures, never check errors" {
    // error.OutOfMemory from the property is a counterexample, not an
    // infrastructure error of check.
    var r1 = try zigprop.checkWith(std.testing.allocator, u32, void, {}, null, oomWhenBig, .{ .seed = 1 });
    defer r1.deinit();
    try std.testing.expect(r1 == .failed);
    try std.testing.expect(r1.failed.failure.eql(.{ .returned_error = error.OutOfMemory }));
    try std.testing.expectEqualStrings("10", r1.failed.shrunk_value);

    // error.InvalidGeneration from the property is a failure too, not a
    // discard (it is the generator's discard signal only).
    var r2 = try zigprop.checkWith(std.testing.allocator, u32, void, {}, null, invalidWhenBig, .{ .seed = 1 });
    defer r2.deinit();
    try std.testing.expect(r2 == .failed);
    try std.testing.expect(r2.failed.failure.eql(.{ .returned_error = error.InvalidGeneration }));
}

fn twoKinds(_: void, _: *Case, x: u32) anyerror!bool {
    if (x >= 100) return error.Big;
    if (x >= 10) return error.Medium;
    return true;
}

fn genSingle(_: void, ctx: *GenContext) anyerror!u32 {
    return singleDraw(ctx);
}

test "api: shrinking preserves the error kind" {
    // 500 fails with error.Big. The smallest failure overall is 10
    // (error.Medium), but shrinking keeps the kind: it stops at 100.
    const entries = [_]zigprop.Regression{.{ .id = "k", .gen_version = zigprop.generator_version, .choices = &.{500} }};
    var r = try zigprop.checkWith(std.testing.allocator, u32, void, {}, genSingle, twoKinds, .{
        .regressions = &entries,
        .regression_id = "k",
    });
    defer r.deinit();
    // The search started from the entry's 500, not from a random draw.
    try std.testing.expectEqual(@as(usize, 0), r.failed.origin.regression.index);
    try std.testing.expect(r.failed.failure.eql(.{ .returned_error = error.Big }));
    try std.testing.expectEqual(@as(u64, 100), r.failed.shrunk_choices[0].value);
    try std.testing.expectEqualStrings("100", r.failed.shrunk_value);
}

test "api: a bool property's failure kind is returned_false" {
    var r = try zigprop.check(std.testing.allocator, u32, smallOnly, .{ .seed = 1 });
    defer r.deinit();
    try std.testing.expect(r.failed.failure == .returned_false);
}

// ---------------------------------------------------------------------
// checkWith: context, generator, case allocator (§5.2)
// ---------------------------------------------------------------------

const Offsets = struct {
    base: u32,
    property_calls: usize = 0,
};

fn genOffset(o: *Offsets, ctx: *GenContext) anyerror!u32 {
    return o.base + @as(u32, @intCast(ctx.range(10)));
}

fn propOffset(o: *Offsets, case: *Case, x: u32) anyerror!bool {
    o.property_calls += 1;
    // The case allocator is the attempt arena: no free needed.
    const scratch = try case.allocator.alloc(u32, 4);
    scratch[0] = x;
    return scratch[0] >= o.base and scratch[0] < o.base + 10;
}

test "api: checkWith hands the context to the generator and the property" {
    var o: Offsets = .{ .base = 1000 };
    var r = try zigprop.checkWith(std.testing.allocator, u32, *Offsets, &o, genOffset, propOffset, .{ .max_cases = 25 });
    defer r.deinit();
    try std.testing.expect(r == .passed);
    try std.testing.expectEqual(@as(usize, 25), r.passed.cases);
    try std.testing.expectEqual(@as(usize, 25), o.property_calls);
}

// ---------------------------------------------------------------------
// Reports (§5.2, D29)
// ---------------------------------------------------------------------

test "api: a regression failure reports its origin, not a seed" {
    const entries = [_]zigprop.Regression{
        .{ .id = "other", .gen_version = zigprop.generator_version, .choices = &.{25} },
        .{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{25} },
    };
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .seed = 77,
        .regressions = &entries,
        .regression_id = "t",
    });
    defer r.deinit();
    switch (r.failed.origin) {
        .regression => |o| {
            try std.testing.expectEqual(@as(usize, 1), o.index);
            try std.testing.expectEqual(@as(?zigprop.StaleReason, null), o.stale);
        },
        .random => return error.TestUnexpectedResult,
    }
}

test "api: a random failure reports seed and attempt" {
    var r = try zigprop.check(std.testing.allocator, u32, smallOnly, .{ .seed = 3 });
    defer r.deinit();
    try std.testing.expectEqual(@as(u64, 3), r.failed.origin.random.seed);
}

fn alwaysTrue(_: u32) bool {
    return true;
}

fn alwaysDiscard(_: *GenContext) anyerror!u32 {
    return error.InvalidGeneration;
}

test "api: every report variant owns its regression summary" {
    // A stale entry on each variant; std.testing.allocator catches a
    // missing free.
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = 999, .choices = &.{1} }};
    const cfg: zigprop.Config = .{ .regressions = &entries, .regression_id = "t", .max_cases = 3, .max_discards = 2 };
    var p = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, cfg);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.passed.regressions.stale.len);
    var g = try zigprop.checkCustom(std.testing.allocator, u32, alwaysDiscard, alwaysTrue, cfg);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.gave_up.regressions.stale.len);
    var f = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, cfg);
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 1), f.failed.regressions.stale.len);
    try std.testing.expectEqual(zigprop.StaleReason.gen_version_mismatch, f.failed.regressions.stale[0].reason);
}

fn propCustomFalse(_: void, _: *Case, _: u32) anyerror!bool {
    return false;
}

test "api: the OrError wrappers map outcomes to errors" {
    try zigprop.checkCustomOrError(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .max_cases = 5 });
    try std.testing.expectError(error.PropertyFailed, zigprop.checkCustomOrError(std.testing.allocator, u32, singleDraw, smallOnly, .{}));
    try std.testing.expectError(error.GaveUp, zigprop.checkCustomOrError(std.testing.allocator, u32, alwaysDiscard, alwaysTrue, .{ .max_discards = 3 }));
    try std.testing.expectError(error.PropertyFailed, zigprop.checkWithOrError(std.testing.allocator, u32, void, {}, genSingle, propCustomFalse, .{}));
}

// ---------------------------------------------------------------------
// Display regeneration (§5.5, D30)
// ---------------------------------------------------------------------

fn sortsInPlaceAndFails(xs: []const u32) bool {
    // Mutates its input, then fails for any slice of length >= 3.
    std.mem.sort(u32, @constCast(xs), {}, std.sort.asc(u32));
    return xs.len < 3;
}

test "display: a mutating property does not corrupt the original" {
    // [3, 1, 2] as []const u32: length 3, then (class 0, value) pairs.
    const entries = [_]zigprop.Regression{.{ .id = "d", .gen_version = zigprop.generator_version, .choices = &.{ 3, 0, 3, 0, 1, 0, 2 } }};
    var r = try zigprop.check(std.testing.allocator, []const u32, sortsInPlaceAndFails, .{
        .regressions = &entries,
        .regression_id = "d",
    });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.failed.origin.regression.index);
    // v0.2 formatted after the property ran and showed { 1, 2, 3 }.
    try std.testing.expectEqualStrings("{ 3, 1, 2 }", r.failed.original_value);
    try std.testing.expectEqualStrings("{ 0, 0, 0 }", r.failed.shrunk_value);
}

const Point = struct {
    x: u8,

    pub fn format(self: Point, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("P<{d}>", .{self.x});
    }
};

fn pointSmall(p: Point) bool {
    return p.x < 10;
}

test "display: a type's own format is used ({f}), others use {any}" {
    const entries = [_]zigprop.Regression{.{ .id = "p", .gen_version = zigprop.generator_version, .choices = &.{ 0, 200 } }};
    var r = try zigprop.check(std.testing.allocator, Point, pointSmall, .{ .regressions = &entries, .regression_id = "p" });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.failed.origin.regression.index);
    try std.testing.expectEqualStrings("P<200>", r.failed.original_value);
    try std.testing.expectEqualStrings("P<10>", r.failed.shrunk_value);
}

// ---------------------------------------------------------------------
// The regression-entry workflow (§5.7, D31)
// ---------------------------------------------------------------------

test "workflow: the printed entry round-trips" {
    // 1. A failure, shrunk from the entry {25} to {10}.
    const start = [_]zigprop.Regression{.{ .id = "m12", .gen_version = zigprop.generator_version, .choices = &.{25} }};
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{ .regressions = &start, .regression_id = "m12" });
    defer r.deinit();
    const entry = try r.failed.regressionEntry(std.testing.allocator, "m12");
    defer std.testing.allocator.free(entry);
    // 2. The printed form is pinned...
    try std.testing.expectEqualStrings(".{ .id = \"m12\", .gen_version = 2, .fingerprint = .{ .type_hash = 0x4d40aac905fa7c87, .max_len = 32, .max_depth = 8, .custom_generator = true }, .choices = .{10} },", entry);
    // ...and is exactly what tests/meta12_entry.zon has in .entries.
    const file_text = @embedFile("meta12_entry.zon");
    try std.testing.expect(std.mem.indexOf(u8, file_text, entry) != null);
    // 3. The pasted file imports as a RegressionFile and the entry
    // replays to the same failure.
    const file: zigprop.RegressionFile = @import("meta12_entry.zon");
    var again = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{ .regressions = file.entries, .regression_id = "m12" });
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 0), again.failed.origin.regression.index);
    try std.testing.expectEqual(@as(u64, 10), again.failed.choices[0].value);
}

test "workflow: an empty choice list prints a pasteable entry" {
    const noDraw = struct {
        fn g(_: *GenContext) anyerror!u32 {
            return 7;
        }
    }.g;
    const alwaysFalse = struct {
        fn p(_: u32) bool {
            return false;
        }
    }.p;
    var r = try zigprop.checkCustom(std.testing.allocator, u32, noDraw, alwaysFalse, .{});
    defer r.deinit();
    const entry = try r.failed.regressionEntry(std.testing.allocator, "a \"quoted\" id");
    defer std.testing.allocator.free(entry);
    try std.testing.expectEqualStrings(".{ .id = \"a \\\"quoted\\\" id\", .gen_version = 2, .fingerprint = .{ .type_hash = 0x4d40aac905fa7c87, .max_len = 32, .max_depth = 8, .custom_generator = true }, .choices = .{} },", entry);
}

test "workflow: a multi-choice entry is printed in zig fmt's tuple form" {
    const entries = [_]zigprop.Regression{.{ .id = "m", .gen_version = zigprop.generator_version, .choices = &.{ 3, 4000000000 } }};
    var r = try zigprop.check(std.testing.allocator, u32, smallOnly, .{ .regressions = &entries, .regression_id = "m" });
    defer r.deinit();
    const entry = try r.failed.regressionEntry(std.testing.allocator, "m");
    defer std.testing.allocator.free(entry);
    // u32 shrinks to 10 as one (class, value) pair: two choices.
    try std.testing.expectEqual(@as(usize, 2), r.failed.shrunk_choices.len);
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, ".{{ .id = \"m\", .gen_version = {d}, .fingerprint = .{{ .type_hash = 0x4d40aac905fa7c87, .max_len = 0, .max_depth = 0, .custom_generator = false }}, .choices = .{{ {d}, {d} }} }},", .{ zigprop.generator_version, r.failed.shrunk_choices[0].value, r.failed.shrunk_choices[1].value });
    try std.testing.expectEqualStrings(expected, entry);
}

test "zon: tests/regressions.zon imports as a RegressionFile" {
    const file: zigprop.RegressionFile = @import("regressions.zon");
    try std.testing.expectEqual(@as(u32, 1), file.version);
    // Its entries can be handed to Config directly.
    var r = try zigprop.check(std.testing.allocator, u32, alwaysTrue, .{ .regressions = file.entries, .regression_id = "any", .max_cases = 1 });
    defer r.deinit();
    try std.testing.expect(r == .passed);
}
