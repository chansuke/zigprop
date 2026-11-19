//! v0.3 M1: golden pins for every generated shape (design v0.3 §7.4,
//! D35), recorded from v0.2.1 (generator_version 1) before any
//! generation-changing milestone.
//!
//! (R) replay pins: a given value sequence -> the generated value, the
//! re-recorded choices (bounds included), keys, skips and the number
//! of values consumed. They are the evidence for replay compatibility.
//! Every input sequence is normalized (each value is below the bound
//! its position draws with), which is the storage contract of design
//! v2 §7.
//!
//! (S) random pins: a seed (attempt 0) -> the recorded sequence and
//! the value. They are the evidence for seed compatibility, which is
//! not promised across versions: a milestone that changes random
//! generation re-records them after reviewing the diff.
//!
//! Display strings are deliberately NOT pinned: they come from std's
//! `{any}` / `{f}` and are not a compatibility surface (§7.4, F1).
//!
//! The recursive-cut group is in tests/meta10_rec.zig, because M7
//! (cut scope, generator_version 2) rewrites it on purpose.
//!
//! All expected values are literals captured from a v0.2.1 run.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const Limits = zigprop.Limits;

fn ReplayPin(comptime V: type) type {
    return struct {
        values: []const u64,
        limits: Limits = .{},
        value: V,
        choices: []const Choice,
        keys: []const u64,
        skips: []const bool,
        consumed: usize,
    };
}

fn RandomPin(comptime V: type) type {
    return struct {
        seed: u64,
        limits: Limits = .{},
        value: V,
        choices: []const Choice,
        keys: []const u64,
        skips: []const bool,
    };
}

fn Generated(comptime T: type) type {
    return struct {
        value: T,
        choices: []const Choice,
        keys: []const u64,
        skips: []const bool,
        consumed: usize,
    };
}

/// The only place that touches the Source: replays `values` (each as
/// an unbounded choice, the way a regression entry is replayed) or
/// draws attempt 0 of `seed`, and returns the value with copies of
/// the recording, all owned by `arena`.
fn generateWith(comptime T: type, arena: std.mem.Allocator, mode: union(enum) { replay: []const u64, seed: u64 }, limits: Limits) !Generated(T) {
    var src = switch (mode) {
        .replay => |values| blk: {
            const buf = try arena.alloc(Choice, values.len);
            for (values, buf) |v, *c| c.* = .{ .bound = 0, .value = v };
            break :blk zigprop.internal.Source.initReplay(arena, buf, 100_000);
        },
        .seed => |seed| zigprop.internal.Source.initRandom(arena, zigprop.internal.deriveSeed(seed, 0), 100_000),
    };
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena, limits);
    const v = try zigprop.generate(T, &ctx);
    try std.testing.expect(!src.exhausted);
    return .{
        .value = v,
        .choices = try arena.dupe(Choice, src.recorded.items),
        .keys = try arena.dupe(u64, src.recorded_keys.items),
        .skips = try arena.dupe(bool, src.recorded_skip.items),
        .consumed = src.pos,
    };
}

fn expectSameValue(comptime V: type, expected: V, actual: V) !void {
    if (@typeInfo(V) == .float) {
        // Bit-exact, so +0.0 and -0.0 are told apart.
        const U = @Int(.unsigned, @typeInfo(V).float.bits);
        return std.testing.expectEqual(@as(U, @bitCast(expected)), @as(U, @bitCast(actual)));
    }
    return std.testing.expectEqualDeep(expected, actual);
}

fn checkReplay(comptime T: type, comptime V: type, pins: []const ReplayPin(V)) !void {
    for (pins, 0..) |p, i| {
        errdefer std.debug.print("replay pin #{d} of {s} differs (values {any})\n", .{ i, @typeName(T), p.values });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const g = try generateWith(T, arena.allocator(), .{ .replay = p.values }, p.limits);
        try expectSameValue(V, p.value, g.value);
        try std.testing.expectEqualSlices(Choice, p.choices, g.choices);
        try std.testing.expectEqualSlices(u64, p.keys, g.keys);
        try std.testing.expectEqualSlices(bool, p.skips, g.skips);
        try std.testing.expectEqual(p.consumed, g.consumed);
    }
}

fn checkRandom(comptime T: type, comptime V: type, pins: []const RandomPin(V)) !void {
    for (pins, 0..) |p, i| {
        errdefer std.debug.print("random pin #{d} of {s} differs (seed {d})\n", .{ i, @typeName(T), p.seed });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const g = try generateWith(T, arena.allocator(), .{ .seed = p.seed }, p.limits);
        try expectSameValue(V, p.value, g.value);
        try std.testing.expectEqualSlices(Choice, p.choices, g.choices);
        try std.testing.expectEqualSlices(u64, p.keys, g.keys);
        try std.testing.expectEqualSlices(bool, p.skips, g.skips);
    }
}

