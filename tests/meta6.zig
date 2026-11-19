//! v0.2 milestone 2: tagged union generation (design v0.2 §2).
//!
//! Pins the draw shape (tag index draw, then payload draws), the
//! named-variants-only rule for non-exhaustive tags, and the
//! corrected shrink rule of §2.2 (MF4): the number of filtered keys
//! decides first, the tag index only breaks ties — declaration
//! order is NOT a general shrink preference.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const GenContext = zigprop.GenContext;

fn genFromValues(comptime T: type, values: []const u64) !T {
    var buf: [8]Choice = undefined;
    for (values, 0..) |v, i| buf[i] = .{ .bound = 0, .value = v };
    var src = zigprop.Source.initReplay(std.testing.allocator, buf[0..values.len], 100_000);
    defer src.deinit();
    var ctx = GenContext{ .src = &src, .allocator = std.testing.allocator, .limits = .{} };
    return zigprop.generate(T, &ctx);
}

const U = union(enum) { a: u8, b: void, c: i32 };

test "unions: tag draw selects the variant, payload draws follow" {
    // tag 2 -> .c, whose payload is an integer pair: class 0, rank 5
    // -> zigzag value -3.
    const vc = try genFromValues(U, &.{ 2, 0, 5 });
    try std.testing.expect(std.meta.activeTag(vc) == .c);
    try std.testing.expectEqual(@as(i32, -3), vc.c);
    // tag 1 -> .b (void): exactly one choice consumed.
    const vb = try genFromValues(U, &.{1});
    try std.testing.expect(std.meta.activeTag(vb) == .b);
    // tag 0 -> .a with a u8 pair: class 3, rank 200.
    const va = try genFromValues(U, &.{ 0, 3, 200 });
    try std.testing.expect(std.meta.activeTag(va) == .a);
    try std.testing.expectEqual(@as(u8, 200), va.a);
}

test "unions: all-zero draws give the first variant with a zero payload" {
    const v = try genFromValues(U, &.{ 0, 0, 0 });
    try std.testing.expect(std.meta.activeTag(v) == .a);
    try std.testing.expectEqual(@as(u8, 0), v.a);
}

test "unions: non-exhaustive tags generate named variants only" {
    const Tag = enum(u8) { x, y, _ };
    const NE = union(Tag) { x: u8, y: void };
    const vx = try genFromValues(NE, &.{ 0, 3, 77 });
    try std.testing.expect(std.meta.activeTag(vx) == .x);
    try std.testing.expectEqual(@as(u8, 77), vx.x);
    const vy = try genFromValues(NE, &.{1});
    try std.testing.expect(std.meta.activeTag(vy) == .y);
    // Random draws only ever produce x or y (the tag draw ranges
    // over the declared fields, not the tag enum's value space).
    var src = zigprop.Source.initRandom(std.testing.allocator, zigprop.deriveSeed(5, 0), 100_000);
    defer src.deinit();
    var ctx = GenContext{ .src = &src, .allocator = std.testing.allocator, .limits = .{} };
    for (0..200) |_| {
        const v = try zigprop.generate(NE, &ctx);
        try std.testing.expect(std.meta.activeTag(v) == .x or std.meta.activeTag(v) == .y);
    }
}

const BigOrNone = union(enum) { big: u32, none: void };

fn bigOrNoneProp(u: BigOrNone) bool {
    return switch (u) {
        .big => |v| v < 100,
        .none => false,
    };
}

test "unions: key count beats declaration order (MF4)" {
    // .big is declared first, but its failing encoding has two
    // filtered keys [0, 100000] while .none has one [1]. Shortlex
    // compares lengths first, so the shrinker must move to .none
    // even though it is declared second.
    const entries = [_]zigprop.Regression{.{ .id = "u", .gen_version = zigprop.generator_version, .choices = &.{ 0, 3, 100000 } }};
    var report = try zigprop.check(std.testing.allocator, BigOrNone, bigOrNoneProp, .{
        .seed = 0,
        .regressions = &entries,
        .regression_id = "u",
    });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .failed);
    try std.testing.expect(report.failed.regression_index != null);
    try std.testing.expectEqual(@as(usize, 1), report.failed.shrunk_choices.len);
    var src = zigprop.Source.initReplay(std.testing.allocator, report.failed.shrunk_choices, 100_000);
    defer src.deinit();
    var ctx = GenContext{ .src = &src, .allocator = std.testing.allocator, .limits = .{} };
    const v = try zigprop.generate(BigOrNone, &ctx);
    try std.testing.expect(std.meta.activeTag(v) == .none);
}

const TwoVoids = union(enum) { a: void, b: void };

fn bothFail(_: TwoVoids) bool {
    return false;
}

test "unions: the tag index breaks ties between equal key counts" {
    // Both variants fail and both encodings are one key long, so
    // the smaller tag index (declaration order) wins the tie.
    const entries = [_]zigprop.Regression{.{ .id = "u", .gen_version = zigprop.generator_version, .choices = &.{1} }};
    var report = try zigprop.check(std.testing.allocator, TwoVoids, bothFail, .{
        .seed = 0,
        .regressions = &entries,
        .regression_id = "u",
    });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .failed);
    try std.testing.expect(report.failed.regression_index != null);
    var src = zigprop.Source.initReplay(std.testing.allocator, report.failed.shrunk_choices, 100_000);
    defer src.deinit();
    var ctx = GenContext{ .src = &src, .allocator = std.testing.allocator, .limits = .{} };
    const v = try zigprop.generate(TwoVoids, &ctx);
    try std.testing.expect(std.meta.activeTag(v) == .a);
}

test "unions: nested union values format readably with {any} (NTH2)" {
    const Inner = union(enum) { x: u8, y: void };
    const Outer = union(enum) { inner: Inner, n: u32 };
    const v = try genFromValues(Outer, &.{ 0, 0, 3, 42 });
    try std.testing.expect(std.meta.activeTag(v) == .inner);
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{any}", .{v});
    try std.testing.expect(std.mem.indexOf(u8, text, "inner") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "42") != null);
}

test "unions: check discovers a failing variant" {
    const prop = struct {
        fn p(u: U) bool {
            return std.meta.activeTag(u) != .b;
        }
    }.p;
    var report = try zigprop.check(std.testing.allocator, U, prop, .{ .seed = 0 });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .failed);
    var src = zigprop.Source.initReplay(std.testing.allocator, report.failed.shrunk_choices, 100_000);
    defer src.deinit();
    var ctx = GenContext{ .src = &src, .allocator = std.testing.allocator, .limits = .{} };
    const v = try zigprop.generate(U, &ctx);
    try std.testing.expect(std.meta.activeTag(v) == .b);
}
