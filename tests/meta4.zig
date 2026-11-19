//! Milestone 4 follow-up: the rank-normalized acceptance rule and
//! the P4 re-expression pass (design §6, v2.1).
//!
//! The §9 T1 target exposed the trap these tests pin: an integer
//! discovered in the boundary class (or diverted into it) could not
//! shrink to the true minimum 2^28, because choice-value shortlex
//! ranks the boundary encoding [1, idx] below [3, 2^28] while the
//! boundary class cannot even represent 2^28.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const GenContext = zigprop.GenContext;

fn belowVarintLimit(x: u32) bool {
    return x < 268435456; // 2^28
}

fn replayValue(choices: []const Choice) !u32 {
    var src = zigprop.internal.Source.initReplay(std.testing.allocator, choices, 100_000);
    defer src.deinit();
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, std.testing.allocator, .{});
    return zigprop.generate(u32, &ctx);
}

test "v2.1: integer pairs are annotated with the value rank as key" {
    // [1, 2] = boundary class, index 2 -> value 2^32 - 2.
    const seq = [_]Choice{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 } };
    var src = zigprop.internal.Source.initReplay(std.testing.allocator, &seq, 100_000);
    defer src.deinit();
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, std.testing.allocator, .{});
    const v = try zigprop.generate(u32, &ctx);
    try std.testing.expectEqual(@as(u32, 4294967294), v);
    try std.testing.expectEqual(@as(u64, 4294967294), src.recorded_keys.items[0]);
    try std.testing.expect(!src.recorded_skip.items[0]);
    try std.testing.expect(src.recorded_skip.items[1]);
}

test "v2.1: a boundary-class failure escapes the trap and shrinks to exactly 2^28" {
    // Regression: the failing sequence starts in the boundary class,
    // whose reachable set does not contain 2^28. P4 must re-express
    // the pair in the full-domain class so P3 can descend the rank.
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{ 1, 2 } }};
    var report = try zigprop.check(std.testing.allocator, u32, belowVarintLimit, .{
        .regressions = &entries,
        .regression_id = "t",
    });
    defer report.deinit();
    switch (report) {
        .failed => |f| {
            try std.testing.expect(f.origin == .regression);
            try std.testing.expectEqual(@as(u32, 268435456), try replayValue(f.shrunk_choices));
        },
        else => return error.ExpectedFailure,
    }
}

test "v2.1: a full-domain failure is not diverted into the boundary class" {
    // Rank 4000000002: rank % 4 == 2, so the old class 3 -> 1
    // decrease produced the boundary value 2^32 - 2 and was accepted
    // as "smaller". Key comparison rejects the detour (its key is
    // larger) and the rank descends to exactly 2^28.
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{ 3, 4000000002 } }};
    var report = try zigprop.check(std.testing.allocator, u32, belowVarintLimit, .{
        .regressions = &entries,
        .regression_id = "t",
    });
    defer report.deinit();
    switch (report) {
        .failed => |f| {
            try std.testing.expect(f.origin == .regression);
            try std.testing.expectEqual(@as(u32, 268435456), try replayValue(f.shrunk_choices));
        },
        else => return error.ExpectedFailure,
    }
}
