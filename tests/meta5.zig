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
        .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 86 },
        .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 156 },
        .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 },
    }, &.{ 3, 86, 86, 156, 156, 1, 1 }, &.{ false, false, true, false, true, false, true });
}