const EnumExplicit = enum(u16) { a = 3, b = 7, c = 42 };
const EnumNonExhaustive = enum(u8) { x = 1, y = 200, _ };
const S3 = struct { a: u32, b: i16, c: bool };
const U3 = union(enum) { a: u8, b: void, c: i32 };

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "golden (R): unsigned integers u0..u64, every class" {
    // Per width: class 0, class 1 (last and second-to-last boundary),
    // class 2, class 3. u8 class 0 has bound = R (W = 8); u16 class 2
    // has bound = R (W = 16) while u17 class 2 has bound 65536 < R
    // (W = 17).
    try checkReplay(u0, u0, &replay_u0);
    try checkReplay(u1, u1, &replay_u1);
    try checkReplay(u8, u8, &replay_u8);
    try checkReplay(u16, u16, &replay_u16);
    try checkReplay(u17, u17, &replay_u17);
    try checkReplay(u32, u32, &replay_u32);
    try checkReplay(u64, u64, &replay_u64);
    // Normalization of raw values in classes whose bound v0.3 keeps.
    try checkReplay(u8, u8, &replay_u8_normalized);
}

test "golden (R): signed integers i1..i64, every class, odd and even ranks" {
    // Per width: class 0 with an even and an odd rank, class 1 (the
    // last boundary, i.e. the minimum, and index 1), class 2 with an
    // odd rank, class 3 with an even and an odd rank.
    try checkReplay(i1, i1, &replay_i1);
    try checkReplay(i8, i8, &replay_i8);
    try checkReplay(i16, i16, &replay_i16);
    try checkReplay(i17, i17, &replay_i17);
    try checkReplay(i32, i32, &replay_i32);
    try checkReplay(i64, i64, &replay_i64);
}

test "golden (R): floats f16/f32/f64, every class, NaN mapping and signed zeros" {
    // Per type: class 0 (+16, -16, +0), class 1 (+0, -0, -inf),
    // class 2 (0.125, -128), class 3 (+0, -0, least subnormal, -max
    // finite) and five NaN patterns (positive with payload 1, the
    // largest payload and the quiet bit; negative with payload 1 and
    // a quiet payload): each maps to the infinity of its sign, keyed
    // by the infinity's rank, never NaN.
    try checkReplay(f16, f16, &replay_f16);
    try checkReplay(f32, f32, &replay_f32);
    try checkReplay(f64, f64, &replay_f64);
}

test "golden (R): enums, optionals and arrays" {
    try checkReplay(EnumExplicit, EnumExplicit, &replay_enum_explicit);
    try checkReplay(EnumNonExhaustive, EnumNonExhaustive, &replay_enum_nonexhaustive);
    try checkReplay(?u8, ?u8, &replay_opt_u8);
    try checkReplay(??u8, ??u8, &replay_opt_opt_u8);
    try checkReplay([3]u8, [3]u8, &replay_array3);
    try checkReplay([0]u8, [0]u8, &replay_array0);
    try checkReplay([2][]const u8, [2][]const u8, &replay_array_of_slices);
}

test "golden (R): nested slices" {
    try checkReplay([][]const u8, []const []const u8, &replay_slice_of_slices);
    try checkReplay([]const ?i16, []const ?i16, &replay_slice_of_opt_i16);
}

test "golden (R): struct and union (void and non-void variants)" {
    try checkReplay(S3, S3, &replay_struct);
    try checkReplay(U3, U3, &replay_union);
}

test "golden (S): integers, one table per width" {
    try checkRandom(u1, u1, &random_u1);
    try checkRandom(u8, u8, &random_u8);
    try checkRandom(u16, u16, &random_u16);
    try checkRandom(u17, u17, &random_u17);
    try checkRandom(u32, u32, &random_u32);
    try checkRandom(u64, u64, &random_u64);
    try checkRandom(i1, i1, &random_i1);
    try checkRandom(i8, i8, &random_i8);
    try checkRandom(i16, i16, &random_i16);
    try checkRandom(i17, i17, &random_i17);
    try checkRandom(i32, i32, &random_i32);
    try checkRandom(i64, i64, &random_i64);
}

test "golden (S): floats" {
    try checkRandom(f16, f16, &random_f16);
    try checkRandom(f32, f32, &random_f32);
    try checkRandom(f64, f64, &random_f64);
}

