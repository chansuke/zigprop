//! Benchmark / profiling harness for zigprop's core.
//!
//! Run: `zig build bench` (full) or `zig build bench -Dsmoke` (CI).
//! The harness measures the Source layer, which every generated value
//! pays for: one recorded draw per choice. See docs/profiling.md for
//! perf/flamegraph workflows on top of this binary.

const std = @import("std");
const zigprop = @import("zigprop");
const Source = zigprop.internal.Source;

var sink: u64 = 0;

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn benchRangeRandom(io: std.Io, allocator: std.mem.Allocator, iterations: usize) !u64 {
    var src = Source.initRandom(allocator, zigprop.internal.deriveSeed(1, 0), std.math.maxInt(usize));
    defer src.deinit();
    try src.recorded.ensureTotalCapacity(allocator, iterations);
    const start = nowNs(io);
    for (0..iterations) |_| {
        sink +%= src.range(1000);
    }
    return @intCast(nowNs(io) - start);
}

fn benchRangeRandomFullDomain(io: std.Io, allocator: std.mem.Allocator, iterations: usize) !u64 {
    var src = Source.initRandom(allocator, zigprop.internal.deriveSeed(1, 0), std.math.maxInt(usize));
    defer src.deinit();
    try src.recorded.ensureTotalCapacity(allocator, iterations);
    const start = nowNs(io);
    for (0..iterations) |_| {
        sink +%= src.range(0);
    }
    return @intCast(nowNs(io) - start);
}

fn benchRangeReplay(io: std.Io, allocator: std.mem.Allocator, iterations: usize) !u64 {
    // Prepare a recorded sequence to replay.
    var gen = Source.initRandom(allocator, zigprop.internal.deriveSeed(2, 0), std.math.maxInt(usize));
    defer gen.deinit();
    try gen.recorded.ensureTotalCapacity(allocator, iterations);
    for (0..iterations) |_| {
        sink +%= gen.range(1000);
    }
    var src = Source.initReplay(allocator, gen.recorded.items, std.math.maxInt(usize));
    defer src.deinit();
    try src.recorded.ensureTotalCapacity(allocator, iterations);
    const start = nowNs(io);
    for (0..iterations) |_| {
        sink +%= src.range(1000);
    }
    return @intCast(nowNs(io) - start);
}

fn benchDeriveSeed(io: std.Io, iterations: usize) !u64 {
    const start = nowNs(io);
    for (0..iterations) |i| {
        sink +%= zigprop.internal.deriveSeed(42, @intCast(i));
    }
    return @intCast(nowNs(io) - start);
}

fn report(name: []const u8, iterations: usize, ns: u64) void {
    const per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iterations));
    const ops_per_s = 1_000_000_000.0 / per_op;
    std.debug.print("{s:<28} {d:>10} ops  {d:>8.1} ns/op  {d:>12.0} ops/s\n", .{ name, iterations, per_op, ops_per_s });
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const n: usize = if (smoke) 10_000 else 2_000_000;

    std.debug.print("zigprop bench ({s})\n", .{if (smoke) "smoke" else "full"});
    const io = init.io;
    report("range random bound=1000", n, try benchRangeRandom(io, allocator, n));
    report("range random full domain", n, try benchRangeRandomFullDomain(io, allocator, n));
    report("range replay bound=1000", n, try benchRangeReplay(io, allocator, n));
    report("deriveSeed", n, try benchDeriveSeed(io, n));
    std.debug.print("sink: {d}\n", .{sink});
}
