//! Meta tests for milestone 3: shrinking (design §6, §8).

const std = @import("std");
const zigprop = @import("zigprop");
const Source = zigprop.internal.Source;
const GenState = zigprop.internal.GenState;
const Choice = zigprop.Choice;
const GenContext = zigprop.GenContext;

fn singleDraw(ctx: *GenContext) anyerror!u32 {
    // The dedicated single-choice encoding of design §8.
    return @intCast(ctx.range(1 << 32));
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
    try std.testing.expect(report.failed.regression_index != null);
    try std.testing.expectEqual(@as(u64, 10), report.failed.shrunk_choices[0].value);

    const minimal = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{10} }};
    var report2 = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .regressions = &minimal,
        .regression_id = "t",
    });
    defer report2.deinit();
    try std.testing.expect(report2.failed.regression_index != null);
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
    var ctx1_state: GenState = undefined;
    var ctx1 = zigprop.internal.genContextForTest(&ctx1_state, &rep1, std.testing.allocator, .{});
    const original = try zigprop.generate(u32, &ctx1);

    var rep2 = Source.initReplay(std.testing.allocator, f.shrunk_choices, 100_000);
    defer rep2.deinit();
    var ctx2_state: GenState = undefined;
    var ctx2 = zigprop.internal.genContextForTest(&ctx2_state, &rep2, std.testing.allocator, .{});
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
    var ctx_state: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &rep, std.testing.allocator, .{});
    const v = try zigprop.generate([]const u8, &ctx);
    defer std.testing.allocator.free(v);
    try std.testing.expect(!allBytesSmall(v));
}

// ---------------------------------------------------------------------
// Tests added after the Sol milestone-3 review (2026-11-19)
// ---------------------------------------------------------------------

test "shrink: initialization OOM does not leak the copied sequence" {
    // fail_index counts allocations from 0: the copies are choices
    // (0), keys (1), skips (2) and display (3). Failing the last one
    // must not leak the first three.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const initial = [_]Choice{.{ .bound = 10, .value = 7 }};
    try std.testing.expectError(error.OutOfMemory, zigprop.internal.shrink(
        failing.allocator(),
        u32,
        null,
        smallOnly,
        .{},
        10,
        &initial,
        &.{7},
        &.{false},
        "7",
    ));
}

var sticky_gen_calls: usize = 0;
fn stickyThenDiscard(ctx: *GenContext) anyerror!u32 {
    sticky_gen_calls += 1;
    _ = ctx.range(10);
    ctx.src.sticky_error = error.OutOfMemory; // a recording failure landed
    return error.InvalidGeneration;
}

test "classification: sticky error outranks InvalidGeneration (MF5)" {
    sticky_gen_calls = 0;
    try std.testing.expectError(error.OutOfMemory, zigprop.checkCustom(
        std.testing.allocator,
        u32,
        stickyThenDiscard,
        smallOnly,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 1), sticky_gen_calls);
}

var boom_calls: usize = 0;
fn failThenBoom(ctx: *GenContext) anyerror!u32 {
    boom_calls += 1;
    if (boom_calls == 1) return @intCast(ctx.range(1 << 32));
    return error.Boom;
}

test "shrink: a generator error during shrinking propagates, never becomes an outcome" {
    boom_calls = 0;
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{25} }};
    try std.testing.expectError(error.Boom, zigprop.checkCustom(std.testing.allocator, u32, failThenBoom, smallOnly, .{
        .regressions = &entries,
        .regression_id = "t",
    }));
}

var counting_calls: usize = 0;
fn countingDraw(ctx: *GenContext) anyerror!u32 {
    counting_calls += 1;
    return @intCast(ctx.range(1 << 32));
}

test "shrink: reported evaluations equal actual generator calls" {
    counting_calls = 0;
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{25} }};
    var report = try zigprop.checkCustom(std.testing.allocator, u32, countingDraw, smallOnly, .{
        .regressions = &entries,
        .regression_id = "t",
    });
    defer report.deinit();
    try std.testing.expect(report.failed.regression_index != null);
    // 1 call for the regression replay itself + 1 per shrink evaluation.
    try std.testing.expectEqual(counting_calls, 1 + report.failed.shrink_evaluations);
    try std.testing.expectEqual(@as(u64, 10), report.failed.shrunk_choices[0].value);
}