test "golden (S): nested slices, struct and union" {
    // The pre-existing struct and []const u8 seed pins stay in
    // tests/meta5.zig.
    try checkRandom([][]const u8, []const []const u8, &random_slice_of_slices);
    try checkRandom([]const ?i16, []const ?i16, &random_slice_of_opt_i16);
    try checkRandom(S3, S3, &random_struct);
    try checkRandom(U3, U3, &random_union);
}

// ---------------------------------------------------------------------
// Pin tables (literals recorded from v0.2.1)
// ---------------------------------------------------------------------

const replay_u0 = [_]ReplayPin(u0){
    .{ .values = &.{}, .value = 0, .choices = &.{}, .keys = &.{}, .skips = &.{}, .consumed = 0 },
};

const replay_u1 = [_]ReplayPin(u1){
    .{ .values = &.{ 0, 1 }, .value = 1, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = 1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 0 }, .value = 0, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 2, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 1 }, .value = 1, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 1 }, .value = 1, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_u8 = [_]ReplayPin(u8){
    .{ .values = &.{ 0, 200 }, .value = 200, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 200 } }, .keys = &.{ 200, 200 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 3 }, .value = 255, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 3 } }, .keys = &.{ 255, 3 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 2 }, .value = 254, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 254, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 201 }, .value = 201, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 201 } }, .keys = &.{ 201, 201 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 255 }, .value = 255, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 255 } }, .keys = &.{ 255, 255 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_u16 = [_]ReplayPin(u16){
    .{ .values = &.{ 0, 255 }, .value = 255, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 255 } }, .keys = &.{ 255, 255 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 3 }, .value = 65535, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 3 } }, .keys = &.{ 65535, 3 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 2 }, .value = 65534, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 65534, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 65535 }, .value = 65535, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 65535 } }, .keys = &.{ 65535, 65535 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 40000 }, .value = 40000, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 40000 } }, .keys = &.{ 40000, 40000 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_u17 = [_]ReplayPin(u17){
    .{ .values = &.{ 0, 129 }, .value = 129, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 129 } }, .keys = &.{ 129, 129 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 3 }, .value = 131071, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 3 } }, .keys = &.{ 131071, 3 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 2 }, .value = 131070, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 131070, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 65535 }, .value = 65535, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 65535 } }, .keys = &.{ 65535, 65535 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 131071 }, .value = 131071, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 131072, .value = 131071 } }, .keys = &.{ 131071, 131071 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_u32 = [_]ReplayPin(u32){
    .{ .values = &.{ 0, 77 }, .value = 77, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 77 } }, .keys = &.{ 77, 77 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 3 }, .value = 4294967295, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 3 } }, .keys = &.{ 4294967295, 3 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 2 }, .value = 4294967294, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 4294967294, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 40000 }, .value = 40000, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 40000 } }, .keys = &.{ 40000, 40000 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4294967295 }, .value = 4294967295, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4294967295 } }, .keys = &.{ 4294967295, 4294967295 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_u64 = [_]ReplayPin(u64){
    .{ .values = &.{ 0, 250 }, .value = 250, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 250 } }, .keys = &.{ 250, 250 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 3 }, .value = 18446744073709551615, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 3 } }, .keys = &.{ 18446744073709551615, 3 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 2 }, .value = 18446744073709551614, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 18446744073709551614, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 12345 }, .value = 12345, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 12345 } }, .keys = &.{ 12345, 12345 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18446744073709551615 }, .value = 18446744073709551615, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18446744073709551615 } }, .keys = &.{ 18446744073709551615, 18446744073709551615 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_i1 = [_]ReplayPin(i1){
    .{ .values = &.{ 0, 0 }, .value = 0, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 2, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 0 }, .value = 0, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 2, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_i8 = [_]ReplayPin(i8){
    .{ .values = &.{ 0, 254 }, .value = 127, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 254 } }, .keys = &.{ 254, 254 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 255 }, .value = -128, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 255 } }, .keys = &.{ 255, 255 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 6 }, .value = -128, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 6 } }, .keys = &.{ 255, 6 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 255 }, .value = -128, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 255 } }, .keys = &.{ 255, 255 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 254 }, .value = 127, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 254 } }, .keys = &.{ 254, 254 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_i16 = [_]ReplayPin(i16){
    .{ .values = &.{ 0, 254 }, .value = 127, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 254 } }, .keys = &.{ 254, 254 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 201 }, .value = -101, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 201 } }, .keys = &.{ 201, 201 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 6 }, .value = -32768, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 6 } }, .keys = &.{ 65535, 6 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 65535 }, .value = -32768, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 65535 } }, .keys = &.{ 65535, 65535 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 40000 }, .value = 20000, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 40000 } }, .keys = &.{ 40000, 40000 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 40001 }, .value = -20001, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 40001 } }, .keys = &.{ 40001, 40001 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_i17 = [_]ReplayPin(i17){
    .{ .values = &.{ 0, 200 }, .value = 100, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 200 } }, .keys = &.{ 200, 200 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 129 }, .value = -65, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 129 } }, .keys = &.{ 129, 129 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 6 }, .value = -65536, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 6 } }, .keys = &.{ 131071, 6 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 65535 }, .value = -32768, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 65535 } }, .keys = &.{ 65535, 65535 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 131070 }, .value = 65535, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 131072, .value = 131070 } }, .keys = &.{ 131070, 131070 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 131071 }, .value = -65536, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 131072, .value = 131071 } }, .keys = &.{ 131071, 131071 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_i32 = [_]ReplayPin(i32){
    .{ .values = &.{ 0, 100 }, .value = 50, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 100 } }, .keys = &.{ 100, 100 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 77 }, .value = -39, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 77 } }, .keys = &.{ 77, 77 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 6 }, .value = -2147483648, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 6 } }, .keys = &.{ 4294967295, 6 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 40001 }, .value = -20001, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 40001 } }, .keys = &.{ 40001, 40001 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4294967294 }, .value = 2147483647, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4294967294 } }, .keys = &.{ 4294967294, 4294967294 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4294967295 }, .value = -2147483648, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4294967295 } }, .keys = &.{ 4294967295, 4294967295 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_i64 = [_]ReplayPin(i64){
    .{ .values = &.{ 0, 2 }, .value = 1, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 2 } }, .keys = &.{ 2, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 3 }, .value = -2, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 3 } }, .keys = &.{ 3, 3 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 6 }, .value = -9223372036854775808, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 6 } }, .keys = &.{ 18446744073709551615, 6 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = -1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 12345 }, .value = -6173, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 12345 } }, .keys = &.{ 12345, 12345 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18446744073709551614 }, .value = 9223372036854775807, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18446744073709551614 } }, .keys = &.{ 18446744073709551614, 18446744073709551614 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18446744073709551615 }, .value = -9223372036854775808, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18446744073709551615 } }, .keys = &.{ 18446744073709551615, 18446744073709551615 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_u8_normalized = [_]ReplayPin(u8){
    .{ .values = &.{ 0, 300 }, .value = 44, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 44 } }, .keys = &.{ 44, 44 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 1000 }, .value = 232, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 232 } }, .keys = &.{ 232, 232 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_f16 = [_]ReplayPin(f16){
    .{ .values = &.{ 0, 31 }, .value = @bitCast(@as(u16, 0x4c00)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 31 } }, .keys = &.{ 38912, 31 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 32 }, .value = @bitCast(@as(u16, 0xcc00)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 32 } }, .keys = &.{ 38913, 32 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 0 }, .value = @bitCast(@as(u16, 0x0)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 0 }, .value = @bitCast(@as(u16, 0x0)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = @bitCast(@as(u16, 0x8000)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 13 }, .value = @bitCast(@as(u16, 0xfc00)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 13 } }, .keys = &.{ 63489, 13 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 1 }, .value = @bitCast(@as(u16, 0x3000)), .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2049, .value = 1 } }, .keys = &.{ 24576, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 2048 }, .value = @bitCast(@as(u16, 0xd800)), .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2049, .value = 2048 } }, .keys = &.{ 45057, 2048 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 0 }, .value = @bitCast(@as(u16, 0x0)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 1 }, .value = @bitCast(@as(u16, 0x8000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 2 }, .value = @bitCast(@as(u16, 0x1)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 2 } }, .keys = &.{ 2, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 63487 }, .value = @bitCast(@as(u16, 0xfbff)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 63487 } }, .keys = &.{ 63487, 63487 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 63490 }, .value = @bitCast(@as(u16, 0x7c00)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 63490 } }, .keys = &.{ 63488, 63490 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 65534 }, .value = @bitCast(@as(u16, 0x7c00)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 65534 } }, .keys = &.{ 63488, 65534 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 64512 }, .value = @bitCast(@as(u16, 0x7c00)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 64512 } }, .keys = &.{ 63488, 64512 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 63491 }, .value = @bitCast(@as(u16, 0xfc00)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 63491 } }, .keys = &.{ 63489, 63491 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 64523 }, .value = @bitCast(@as(u16, 0xfc00)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 64523 } }, .keys = &.{ 63489, 64523 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_f32 = [_]ReplayPin(f32){
    .{ .values = &.{ 0, 31 }, .value = @bitCast(@as(u32, 0x41800000)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 31 } }, .keys = &.{ 2197815296, 31 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 32 }, .value = @bitCast(@as(u32, 0xc1800000)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 32 } }, .keys = &.{ 2197815297, 32 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 0 }, .value = @bitCast(@as(u32, 0x0)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 0 }, .value = @bitCast(@as(u32, 0x0)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = @bitCast(@as(u32, 0x80000000)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 13 }, .value = @bitCast(@as(u32, 0xff800000)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 13 } }, .keys = &.{ 4278190081, 13 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 1 }, .value = @bitCast(@as(u32, 0x3e000000)), .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2049, .value = 1 } }, .keys = &.{ 2080374784, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 2048 }, .value = @bitCast(@as(u32, 0xc3000000)), .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2049, .value = 2048 } }, .keys = &.{ 2248146945, 2048 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 0 }, .value = @bitCast(@as(u32, 0x0)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 1 }, .value = @bitCast(@as(u32, 0x80000000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 2 }, .value = @bitCast(@as(u32, 0x1)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 2 } }, .keys = &.{ 2, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4278190079 }, .value = @bitCast(@as(u32, 0xff7fffff)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4278190079 } }, .keys = &.{ 4278190079, 4278190079 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4278190082 }, .value = @bitCast(@as(u32, 0x7f800000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4278190082 } }, .keys = &.{ 4278190080, 4278190082 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4294967294 }, .value = @bitCast(@as(u32, 0x7f800000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4294967294 } }, .keys = &.{ 4278190080, 4294967294 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4286578688 }, .value = @bitCast(@as(u32, 0x7f800000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4286578688 } }, .keys = &.{ 4278190080, 4286578688 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4278190083 }, .value = @bitCast(@as(u32, 0xff800000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4278190083 } }, .keys = &.{ 4278190081, 4278190083 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 4286578699 }, .value = @bitCast(@as(u32, 0xff800000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4286578699 } }, .keys = &.{ 4278190081, 4286578699 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_f64 = [_]ReplayPin(f64){
    .{ .values = &.{ 0, 31 }, .value = @bitCast(@as(u64, 0x4030000000000000)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 31 } }, .keys = &.{ 9250393634618998784, 31 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 32 }, .value = @bitCast(@as(u64, 0xc030000000000000)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 32 } }, .keys = &.{ 9250393634618998785, 32 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 0, 0 }, .value = @bitCast(@as(u64, 0x0)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 0 }, .value = @bitCast(@as(u64, 0x0)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 1 }, .value = @bitCast(@as(u64, 0x8000000000000000)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 1, 13 }, .value = @bitCast(@as(u64, 0xfff0000000000000)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 13 } }, .keys = &.{ 18437736874454810625, 13 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 1 }, .value = @bitCast(@as(u64, 0x3fc0000000000000)), .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2049, .value = 1 } }, .keys = &.{ 9187343239835811840, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 2, 2048 }, .value = @bitCast(@as(u64, 0xc060000000000000)), .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2049, .value = 2048 } }, .keys = &.{ 9277415232383221761, 2048 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 0 }, .value = @bitCast(@as(u64, 0x0)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 1 }, .value = @bitCast(@as(u64, 0x8000000000000000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 2 }, .value = @bitCast(@as(u64, 0x1)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 2 } }, .keys = &.{ 2, 2 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18437736874454810623 }, .value = @bitCast(@as(u64, 0xffefffffffffffff)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18437736874454810623 } }, .keys = &.{ 18437736874454810623, 18437736874454810623 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18437736874454810626 }, .value = @bitCast(@as(u64, 0x7ff0000000000000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18437736874454810626 } }, .keys = &.{ 18437736874454810624, 18437736874454810626 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18446744073709551614 }, .value = @bitCast(@as(u64, 0x7ff0000000000000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18446744073709551614 } }, .keys = &.{ 18437736874454810624, 18446744073709551614 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18442240474082181120 }, .value = @bitCast(@as(u64, 0x7ff0000000000000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18442240474082181120 } }, .keys = &.{ 18437736874454810624, 18442240474082181120 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18437736874454810627 }, .value = @bitCast(@as(u64, 0xfff0000000000000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18437736874454810627 } }, .keys = &.{ 18437736874454810625, 18437736874454810627 }, .skips = &.{ false, true }, .consumed = 2 },
    .{ .values = &.{ 3, 18442240474082181131 }, .value = @bitCast(@as(u64, 0xfff0000000000000)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 18442240474082181131 } }, .keys = &.{ 18437736874454810625, 18442240474082181131 }, .skips = &.{ false, true }, .consumed = 2 },
};

