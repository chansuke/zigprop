//! Pre-registered validation targets (design §9). Run with
//! `zig build validation`.
//!
//! T1 varint: LEB128 round-trip; the mutant decoder stops after
//! 4 bytes. Expected minimal counterexample: exactly 2^28.
//! T2 RLE: run-length round-trip via a custom generator; the mutant
//! decoder truncates run lengths to u8. Expected minimal
//! counterexample: a single run of length 256.
//!
//! Success criterion (registered in advance): for each target, at
//! least 8 of seeds 0..9 discover a failure within max_cases = 200
//! AND shrink to the expected minimal counterexample. A hand-written
//! random loop with the same seed budget is measured alongside;
//! correct (non-mutant) codecs must not fail (control).

const std = @import("std");
const zigprop = @import("zigprop");

// ---------------------------------------------------------------------
// T1: varint
// ---------------------------------------------------------------------

fn varintEncode(x: u32, buf: *[5]u8) []const u8 {
    var v = x;
    var i: usize = 0;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        buf[i] = byte;
        i += 1;
        if (v == 0) break;
    }
    return buf[0..i];
}

fn varintDecode(bytes: []const u8) u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    for (bytes) |byte| {
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

/// Mutant: the decoder stops after 4 bytes (28 bits) and ignores any
/// continuation, so values >= 2^28 lose their high bits.
fn varintDecodeMutant(bytes: []const u8) u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4) break;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

fn propVarintMutant(x: u32) bool {
    var buf: [5]u8 = undefined;
    return varintDecodeMutant(varintEncode(x, &buf)) == x;
}

fn propVarintCorrect(x: u32) bool {
    var buf: [5]u8 = undefined;
    return varintDecode(varintEncode(x, &buf)) == x;
}

// ---------------------------------------------------------------------
// T2: RLE
// ---------------------------------------------------------------------

const Run = struct { value: u8, len: u32 };
const max_runs = 5;

fn rleEncode(runs: []const Run, buf: *[max_runs * 3]u8) []const u8 {
    var i: usize = 0;
    for (runs) |r| {
        buf[i] = r.value;
        std.mem.writeInt(u16, buf[i + 1 ..][0..2], @intCast(r.len), .little);
        i += 3;
    }
    return buf[0..i];
}

fn rleDecode(bytes: []const u8, out: *[max_runs]Run, mutant: bool) []const Run {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const len16 = std.mem.readInt(u16, bytes[i + 1 ..][0..2], .little);
        out[n] = .{
            .value = bytes[i],
            // The mutant truncates the length to u8 (the low byte).
            .len = if (mutant) @as(u32, len16 & 0xff) else @as(u32, len16),
        };
        n += 1;
    }
    return out[0..n];
}

fn runsEql(a: []const Run, b: []const Run) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.value != y.value or x.len != y.len) return false;
    }
    return true;
}

fn propRle(runs: []const Run, mutant: bool) bool {
    var ebuf: [max_runs * 3]u8 = undefined;
    var dout: [max_runs]Run = undefined;
    const decoded = rleDecode(rleEncode(runs, &ebuf), &dout, mutant);
    return runsEql(runs, decoded);
}

fn propRleMutant(runs: []const Run) bool {
    return propRle(runs, true);
}

fn propRleCorrect(runs: []const Run) bool {
    return propRle(runs, false);
}

