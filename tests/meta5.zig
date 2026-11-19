//! v0.2 milestone 1: golden replay pins (design v0.2 §0, SF5) and
//! float generation (design v0.2 §1).
//!
//! The golden tests pin the exact consumed choice sequence, key
//! sequence and skip flags for representative pre-v0.2 types. They
//! were recorded from the v0.1.0 implementation; any refactor that
//! changes existing generation paths must fail here loudly rather
//! than silently invalidating recorded regressions.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const GenContext = zigprop.GenContext;

fn expectRecorded(src: *zigprop.Source, choices: []const Choice, keys: []const u64, skips: []const bool) !void {
    try std.testing.expectEqualSlices(Choice, choices, src.recorded.items);
    try std.testing.expectEqualSlices(u64, keys, src.recorded_keys.items);
    try std.testing.expectEqualSlices(bool, skips, src.recorded_skip.items);
}

test "golden: struct { u32, i16, bool } at seed 42" {
    const S = struct { a: u32, b: i16, c: bool };
    var src = zigprop.Source.initRandom(std.testing.allocator, zigprop.deriveSeed(42, 0), 100_000);
    defer src.deinit();
    var ctx = GenContext{ .src = &src, .allocator = std.testing.allocator, .limits = .{} };
    const v = try zigprop.generate(S, &ctx);
    try std.testing.expectEqual(@as(u32, 22188), v.a);
    try std.testing.expectEqual(@as(i16, -1), v.b);
    try std.testing.expectEqual(true, v.c);
    try expectRecorded(&src, &.{
        .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 22188 },
        .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 1 },
        .{ .bound = 2, .value = 1 },
    }, &.{ 22188, 22188, 1, 1, 1 }, &.{ false, true, false, true, false });
}

test "golden: []const u8 at seed 2 with max_len 4" {
    var src = zigprop.Source.initRandom(std.testing.allocator, zigprop.deriveSeed(2, 0), 100_000);
    defer src.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = GenContext{ .src = &src, .allocator = arena.allocator(), .limits = .{ .max_len = 4 } };
    const v = try zigprop.generate([]const u8, &ctx);
    try std.testing.expectEqualSlices(u8, &.{ 86, 156, 1 }, v);
    try expectRecorded(&src, &.{
        .{ .bound = 5, .value = 3 },
        .{ .bound = 4, .value = 0 },
        .{ .bound = 256, .value = 86 },
        .{ .bound = 4, .value = 0 },
        .{ .bound = 256, .value = 156 },
        .{ .bound = 4, .value = 1 },
        .{ .bound = 4, .value = 1 },
    }, &.{ 3, 86, 86, 156, 156, 1, 1 }, &.{ false, false, true, false, true, false, true });
}

// ---------------------------------------------------------------------
// Floats (design v0.2 §1)
// ---------------------------------------------------------------------

fn genFromValues(comptime T: type, values: []const u64, src_out: *zigprop.Source) !T {
    var buf: [4]Choice = undefined;
    for (values, 0..) |v, i| buf[i] = .{ .bound = 0, .value = v };
    src_out.* = zigprop.Source.initReplay(std.testing.allocator, buf[0..values.len], 100_000);
    var ctx = GenContext{ .src = src_out, .allocator = std.testing.allocator, .limits = .{} };
    return zigprop.generate(T, &ctx);
}

fn genFromChoices(comptime T: type, choices: []const Choice, src_out: *zigprop.Source) !T {
    src_out.* = zigprop.Source.initReplay(std.testing.allocator, choices, 100_000);
    var ctx = GenContext{ .src = src_out, .allocator = std.testing.allocator, .limits = .{} };
    return zigprop.generate(T, &ctx);
}

/// Test-side rank of a float value, from bit math only: rank =
/// 2 * magnitude_bits + sign (produced values are never NaN, so no
/// canonicalization is needed on this side).
fn rankOf(comptime T: type, value: T) u64 {
    const bits: u64 = switch (T) {
        f16 => @as(u16, @bitCast(value)),
        f32 => @as(u32, @bitCast(value)),
        f64 => @bitCast(value),
        else => unreachable,
    };
    const sign_bit: u6 = switch (T) {
        f16 => 15,
        f32 => 31,
        f64 => 63,
        else => unreachable,
    };
    const sign = bits >> sign_bit;
    const mag = bits & ((@as(u64, 1) << sign_bit) - 1);
    return 2 * mag + sign;
}