const replay_enum_explicit = [_]ReplayPin(EnumExplicit){
    .{ .values = &.{0}, .value = .a, .choices = &.{.{ .bound = 3, .value = 0 }}, .keys = &.{0}, .skips = &.{false}, .consumed = 1 },
    .{ .values = &.{2}, .value = .c, .choices = &.{.{ .bound = 3, .value = 2 }}, .keys = &.{2}, .skips = &.{false}, .consumed = 1 },
};

const replay_enum_nonexhaustive = [_]ReplayPin(EnumNonExhaustive){
    .{ .values = &.{0}, .value = .x, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false}, .consumed = 1 },
    .{ .values = &.{1}, .value = .y, .choices = &.{.{ .bound = 2, .value = 1 }}, .keys = &.{1}, .skips = &.{false}, .consumed = 1 },
};

const replay_opt_u8 = [_]ReplayPin(?u8){
    .{ .values = &.{0}, .value = null, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false}, .consumed = 1 },
    .{ .values = &.{ 1, 3, 9 }, .value = 9, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 9 } }, .keys = &.{ 1, 9, 9 }, .skips = &.{ false, false, true }, .consumed = 3 },
};

const replay_opt_opt_u8 = [_]ReplayPin(??u8){
    .{ .values = &.{0}, .value = null, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false}, .consumed = 1 },
    .{ .values = &.{ 1, 0 }, .value = @as(?u8, null), .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 2, .value = 0 } }, .keys = &.{ 1, 0 }, .skips = &.{ false, false }, .consumed = 2 },
    .{ .values = &.{ 1, 1, 0, 5 }, .value = @as(?u8, 5), .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 } }, .keys = &.{ 1, 1, 5, 5 }, .skips = &.{ false, false, false, true }, .consumed = 4 },
};