test "shrink: budget boundary — exact fit is fixed_point, one less is exhausted" {
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{10} }};
    // Shrinking {10} for x < 10 needs exactly 6 evaluations:
    // delete, zero, and decreases by 8/4/2/1 (all pass).
    var r6 = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .regressions = &entries,
        .regression_id = "t",
        .shrink_budget = 6,
    });
    defer r6.deinit();
    try std.testing.expect(r6.failed.regression_index != null);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, r6.failed.shrink_outcome);
    try std.testing.expectEqual(@as(usize, 6), r6.failed.shrink_evaluations);

    var r5 = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .regressions = &entries,
        .regression_id = "t",
        .shrink_budget = 5,
    });
    defer r5.deinit();
    try std.testing.expect(r5.failed.regression_index != null);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.budget_exhausted, r5.failed.shrink_outcome);
    try std.testing.expectEqual(@as(usize, 5), r5.failed.shrink_evaluations);
}

test "shrink: an acceptance on the last budget unit still reports exhaustion next" {
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{25} }};
    // Evaluations: delete (pass), zero (pass), -16 -> 9 (pass),
    // -8 -> 17 (fail, accepted on the 4th and last unit).
    var report = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .regressions = &entries,
        .regression_id = "t",
        .shrink_budget = 4,
    });
    defer report.deinit();
    try std.testing.expect(report.failed.regression_index != null);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.budget_exhausted, report.failed.shrink_outcome);
    try std.testing.expectEqual(@as(usize, 4), report.failed.shrink_evaluations);
    try std.testing.expectEqual(@as(u64, 17), report.failed.shrunk_choices[0].value);
}

fn noDraw(_: *GenContext) anyerror!u32 {
    return 7;
}
fn isZero(x: u32) bool {
    return x == 0;
}

test "shrink: an empty failing sequence is already a fixed point" {
    var report = try zigprop.checkCustom(std.testing.allocator, u32, noDraw, isZero, .{});
    defer report.deinit();
    const f = report.failed;
    try std.testing.expectEqual(@as(usize, 0), f.choices.len);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, f.shrink_outcome);
    try std.testing.expectEqual(@as(usize, 0), f.shrink_evaluations);
}

fn drawUntilZero(ctx: *GenContext) anyerror![]const u32 {
    var list: std.ArrayList(u32) = .empty;
    while (true) {
        const v: u32 = @intCast(ctx.range(100));
        if (v == 0) break;
        try list.append(ctx.allocator, v);
    }
    return list.toOwnedSlice(ctx.allocator);
}

fn twoBigAndLong(xs: []const u32) bool {
    if (xs.len < 3) return true;
    var big: usize = 0;
    for (xs) |v| {
        if (v >= 5) big += 1;
    }
    return big < 2;
}

test "shrink: P1 tries unaligned chunk positions" {
    // {8,1,9,1,0} draws the slice {8,1,9,1} (fails: len >= 3, two
    // values >= 5). The only productive size-2 deletion is the
    // trailing chunk at position 3 (dropping "1,0"), which a scan
    // stepping by the chunk size (positions 0, 2) never tries.
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{ 8, 1, 9, 1, 0 } }};
    var report = try zigprop.checkCustom(std.testing.allocator, []const u32, drawUntilZero, twoBigAndLong, .{
        .regressions = &entries,
        .regression_id = "t",
    });
    defer report.deinit();
    const f = report.failed;
    try std.testing.expect(f.regression_index != null);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, f.shrink_outcome);
    // After the trailing deletion, zero-padding ends the slice and
    // P3 reduces the two load-bearing values to the threshold 5.
    // The middle 1 is load-bearing too: zeroing or deleting it ends
    // the slice early (it sits before the terminator), so it stays.
    try std.testing.expectEqual(@as(usize, 4), f.shrunk_choices.len);
    try std.testing.expectEqual(@as(u64, 5), f.shrunk_choices[0].value);
    try std.testing.expectEqual(@as(u64, 1), f.shrunk_choices[1].value);
    try std.testing.expectEqual(@as(u64, 5), f.shrunk_choices[2].value);
    try std.testing.expectEqual(@as(u64, 0), f.shrunk_choices[3].value);
}