test "floats: f16 class-3 is exhaustive — every rank yields its canonical value" {
    // NTH1: all 65536 ranks. Every non-NaN pattern is produced
    // exactly once; the 1023 NaN payloads of each sign collapse
    // onto that sign's infinity (1024 productions each, counting
    // the genuine infinity rank); NaN is never produced.
    var counts: [65536]u32 = @splat(0);
    for (0..65536) |rank| {
        var src: zigprop.Source = undefined;
        const v = try genFromValues(f16, &.{ 3, @intCast(rank) }, &src);
        defer src.deinit();
        try std.testing.expect(!std.math.isNan(v));
        const bits: usize = @as(u16, @bitCast(v));
        counts[bits] += 1;
        // MF3: the recorded key is the produced value's rank.
        try std.testing.expectEqual(rankOf(f16, v), src.recorded_keys.items[0]);
    }
    try std.testing.expectEqual(@as(u32, 1024), counts[0x7C00]); // +inf
    try std.testing.expectEqual(@as(u32, 1024), counts[0xFC00]); // -inf
    for (counts, 0..) |c, pattern| {
        const exp: u32 = @intCast(pattern & 0x7C00);
        const mant: u32 = @intCast(pattern & 0x03FF);
        if (exp == 0x7C00 and mant != 0) {
            try std.testing.expectEqual(@as(u32, 0), c); // NaN patterns: never produced
        } else if (pattern != 0x7C00 and pattern != 0xFC00) {
            try std.testing.expectEqual(@as(u32, 1), c);
        }
    }
}

test "floats: f32/f64 landmark ranks produce the landmark values" {
    inline for (.{ f32, f64 }) |T| {
        var src: zigprop.Source = undefined;
        // rank 0 -> +0.0, rank 1 -> -0.0, rank 2 -> least subnormal
        const zp = try genFromValues(T, &.{ 3, 0 }, &src);
        src.deinit();
        try std.testing.expectEqual(@as(T, 0.0), zp);
        try std.testing.expect(!std.math.signbit(zp));
        const zn = try genFromValues(T, &.{ 3, 1 }, &src);
        src.deinit();
        try std.testing.expectEqual(@as(T, 0.0), zn);
        try std.testing.expect(std.math.signbit(zn));
        const sub = try genFromValues(T, &.{ 3, 2 }, &src);
        src.deinit();
        try std.testing.expect(sub > 0);
        try std.testing.expectEqual(@as(T, 0.0), sub / 2); // least subnormal halves to zero
        // rank of 1.0 -> exactly 1.0; rank of +inf -> +inf
        const one = try genFromValues(T, &.{ 3, rankOf(T, 1.0) }, &src);
        src.deinit();
        try std.testing.expectEqual(@as(T, 1.0), one);
        const inf = try genFromValues(T, &.{ 3, rankOf(T, std.math.inf(T)) }, &src);
        src.deinit();
        try std.testing.expect(std.math.isInf(inf) and inf > 0);
        // a NaN rank (exponent all ones, mantissa nonzero) -> +inf,
        // keyed by the infinity rank, not the drawn rank (MF3)
        const nan_rank = rankOf(T, std.math.inf(T)) + 2 * 0x12345;
        const remapped = try genFromValues(T, &.{ 3, nan_rank }, &src);
        try std.testing.expect(std.math.isInf(remapped) and remapped > 0);
        try std.testing.expectEqual(rankOf(T, std.math.inf(T)), src.recorded_keys.items[0]);
        src.deinit();
    }
}

test "floats: all-zero draws produce +0.0" {
    var src: zigprop.Source = undefined;
    const v = try genFromValues(f64, &.{ 0, 0 }, &src);
    defer src.deinit();
    try std.testing.expectEqual(@as(f64, 0.0), v);
    try std.testing.expect(!std.math.signbit(v));
    try std.testing.expectEqual(@as(u64, 0), src.recorded_keys.items[0]);
}