const replay_array3 = [_]ReplayPin([3]u8){
    .{ .values = &.{ 0, 1, 3, 200, 1, 3 }, .value = .{ 1, 200, 255 }, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 1 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 200 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 3 } }, .keys = &.{ 1, 1, 200, 200, 255, 3 }, .skips = &.{ false, true, false, true, false, true }, .consumed = 6 },
};

const replay_array0 = [_]ReplayPin([0]u8){
    .{ .values = &.{}, .value = .{}, .choices = &.{}, .keys = &.{}, .skips = &.{}, .consumed = 0 },
};

const replay_array_of_slices = [_]ReplayPin([2][]const u8){
    .{ .values = &.{ 1, 0, 7, 0 }, .value = .{ &.{7}, &.{} }, .choices = &.{ .{ .bound = 33, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 7 }, .{ .bound = 33, .value = 0 } }, .keys = &.{ 1, 7, 7, 0 }, .skips = &.{ false, false, true, false }, .consumed = 4 },
    .{ .values = &.{ 2, 0, 1, 3, 250, 1, 2, 1 }, .limits = .{ .max_len = 4 }, .value = .{ &.{ 1, 250 }, &.{1} }, .choices = &.{ .{ .bound = 5, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 1 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 250 }, .{ .bound = 5, .value = 1 }, .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 1 } }, .keys = &.{ 2, 1, 1, 250, 250, 1, 1, 1 }, .skips = &.{ false, false, true, false, true, false, false, true }, .consumed = 8 },
};