fn genRuns(ctx: *zigprop.GenContext) anyerror![]const Run {
    const n = 1 + ctx.src.length(max_runs - 1); // 1..5 runs
    const runs = try ctx.allocator.alloc(Run, n);
    for (runs) |*r| {
        r.* = .{
            .value = @intCast(ctx.src.range(256)),
            .len = 200 + @as(u32, @intCast(ctx.src.range(101))), // 200..300
        };
    }
    return runs;
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

fn replayU32(allocator: std.mem.Allocator, choices: []const zigprop.Choice) !u32 {
    var src = zigprop.Source.initReplay(allocator, choices, 100_000);
    defer src.deinit();
    var ctx = zigprop.GenContext{ .src = &src, .allocator = allocator, .limits = .{} };
    return zigprop.generate(u32, &ctx);
}

fn replayRuns(allocator: std.mem.Allocator, choices: []const zigprop.Choice) ![]const Run {
    var src = zigprop.Source.initReplay(allocator, choices, 100_000);
    defer src.deinit();
    var ctx = zigprop.GenContext{ .src = &src, .allocator = allocator, .limits = .{} };
    return genRuns(&ctx);
}

// ---------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const out = std.debug;

    // ---------------- T1 ----------------
    out.print("\n== T1 varint (mutant: decoder truncated at 4 bytes) ==\n", .{});
    out.print("seed | zigprop: cases, shrunk value, shrink evals | hand loop: cases, found value\n", .{});
    var t1_discovered: usize = 0;
    var t1_exact: usize = 0;
    var t1_control_ok: usize = 0;
    for (0..10) |seed| {
        var report = try zigprop.check(allocator, u32, propVarintMutant, .{ .seed = seed, .max_cases = 200 });
        defer report.deinit();
        var hand_prng = std.Random.DefaultPrng.init(seed);
        const hand_rand = hand_prng.random();
        var hand_cases: ?usize = null;
        var hand_value: u32 = 0;
        for (1..201) |i| {
            const x = hand_rand.int(u32);
            if (!propVarintMutant(x)) {
                hand_cases = i;
                hand_value = x;
                break;
            }
        }
        switch (report) {
            .failed => |f| {
                t1_discovered += 1;
                const shrunk = try replayU32(allocator, f.shrunk_choices);
                const exact = shrunk == 268435456;
                if (exact) t1_exact += 1;
                out.print("{d:>4} | cases {d}, shrunk {d}{s}, evals {d} | hand: {s}, {d}\n", .{
                    seed,                                     f.attempt_index + 1, shrunk, if (exact) " (exact)" else "", f.shrink_evaluations,
                    if (hand_cases) |_| "found" else "none ", hand_value,
                });
            },
            else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(report)) }),
        }
        var control = try zigprop.check(allocator, u32, propVarintCorrect, .{ .seed = seed, .max_cases = 200 });
        defer control.deinit();
        if (std.meta.activeTag(control) == .passed) t1_control_ok += 1;
    }
    out.print("T1: discovered {d}/10, exact 2^28 {d}/10, control passed {d}/10\n", .{ t1_discovered, t1_exact, t1_control_ok });
    out.print("T1 criterion (>=8 discovered AND >=8 exact): {s}\n", .{
        if (t1_discovered >= 8 and t1_exact >= 8) "MET" else "NOT MET",
    });

    // ---------------- T2 ----------------
    out.print("\n== T2 RLE (mutant: run length truncated to u8) ==\n", .{});
    out.print("seed | zigprop: cases, shrunk input, shrink evals | hand loop: cases, first failing input\n", .{});
    var t2_discovered: usize = 0;
    var t2_exact: usize = 0;
    var t2_control_ok: usize = 0;
    for (0..10) |seed| {
        var report = try zigprop.checkCustom(allocator, []const Run, genRuns, propRleMutant, .{ .seed = seed, .max_cases = 200 });
        defer report.deinit();
        var hand_prng = std.Random.DefaultPrng.init(seed);
        const hand_rand = hand_prng.random();
        var hand_desc: ?[]const u8 = null;
        var hand_buf: [128]u8 = undefined;
        for (1..201) |i| {
            _ = i;
            var runs_buf: [max_runs]Run = undefined;
            const n = 1 + hand_rand.intRangeLessThan(usize, 0, max_runs);
            for (runs_buf[0..n]) |*r| {
                r.* = .{
                    .value = hand_rand.int(u8),
                    .len = 200 + hand_rand.intRangeLessThan(u32, 0, 101),
                };
            }
            if (!propRleMutant(runs_buf[0..n])) {
                hand_desc = try std.fmt.bufPrint(&hand_buf, "{d} run(s), first len {d}", .{ n, runs_buf[0].len });
                break;
            }
        }
        switch (report) {
            .failed => |f| {
                t2_discovered += 1;
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const shrunk = try replayRuns(arena.allocator(), f.shrunk_choices);
                const exact = shrunk.len == 1 and shrunk[0].len == 256;
                if (exact) t2_exact += 1;
                out.print("{d:>4} | cases {d}, shrunk {d} run(s) first len {d}{s}, evals {d} | hand: {s}\n", .{
                    seed,                    f.attempt_index + 1, shrunk.len, shrunk[0].len, if (exact) " (exact)" else "", f.shrink_evaluations,
                    hand_desc orelse "none",
                });
            },
            else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(report)) }),
        }
        var control = try zigprop.checkCustom(allocator, []const Run, genRuns, propRleCorrect, .{ .seed = seed, .max_cases = 200 });
        defer control.deinit();
        if (std.meta.activeTag(control) == .passed) t2_control_ok += 1;
    }
    out.print("T2: discovered {d}/10, exact single-run-256 {d}/10, control passed {d}/10\n", .{ t2_discovered, t2_exact, t2_control_ok });
    out.print("T2 criterion (>=8 discovered AND >=8 exact): {s}\n", .{
        if (t2_discovered >= 8 and t2_exact >= 8) "MET" else "NOT MET",
    });
}