test "floats: the boundary class contains the landmarks" {
    var seen: [14]f64 = @splat(0);
    for (0..14) |idx| {
        var src: zigprop.Source = undefined;
        seen[idx] = try genFromValues(f64, &.{ 1, @intCast(idx) }, &src);
        src.deinit();
    }
    var has_pos_inf = false;
    var has_neg_inf = false;
    var has_neg_zero = false;
    var has_one = false;
    var has_half = false;
    var has_max = false;
    var has_min_sub = false;
    for (seen) |v| {
        if (std.math.isInf(v) and v > 0) has_pos_inf = true;
        if (std.math.isInf(v) and v < 0) has_neg_inf = true;
        if (v == 0 and std.math.signbit(v)) has_neg_zero = true;
        if (v == 1.0) has_one = true;
        if (v == 0.5) has_half = true;
        if (v == std.math.floatMax(f64)) has_max = true;
        if (@as(u64, @bitCast(v)) == 1) has_min_sub = true;
    }
    try std.testing.expect(has_pos_inf and has_neg_inf and has_neg_zero);
    try std.testing.expect(has_one and has_half and has_max and has_min_sub);
}

test "floats: the grid class hits exact dyadic values" {
    var src: zigprop.Source = undefined;
    const a = try genFromValues(f32, &.{ 2, 1 }, &src);
    src.deinit();
    try std.testing.expectEqual(@as(f32, 0.125), a);
    const b = try genFromValues(f32, &.{ 2, 2 }, &src);
    src.deinit();
    try std.testing.expectEqual(@as(f32, -0.125), b);
    const c = try genFromValues(f32, &.{ 2, 2048 }, &src);
    src.deinit();
    try std.testing.expectEqual(@as(f32, -128.0), c);
}

fn lessThanOne(x: f32) bool {
    return x < 1.0;
}

test "floats: a class-0 regression shrinks to exactly 1.0" {
    // Choice 32 in the small-integer class is +16 (the list is
    // rank-sorted: +0, -0, +1, -1, ..., +16, -16). The shrinker
    // must reach the exact threshold value 1.0.
    const entries = [_]zigprop.Regression{.{ .id = "f", .gen_version = zigprop.generator_version, .choices = &.{ 0, 32 } }};
    var report = try zigprop.check(std.testing.allocator, f32, lessThanOne, .{
        .seed = 0,
        .regressions = &entries,
        .regression_id = "f",
    });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .failed);
    var src: zigprop.Source = undefined;
    const v = try genFromChoices(f32, report.failed.shrunk_choices, &src);
    src.deinit();
    try std.testing.expectEqual(@as(f32, 1.0), v);
}

fn selfSubtractIsZero(x: f64) bool {
    return (x - x) == 0;
}

test "floats: check discovers infinity for x - x == 0 and shrinks to it" {
    // Only +-inf fails (NaN is never generated). The boundary
    // class carries both infinities.
    var report = try zigprop.check(std.testing.allocator, f64, selfSubtractIsZero, .{ .seed = 0 });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .failed);
    var src: zigprop.Source = undefined;
    const v = try genFromChoices(f64, report.failed.shrunk_choices, &src);
    src.deinit();
    try std.testing.expect(std.math.isInf(v));
}

test "floats: NaN is never generated under random draws" {
    const prop = struct {
        fn p(x: f32) bool {
            return !std.math.isNan(x);
        }
    }.p;
    for (0..5) |seed| {
        var report = try zigprop.check(std.testing.allocator, f32, prop, .{ .seed = @intCast(seed) });
        defer report.deinit();
        try std.testing.expect(std.meta.activeTag(report) == .passed);
    }
}

test "floats: nested in structs and slices" {
    const S = struct { x: f32, ys: []const f16 };
    var src = zigprop.Source.initRandom(std.testing.allocator, zigprop.deriveSeed(3, 0), 100_000);
    defer src.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = GenContext{ .src = &src, .allocator = arena.allocator(), .limits = .{} };
    const v = try zigprop.generate(S, &ctx);
    try std.testing.expect(!std.math.isNan(v.x));
    for (v.ys) |y| try std.testing.expect(!std.math.isNan(y));
}
