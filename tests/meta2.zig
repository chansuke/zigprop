//! Meta tests for milestone 2: comptime generation (design §4/§4.1)
//! and the runner (design §5/§7), following the §8 list.

const std = @import("std");
const zigprop = @import("zigprop");
const Source = zigprop.internal.Source;
const GenState = zigprop.internal.GenState;
const Choice = zigprop.Choice;
const GenContext = zigprop.GenContext;

fn randomCtx(state: *GenState, src: *Source) GenContext {
    return zigprop.internal.genContextForTest(state, src, std.testing.allocator, .{});
}

fn zeroChoices(n: usize) [256]Choice {
    var arr: [256]Choice = undefined;
    for (&arr) |*c| c.* = .{ .bound = 0, .value = 0 };
    _ = n;
    return arr;
}

test "all-zero draws generate zero values (design §4.1 invariant)" {
    const zeros = zeroChoices(0);
    inline for (.{ u8, u32, u64, i8, i32, i64, u1, i1 }) |T| {
        var src = Source.initReplay(std.testing.allocator, &zeros, 1000);
        defer src.deinit();
        var ctx_state: GenState = undefined;
        var ctx = randomCtx(&ctx_state, &src);
        try std.testing.expectEqual(@as(T, 0), try zigprop.generate(T, &ctx));
    }
    var src = Source.initReplay(std.testing.allocator, &zeros, 1000);
    defer src.deinit();
    var ctx_state: GenState = undefined;
    var ctx = randomCtx(&ctx_state, &src);
    try std.testing.expectEqual(false, try zigprop.generate(bool, &ctx));
    try std.testing.expectEqual(null, try zigprop.generate(?u32, &ctx));
    const s = try zigprop.generate([]const u8, &ctx);
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

test "no-draw generation: u0, empty struct, empty array" {
    var src = Source.initRandom(std.testing.allocator, zigprop.internal.deriveSeed(5, 0), 100);
    defer src.deinit();
    var ctx_state: GenState = undefined;
    var ctx = randomCtx(&ctx_state, &src);
    try std.testing.expectEqual(@as(u0, 0), try zigprop.generate(u0, &ctx));
    _ = try zigprop.generate(struct {}, &ctx);
    _ = try zigprop.generate([0]u8, &ctx);
    try std.testing.expectEqual(@as(usize, 0), src.recorded.items.len);
}

test "i8 generation reaches the boundary values" {
    var seen: std.bit_set.IntegerBitSet(256) = .empty;
    for (0..300) |attempt| {
        var src = Source.initRandom(std.testing.allocator, zigprop.internal.deriveSeed(11, @intCast(attempt)), 1000);
        defer src.deinit();
        var ctx_state: GenState = undefined;
        var ctx = randomCtx(&ctx_state, &src);
        const v = try zigprop.generate(i8, &ctx);
        seen.set(@intCast(@as(i16, v) + 128));
    }
    for ([_]i8{ -128, 127, 0, -1, 1, -127, 126 }) |want| {
        try std.testing.expect(seen.isSet(@intCast(@as(i16, want) + 128)));
    }
}

test "enum with explicit values generates only named fields, all reachable" {
    const E = enum(u16) { a = 3, b = 7, c = 42 };
    var seen_a = false;
    var seen_b = false;
    var seen_c = false;
    for (0..200) |attempt| {
        var src = Source.initRandom(std.testing.allocator, zigprop.internal.deriveSeed(3, @intCast(attempt)), 100);
        defer src.deinit();
        var ctx_state: GenState = undefined;
        var ctx = randomCtx(&ctx_state, &src);
        switch (try zigprop.generate(E, &ctx)) {
            .a => seen_a = true,
            .b => seen_b = true,
            .c => seen_c = true,
        }
    }
    try std.testing.expect(seen_a and seen_b and seen_c);
}

test "struct with a comptime field keeps the comptime value" {
    const S = struct { comptime tag: u32 = 99, x: u32 };
    var src = Source.initRandom(std.testing.allocator, zigprop.internal.deriveSeed(3, 0), 100);
    defer src.deinit();
    var ctx_state: GenState = undefined;
    var ctx = randomCtx(&ctx_state, &src);
    const v = try zigprop.generate(S, &ctx);
    try std.testing.expectEqual(@as(u32, 99), v.tag);
}

test "composite generation is deterministic and replays faithfully" {
    const S = struct { a: u32, b: ?i16, c: []const u8 };
    var src = Source.initRandom(std.testing.allocator, zigprop.internal.deriveSeed(77, 2), 100_000);
    defer src.deinit();
    var ctx_state: GenState = undefined;
    var ctx = randomCtx(&ctx_state, &src);
    const v1 = try zigprop.generate(S, &ctx);
    defer std.testing.allocator.free(v1.c);

    var rep = Source.initReplay(std.testing.allocator, src.recorded.items, 100_000);
    defer rep.deinit();
    var rctx_state: GenState = undefined;
    var rctx = randomCtx(&rctx_state, &rep);
    const v2 = try zigprop.generate(S, &rctx);
    defer std.testing.allocator.free(v2.c);
    try std.testing.expectEqual(v1.a, v2.a);
    try std.testing.expectEqual(v1.b, v2.b);
    try std.testing.expectEqualSlices(u8, v1.c, v2.c);
    try std.testing.expectEqualSlices(Choice, src.recorded.items, rep.recorded.items);
}

test "slice lengths respect max_len" {
    for (0..200) |attempt| {
        var src = Source.initRandom(std.testing.allocator, zigprop.internal.deriveSeed(8, @intCast(attempt)), 100_000);
        defer src.deinit();
        var ctx_state: GenState = undefined;
        var ctx = randomCtx(&ctx_state, &src);
        const s = try zigprop.generate([]const u32, &ctx);
        defer std.testing.allocator.free(s);
        try std.testing.expect(s.len <= 32);
    }
}

test "element budget turns nested expansion into InvalidGeneration" {
    // Force every length draw to 32: outer slice of 32 slices, each
    // counted, blows a budget of 4 immediately.
    var choices: [512]Choice = undefined;
    for (&choices) |*c| c.* = .{ .bound = 0, .value = 32 };
    var src = Source.initReplay(std.testing.allocator, &choices, 100_000);
    defer src.deinit();
    var ctx_state: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, std.testing.allocator, .{ .max_total_elements = 4 });
    try std.testing.expectError(error.InvalidGeneration, zigprop.generate([]const []const u8, &ctx));
}