const replay_slice_of_slices = [_]ReplayPin([]const []const u8){
    .{ .values = &.{ 2, 1, 0, 5, 0 }, .value = &.{ &.{5}, &.{} }, .choices = &.{ .{ .bound = 33, .value = 2 }, .{ .bound = 33, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 }, .{ .bound = 33, .value = 0 } }, .keys = &.{ 2, 1, 5, 5, 0 }, .skips = &.{ false, false, false, true, false }, .consumed = 5 },
    .{ .values = &.{ 1, 2, 3, 255, 1, 0 }, .limits = .{ .max_len = 4 }, .value = &.{&.{ 255, 0 }}, .choices = &.{ .{ .bound = 5, .value = 1 }, .{ .bound = 5, .value = 2 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 255 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 0 } }, .keys = &.{ 1, 2, 255, 255, 0, 0 }, .skips = &.{ false, false, false, true, false, true }, .consumed = 6 },
};

const replay_slice_of_opt_i16 = [_]ReplayPin([]const ?i16){
    .{ .values = &.{ 3, 0, 1, 0, 3, 1, 3, 65535 }, .value = &.{ null, -2, -32768 }, .choices = &.{ .{ .bound = 33, .value = 3 }, .{ .bound = 2, .value = 0 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 3 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 65535 } }, .keys = &.{ 3, 0, 1, 3, 3, 1, 65535, 65535 }, .skips = &.{ false, false, false, false, true, false, false, true }, .consumed = 8 },
};

