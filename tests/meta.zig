//! Meta tests for zigprop itself (design §8).
//! Milestone 1 covers the Source layer: range validity, determinism and
//! replay fidelity. Runner/shrink meta tests arrive with their milestones.

const std = @import("std");
const zigprop = @import("zigprop");
const Source = zigprop.Source;
const Choice = zigprop.Choice;

const bounds = [_]u64{ 1, 2, 3, 7, 1000, 1 << 63, 0 }; // 0 = full-domain sentinel

test "range validity: every recorded choice satisfies bound == 0 or value < bound" {
    var src = Source.initRandom(std.testing.allocator, zigprop.deriveSeed(42, 0), 100_000);
    defer src.deinit();
    for (0..1000) |i| {
        const bound = bounds[i % bounds.len];
        const v = src.range(bound);
        if (bound != 0) try std.testing.expect(v < bound);
    }
    try std.testing.expectEqual(@as(usize, 1000), src.recorded.items.len);
    for (src.recorded.items) |c| {
        try std.testing.expect(c.bound == 0 or c.value < c.bound);
    }
    try std.testing.expect(src.sticky_error == null);
}

test "determinism: same derived seed reproduces the same choice sequence" {
    var a = Source.initRandom(std.testing.allocator, zigprop.deriveSeed(42, 3), 100_000);
    defer a.deinit();
    var b = Source.initRandom(std.testing.allocator, zigprop.deriveSeed(42, 3), 100_000);
    defer b.deinit();
    for (0..500) |i| {
        const bound = bounds[i % bounds.len];
        try std.testing.expectEqual(a.range(bound), b.range(bound));
    }
    try std.testing.expectEqualSlices(Choice, a.recorded.items, b.recorded.items);
}

test "different attempts diverge" {
    var a = Source.initRandom(std.testing.allocator, zigprop.deriveSeed(42, 0), 100_000);
    defer a.deinit();
    var b = Source.initRandom(std.testing.allocator, zigprop.deriveSeed(42, 1), 100_000);
    defer b.deinit();
    for (0..100) |i| {
        const bound = bounds[i % bounds.len];
        _ = a.range(bound);
        _ = b.range(bound);
    }
    var diverged = false;
    for (a.recorded.items, b.recorded.items) |ca, cb| {
        if (ca.bound != cb.bound or ca.value != cb.value) diverged = true;
    }
    try std.testing.expect(diverged);
}

test "replay fidelity: replaying the recorded sequence regenerates the same values" {
    var gen = Source.initRandom(std.testing.allocator, zigprop.deriveSeed(9, 5), 100_000);
    defer gen.deinit();
    var values: [300]u64 = undefined;
    for (0..300) |i| {
        values[i] = gen.range(bounds[i % bounds.len]);
    }
    var rep = Source.initReplay(std.testing.allocator, gen.recorded.items, 100_000);
    defer rep.deinit();
    for (0..300) |i| {
        try std.testing.expectEqual(values[i], rep.range(bounds[i % bounds.len]));
    }
    try std.testing.expectEqualSlices(Choice, gen.recorded.items, rep.recorded.items);
    try std.testing.expect(!rep.exhausted);
}

test "replay normalization: recorded values are reduced modulo the requested bound" {
    const recorded = [_]Choice{.{ .bound = 10, .value = 9 }};
    var rep = Source.initReplay(std.testing.allocator, &recorded, 100);
    defer rep.deinit();
    try std.testing.expectEqual(@as(u64, 0), rep.range(3)); // 9 % 3
    try std.testing.expectEqual(@as(u64, 3), rep.recorded.items[0].bound);
    try std.testing.expectEqual(@as(u64, 0), rep.recorded.items[0].value);
    // The sentinel bound passes the raw value through untouched.
    var rep2 = Source.initReplay(std.testing.allocator, &recorded, 100);
    defer rep2.deinit();
    try std.testing.expectEqual(@as(u64, 9), rep2.range(0));
}

test "replay exhaustion: draws past the end return 0 and set the flag" {
    const recorded = [_]Choice{.{ .bound = 5, .value = 3 }};
    var rep = Source.initReplay(std.testing.allocator, &recorded, 100);
    defer rep.deinit();
    try std.testing.expectEqual(@as(u64, 3), rep.range(5));
    try std.testing.expect(!rep.exhausted);
    try std.testing.expectEqual(@as(u64, 0), rep.range(5));
    try std.testing.expect(rep.exhausted);
}

test "replay of an empty sequence exhausts immediately" {
    var rep = Source.initReplay(std.testing.allocator, &.{}, 100);
    defer rep.deinit();
    try std.testing.expectEqual(@as(u64, 0), rep.range(5));
    try std.testing.expect(rep.exhausted);
}

test "replay ignores an unconsumed surplus suffix" {
    const recorded = [_]Choice{
        .{ .bound = 5, .value = 3 },
        .{ .bound = 5, .value = 4 },
        .{ .bound = 5, .value = 2 },
    };
    var rep = Source.initReplay(std.testing.allocator, &recorded, 100);
    defer rep.deinit();
    try std.testing.expectEqual(@as(u64, 3), rep.range(5));
    try std.testing.expect(!rep.exhausted);
    // Only the consumed prefix is re-recorded; the suffix drops off.
    try std.testing.expectEqual(@as(usize, 1), rep.recorded.items.len);
}

test "boolean draws are recorded as range(2)" {
    var src = Source.initRandom(std.testing.allocator, zigprop.deriveSeed(3, 0), 100);
    defer src.deinit();
    for (0..50) |_| _ = src.boolean();
    for (src.recorded.items) |c| {
        try std.testing.expectEqual(@as(u64, 2), c.bound);
        try std.testing.expect(c.value < 2);
    }
}
