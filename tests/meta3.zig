//! Meta tests for milestone 3: shrinking (design §6, §8).

const std = @import("std");
const zigprop = @import("zigprop");
const Source = zigprop.Source;
const Choice = zigprop.Choice;
const GenContext = zigprop.GenContext;

fn singleDraw(ctx: *GenContext) anyerror!u32 {
    // The dedicated single-choice encoding of design §8.
    return @intCast(ctx.src.range(1 << 32));
}

fn smallOnly(x: u32) bool {
    return x < 10;
}

test "shrink: the single-draw encoding shrinks to exactly 10 (design §8)" {
    var report = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{ .seed = 1, .max_cases = 100 });
    defer report.deinit();
    const f = report.failed;
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, f.shrink_outcome);
    try std.testing.expectEqual(@as(usize, 1), f.shrunk_choices.len);
    try std.testing.expectEqual(@as(u64, 10), f.shrunk_choices[0].value);
    try std.testing.expectEqualStrings("10", f.shrunk_value);
    try std.testing.expect(f.shrink_evaluations > 0);
}

test "shrink: a regression entry shrinks too, and an already-minimal one stays" {
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{25} }};
    var report = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .regressions = &entries,
        .regression_id = "t",
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(u64, 10), report.failed.shrunk_choices[0].value);

    const minimal = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{10} }};
    var report2 = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .regressions = &minimal,
        .regression_id = "t",
    });
    defer report2.deinit();
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, report2.failed.shrink_outcome);
    try std.testing.expectEqual(@as(u64, 10), report2.failed.shrunk_choices[0].value);
}

test "shrink: budget exhaustion is reported and bounds the evaluations" {
    var report = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .seed = 1,
        .max_cases = 100,
        .shrink_budget = 3,
    });
    defer report.deinit();
    const f = report.failed;
    try std.testing.expectEqual(zigprop.ShrinkOutcome.budget_exhausted, f.shrink_outcome);
    try std.testing.expectEqual(@as(usize, 3), f.shrink_evaluations);
    // The shrunk-so-far value still fails the property.
    try std.testing.expect(f.shrunk_choices[0].value >= 10);
}

test "shrink: zero budget keeps the original counterexample" {
    var report = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .seed = 1,
        .max_cases = 100,
        .shrink_budget = 0,
    });
    defer report.deinit();
    const f = report.failed;
    try std.testing.expectEqual(zigprop.ShrinkOutcome.budget_exhausted, f.shrink_outcome);
    try std.testing.expectEqual(@as(usize, 0), f.shrink_evaluations);
    try std.testing.expectEqualSlices(Choice, f.choices, f.shrunk_choices);
}

test "shrink: built-in integers — failure preserved, value not larger (design §8)" {
    var report = try zigprop.check(std.testing.allocator, u32, smallOnly, .{ .seed = 5, .max_cases = 100 });
    defer report.deinit();
    const f = report.failed;

    var rep1 = Source.initReplay(std.testing.allocator, f.choices, 100_000);
    defer rep1.deinit();
    var ctx1 = GenContext{ .src = &rep1, .allocator = std.testing.allocator, .limits = .{} };
    const original = try zigprop.generate(u32, &ctx1);

    var rep2 = Source.initReplay(std.testing.allocator, f.shrunk_choices, 100_000);
    defer rep2.deinit();
    var ctx2 = GenContext{ .src = &rep2, .allocator = std.testing.allocator, .limits = .{} };
    const shrunk = try zigprop.generate(u32, &ctx2);

    try std.testing.expect(!smallOnly(shrunk));
    try std.testing.expect(shrunk <= original);
}

fn allBytesSmall(xs: []const u8) bool {
    for (xs) |b| {
        if (b > 100) return false;
    }
    return true;
}

fn shortlexLess(a: []const Choice, b: []const Choice) bool {
    if (a.len != b.len) return a.len < b.len;
    for (a, b) |x, y| {
        if (x.value != y.value) return x.value < y.value;
    }
    return false;
}

test "shrink: slices shrink to a shortlex-smaller still-failing sequence" {
    var report = try zigprop.check(std.testing.allocator, []const u8, allBytesSmall, .{ .seed = 0, .max_cases = 200 });
    defer report.deinit();
    const f = report.failed;
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, f.shrink_outcome);
    try std.testing.expect(f.shrink_evaluations > 0);
    // The stored sequence never grows under shrinking (MF2).
    try std.testing.expect(!shortlexLess(f.choices, f.shrunk_choices));

    // The shrunk sequence still regenerates a failing slice.
    var rep = Source.initReplay(std.testing.allocator, f.shrunk_choices, 100_000);
    defer rep.deinit();
    var ctx = GenContext{ .src = &rep, .allocator = std.testing.allocator, .limits = .{} };
    const v = try zigprop.generate([]const u8, &ctx);
    defer std.testing.allocator.free(v);
    try std.testing.expect(!allBytesSmall(v));
}