const replay_struct = [_]ReplayPin(S3){
    .{ .values = &.{ 2, 22188, 1, 1, 1 }, .value = .{ .a = 22188, .b = -1, .c = true }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 22188 }, .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 1 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 22188, 22188, 1, 1, 1 }, .skips = &.{ false, true, false, true, false }, .consumed = 5 },
    .{ .values = &.{ 3, 4294967295, 0, 255, 0 }, .value = .{ .a = 4294967295, .b = -128, .c = false }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 4294967296, .value = 4294967295 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 255 }, .{ .bound = 2, .value = 0 } }, .keys = &.{ 4294967295, 4294967295, 255, 255, 0 }, .skips = &.{ false, true, false, true, false }, .consumed = 5 },
};

const replay_union = [_]ReplayPin(U3){
    .{ .values = &.{1}, .value = .{ .b = {} }, .choices = &.{.{ .bound = 3, .value = 1 }}, .keys = &.{1}, .skips = &.{false}, .consumed = 1 },
    .{ .values = &.{ 2, 0, 5 }, .value = .{ .c = -3 }, .choices = &.{ .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 } }, .keys = &.{ 2, 5, 5 }, .skips = &.{ false, false, true }, .consumed = 3 },
    .{ .values = &.{ 0, 3, 200 }, .value = .{ .a = 200 }, .choices = &.{ .{ .bound = 3, .value = 0 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 200 } }, .keys = &.{ 0, 200, 200 }, .skips = &.{ false, false, true }, .consumed = 3 },
};

const random_u1 = [_]RandomPin(u1){
    .{ .seed = 100, .value = 0, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 2, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true } },
    .{ .seed = 200, .value = 1, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true } },
};

const random_u8 = [_]RandomPin(u8){
    .{ .seed = 101, .value = 254, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 254, 2 }, .skips = &.{ false, true } },
    .{ .seed = 201, .value = 8, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 8 } }, .keys = &.{ 8, 8 }, .skips = &.{ false, true } },
};

const random_u16 = [_]RandomPin(u16){
    .{ .seed = 102, .value = 1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true } },
    .{ .seed = 202, .value = 62526, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 62526 } }, .keys = &.{ 62526, 62526 }, .skips = &.{ false, true } },
};

const random_u17 = [_]RandomPin(u17){
    .{ .seed = 103, .value = 0, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true } },
    .{ .seed = 203, .value = 1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true } },
};

const random_u32 = [_]RandomPin(u32){
    .{ .seed = 104, .value = 36903, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 36903 } }, .keys = &.{ 36903, 36903 }, .skips = &.{ false, true } },
    .{ .seed = 204, .value = 161, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 161 } }, .keys = &.{ 161, 161 }, .skips = &.{ false, true } },
};

const random_u64 = [_]RandomPin(u64){
    .{ .seed = 105, .value = 11532653262026826893, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 11532653262026826893 } }, .keys = &.{ 11532653262026826893, 11532653262026826893 }, .skips = &.{ false, true } },
    .{ .seed = 205, .value = 57939, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 57939 } }, .keys = &.{ 57939, 57939 }, .skips = &.{ false, true } },
};

const random_i1 = [_]RandomPin(i1){
    .{ .seed = 106, .value = -1, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true } },
    .{ .seed = 206, .value = 0, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 2, .value = 0 } }, .keys = &.{ 0, 0 }, .skips = &.{ false, true } },
};

const random_i8 = [_]RandomPin(i8){
    .{ .seed = 107, .value = -17, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 33 } }, .keys = &.{ 33, 33 }, .skips = &.{ false, true } },
    .{ .seed = 207, .value = -87, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 173 } }, .keys = &.{ 173, 173 }, .skips = &.{ false, true } },
};

const random_i16 = [_]RandomPin(i16){
    .{ .seed = 108, .value = 105, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 210 } }, .keys = &.{ 210, 210 }, .skips = &.{ false, true } },
    .{ .seed = 208, .value = 23166, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 46332 } }, .keys = &.{ 46332, 46332 }, .skips = &.{ false, true } },
};

const random_i17 = [_]RandomPin(i17){
    .{ .seed = 109, .value = 10685, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 21370 } }, .keys = &.{ 21370, 21370 }, .skips = &.{ false, true } },
    .{ .seed = 209, .value = -13740, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 27479 } }, .keys = &.{ 27479, 27479 }, .skips = &.{ false, true } },
};

const random_i32 = [_]RandomPin(i32){
    .{ .seed = 110, .value = -28933, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 57865 } }, .keys = &.{ 57865, 57865 }, .skips = &.{ false, true } },
    .{ .seed = 210, .value = -1, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 1 } }, .keys = &.{ 1, 1 }, .skips = &.{ false, true } },
};