// ---------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------

fn alwaysTrue(_: u32) bool {
    return true;
}
fn alwaysFalse(_: u32) bool {
    return false;
}
fn smallOnly(x: u32) bool {
    return x < 10;
}

test "runner: always-true property passes with the requested case count" {
    var report = try zigprop.check(std.testing.allocator, u32, alwaysTrue, .{ .max_cases = 25 });
    defer report.deinit();
    switch (report) {
        .passed => |p| {
            try std.testing.expectEqual(@as(usize, 25), p.cases);
            try std.testing.expectEqual(@as(usize, 0), p.discards);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "runner: a failure is confirmed, snapshotted and replayable" {
    var report = try zigprop.check(std.testing.allocator, u32, smallOnly, .{ .seed = 5, .max_cases = 100 });
    defer report.deinit();
    switch (report) {
        .failed => |f| {
            try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, f.shrink_outcome);
            try std.testing.expect(f.choices.len > 0);
            // The snapshot survives the attempt arena (report outlives
            // check) and the recorded sequence regenerates a failing
            // value.
            var rep = Source.initReplay(std.testing.allocator, f.choices, 100_000);
            defer rep.deinit();
            var ctx_state: GenState = undefined;
            var ctx = randomCtx(&ctx_state, &rep);
            const v = try zigprop.generate(u32, &ctx);
            try std.testing.expect(!smallOnly(v));
            try std.testing.expectEqualSlices(Choice, f.choices, rep.recorded.items);
            // The shrunk sequence also regenerates a failing value.
            var rep2 = Source.initReplay(std.testing.allocator, f.shrunk_choices, 100_000);
            defer rep2.deinit();
            var ctx2_state: GenState = undefined;
            var ctx2 = randomCtx(&ctx2_state, &rep2);
            const v2 = try zigprop.generate(u32, &ctx2);
            try std.testing.expect(!smallOnly(v2));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "runner: same seed reproduces the same failure" {
    var r1 = try zigprop.check(std.testing.allocator, u32, smallOnly, .{ .seed = 9, .max_cases = 100 });
    defer r1.deinit();
    var r2 = try zigprop.check(std.testing.allocator, u32, smallOnly, .{ .seed = 9, .max_cases = 100 });
    defer r2.deinit();
    try std.testing.expectEqual(r1.failed.origin.random.attempt_index, r2.failed.origin.random.attempt_index);
    try std.testing.expectEqualSlices(Choice, r1.failed.choices, r2.failed.choices);
    try std.testing.expectEqualStrings(r1.failed.original_value, r2.failed.original_value);
}

fn alwaysDiscard(_: *GenContext) anyerror!u32 {
    return error.InvalidGeneration;
}

test "runner: a generator that always discards gives up" {
    var report = try zigprop.checkCustom(std.testing.allocator, u32, alwaysDiscard, alwaysTrue, .{ .max_discards = 10 });
    defer report.deinit();
    switch (report) {
        .gave_up => |g| try std.testing.expectEqual(@as(usize, 11), g.discards),
        else => return error.TestUnexpectedResult,
    }
}

fn singleDraw(ctx: *GenContext) anyerror!u32 {
    // The dedicated single-choice encoding of design §8.
    return @intCast(ctx.range(1 << 32));
}

test "runner: checkCustom with the single-draw encoding finds x >= 10" {
    var report = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{ .seed = 1, .max_cases = 100 });
    defer report.deinit();
    switch (report) {
        .failed => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.choices.len);
            try std.testing.expect(f.choices[0].value >= 10);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "runner: checkOrError maps outcomes to errors" {
    try zigprop.checkOrError(std.testing.allocator, u32, alwaysTrue, .{ .max_cases = 5 });
    try std.testing.expectError(error.PropertyFailed, zigprop.checkOrError(std.testing.allocator, u32, alwaysFalse, .{}));
}

test "runner: invalid config is rejected" {
    try std.testing.expectError(error.InvalidConfig, zigprop.check(std.testing.allocator, u32, alwaysTrue, .{ .limits = .{ .max_draws = 0 } }));
    try std.testing.expectError(error.InvalidConfig, zigprop.check(std.testing.allocator, u32, alwaysTrue, .{ .limits = .{ .max_total_elements = 0 } }));
}

test "runner: max_cases = 0 is rejected rather than passing vacuously" {
    try std.testing.expectError(error.InvalidConfig, zigprop.check(std.testing.allocator, u32, alwaysTrue, .{ .max_cases = 0 }));
    try std.testing.expectError(error.InvalidConfig, zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .max_cases = 0 }));
}

// ---------------------------------------------------------------------
// Regressions (design §7)
// ---------------------------------------------------------------------

test "regressions: a failing entry fails the run before random cases" {
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{25} }};
    var report = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{
        .regressions = &entries,
        .regression_id = "t",
    });
    defer report.deinit();
    switch (report) {
        .failed => |f| {
            try std.testing.expectEqual(@as(usize, 0), f.origin.regression.index);
            try std.testing.expectEqual(@as(u64, 25), f.choices[0].value);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "regressions: passing entries are counted, stale versions skipped" {
    const entries = [_]zigprop.Regression{
        .{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{5} },
        .{ .id = "t", .gen_version = 999, .choices = &.{25} },
        .{ .id = "other", .gen_version = zigprop.generator_version, .choices = &.{25} },
    };
    var report = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, .{
        .regressions = &entries,
        .regression_id = "t",
        .max_cases = 10,
        .seed = 12345,
    });
    defer report.deinit();
    switch (report) {
        .passed => |p| {
            try std.testing.expectEqual(@as(usize, 1), p.regressions.passed);
            try std.testing.expectEqual(@as(usize, 1), p.regressions.stale.len);
            try std.testing.expectEqual(zigprop.StaleReason.gen_version_mismatch, p.regressions.stale[0].reason);
            try std.testing.expectEqual(@as(usize, 1), p.regressions.stale[0].index);
        },
        else => return error.TestUnexpectedResult,
    }
}