const random_i64 = [_]RandomPin(i64){
    .{ .seed = 111, .value = 9, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 18 } }, .keys = &.{ 18, 18 }, .skips = &.{ false, true } },
    .{ .seed = 211, .value = 9223372036854775807, .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 5 } }, .keys = &.{ 18446744073709551614, 5 }, .skips = &.{ false, true } },
};

const random_f16 = [_]RandomPin(f16){
    .{ .seed = 300, .value = @bitCast(@as(u16, 0x3800)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 4 } }, .keys = &.{ 28672, 4 }, .skips = &.{ false, true } },
    .{ .seed = 400, .value = @bitCast(@as(u16, 0xc986)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 37645 } }, .keys = &.{ 37645, 37645 }, .skips = &.{ false, true } },
};

const random_f32 = [_]RandomPin(f32){
    .{ .seed = 301, .value = @bitCast(@as(u32, 0x41100000)), .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 33, .value = 17 } }, .keys = &.{ 2183135232, 17 }, .skips = &.{ false, true } },
    .{ .seed = 401, .value = @bitCast(@as(u32, 0xff800000)), .choices = &.{ .{ .bound = 4, .value = 1 }, .{ .bound = 14, .value = 13 } }, .keys = &.{ 4278190081, 13 }, .skips = &.{ false, true } },
};

const random_f64 = [_]RandomPin(f64){
    .{ .seed = 302, .value = @bitCast(@as(u64, 0x4042800000000000)), .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 2049, .value = 591 } }, .keys = &.{ 9260808208757293056, 591 }, .skips = &.{ false, true } },
    .{ .seed = 402, .value = @bitCast(@as(u64, 0xae62d9debffd9729)), .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 6684946848378728019 } }, .keys = &.{ 6684946848378728019, 6684946848378728019 }, .skips = &.{ false, true } },
};

const random_slice_of_slices = [_]RandomPin([]const []const u8){
    .{ .seed = 17, .limits = .{ .max_len = 3 }, .value = &.{ &.{ 25, 11, 155 }, &.{140} }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 4, .value = 3 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 25 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 11 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 155 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 140 } }, .keys = &.{ 2, 3, 25, 25, 11, 11, 155, 155, 1, 140, 140 }, .skips = &.{ false, false, false, true, false, true, false, true, false, false, true } },
    .{ .seed = 27, .limits = .{ .max_len = 3 }, .value = &.{ &.{245}, &.{ 117, 254, 74 } }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 245 }, .{ .bound = 4, .value = 3 }, .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 117 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 254 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 74 } }, .keys = &.{ 2, 1, 245, 245, 3, 117, 117, 254, 254, 74, 74 }, .skips = &.{ false, false, false, true, false, false, true, false, true, false, true } },
};

const random_slice_of_opt_i16 = [_]RandomPin([]const ?i16){
    .{ .seed = 18, .limits = .{ .max_len = 4 }, .value = &.{ 96, 32767 }, .choices = &.{ .{ .bound = 5, .value = 2 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 192 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 5 } }, .keys = &.{ 2, 1, 192, 192, 1, 65534, 5 }, .skips = &.{ false, false, false, true, false, false, true } },
    .{ .seed = 28, .limits = .{ .max_len = 4 }, .value = &.{0}, .choices = &.{ .{ .bound = 5, .value = 1 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 0 } }, .keys = &.{ 1, 1, 0, 0 }, .skips = &.{ false, false, false, true } },
};

const random_struct = [_]RandomPin(S3){
    .{ .seed = 9, .value = .{ .a = 202, .b = -32768, .c = true }, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 202 }, .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 6 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 202, 202, 65535, 6, 1 }, .skips = &.{ false, true, false, true, false } },
};

const random_union = [_]RandomPin(U3){
    .{ .seed = 10, .value = .{ .b = {} }, .choices = &.{.{ .bound = 3, .value = 1 }}, .keys = &.{1}, .skips = &.{false} },
    .{ .seed = 20, .value = .{ .c = 4341 }, .choices = &.{ .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 8682 } }, .keys = &.{ 2, 8682, 8682 }, .skips = &.{ false, false, true } },
    .{ .seed = 21, .value = .{ .a = 254 }, .choices = &.{ .{ .bound = 3, .value = 0 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 0, 254, 2 }, .skips = &.{ false, false, true } },
    .{ .seed = 22, .value = .{ .a = 44 }, .choices = &.{ .{ .bound = 3, .value = 0 }, .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 44 } }, .keys = &.{ 0, 44, 44 }, .skips = &.{ false, false, true } },
};
