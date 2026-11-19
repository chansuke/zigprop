//! Pre-registered validation targets (design §9). Run with
//! `zig build validation`.
//!
//! T1 varint: LEB128 round-trip; the mutant decoder stops after
//! 4 bytes. Expected minimal counterexample: exactly 2^28.
//! T2 RLE: run-length round-trip via a custom generator; the mutant
//! decoder truncates run lengths to u8. Expected minimal
//! counterexample: a single run of length 256.
//!
//! T3 float codec (v0.2 design §4): f32 split into (sign, exponent,
//! mantissa) and rejoined; the mutant drops the mantissa low byte.
//! Registered minimum: rank 2 (the least positive subnormal).
//! Reporting is three-tiered: discovery, subnormal reach, exact
//! minimum. The gate is discovery >= 8/10 AND subnormal >= 8/10.
//!
//! T4 recursive JSON-like union (v0.2 design §4): byte encoding
//! round-trip; the mutant decoder truncates every list to its
//! first 2 elements. Expected minimal counterexample:
//! list[int 0, int 0, int 0]. Gate: discovery >= 8/10 AND exact
//! structural match >= 8/10.
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
// T3: f32 codec
// ---------------------------------------------------------------------

fn f32Split(x: f32) struct { sign: u32, exp: u32, mant: u32 } {
    const bits: u32 = @bitCast(x);
    return .{ .sign = bits >> 31, .exp = (bits >> 23) & 0xff, .mant = bits & 0x7fffff };
}

fn f32Join(sign: u32, exp: u32, mant: u32, mutant: bool) f32 {
    const m = if (mutant) mant & 0x7fff00 else mant; // mutant drops the low byte
    return @bitCast((sign << 31) | (exp << 23) | m);
}

fn propF32(x: f32, mutant: bool) bool {
    const p = f32Split(x);
    const y = f32Join(p.sign, p.exp, p.mant, mutant);
    return @as(u32, @bitCast(y)) == @as(u32, @bitCast(x));
}

fn propF32Mutant(x: f32) bool {
    return propF32(x, true);
}

fn propF32Correct(x: f32) bool {
    return propF32(x, false);
}

/// Canonical rank of an f32 bit pattern (NaN collapses to the
/// infinity rank of its sign), matching the generator's order.
fn f32RankOfBits(bits: u32) u64 {
    const sign: u64 = bits >> 31;
    var a: u64 = bits & 0x7fffffff;
    const exp: u32 = (bits >> 23) & 0xff;
    const mant: u32 = bits & 0x7fffff;
    if (exp == 0xff and mant != 0) a = 0xff << 23;
    return 2 * a + sign;
}

// ---------------------------------------------------------------------
// T4: recursive JSON-like union codec
// ---------------------------------------------------------------------

const Value = union(enum) { int: i64, str: []const u8, list: []const Value };

fn encodeValue(v: Value, buf: []u8, pos: *usize) void {
    switch (v) {
        .int => |n| {
            buf[pos.*] = 0;
            pos.* += 1;
            std.mem.writeInt(i64, buf[pos.*..][0..8], n, .little);
            pos.* += 8;
        },
        .str => |s| {
            buf[pos.*] = 1;
            pos.* += 1;
            std.mem.writeInt(u32, buf[pos.*..][0..4], @intCast(s.len), .little);
            pos.* += 4;
            @memcpy(buf[pos.*..][0..s.len], s);
            pos.* += s.len;
        },
        .list => |items| {
            buf[pos.*] = 2;
            pos.* += 1;
            std.mem.writeInt(u32, buf[pos.*..][0..4], @intCast(items.len), .little);
            pos.* += 4;
            for (items) |item| encodeValue(item, buf, pos);
        },
    }
}

fn decodeValue(bytes: []const u8, pos: *usize, alloc: std.mem.Allocator, mutant: bool) !Value {
    const tag = bytes[pos.*];
    pos.* += 1;
    switch (tag) {
        0 => {
            const n = std.mem.readInt(i64, bytes[pos.*..][0..8], .little);
            pos.* += 8;
            return .{ .int = n };
        },
        1 => {
            const len = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
            pos.* += 4;
            const str = bytes[pos.*..][0..len];
            pos.* += len;
            return .{ .str = str };
        },
        2 => {
            const n = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
            pos.* += 4;
            const keep = if (mutant) @min(n, 2) else n;
            const items = try alloc.alloc(Value, keep);
            for (0..n) |i| {
                const item = try decodeValue(bytes, pos, alloc, mutant);
                if (i < keep) items[i] = item;
            }
            return .{ .list = items };
        },
        else => unreachable,
    }
}

fn valueEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .int => |n| return n == b.int,
        .str => |s| return std.mem.eql(u8, s, b.str),
        .list => |items| {
            if (items.len != b.list.len) return false;
            for (items, b.list) |x, y| {
                if (!valueEql(x, y)) return false;
            }
            return true;
        },
    }
}

// The property signature has no allocator, so encode/decode run
// over fixed buffers (sized far above what the generation limits
// can produce: at most 4096 elements per case).
var t4_enc_buf: [256 * 1024]u8 = undefined;
var t4_dec_buf: [16 * 1024 * 1024]u8 = undefined;

fn propValue(v: Value, mutant: bool) bool {
    var pos: usize = 0;
    encodeValue(v, &t4_enc_buf, &pos);
    var fba = std.heap.FixedBufferAllocator.init(&t4_dec_buf);
    var dpos: usize = 0;
    const decoded = decodeValue(t4_enc_buf[0..pos], &dpos, fba.allocator(), mutant) catch return true;
    return valueEql(v, decoded);
}

fn propValueMutant(v: Value) bool {
    return propValue(v, true);
}

fn propValueCorrect(v: Value) bool {
    return propValue(v, false);
}

fn isExpectedT4Minimum(v: Value) bool {
    if (std.meta.activeTag(v) != .list or v.list.len != 3) return false;
    for (v.list) |item| {
        if (std.meta.activeTag(item) != .int or item.int != 0) return false;
    }
    return true;
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

fn replayF32(allocator: std.mem.Allocator, choices: []const zigprop.Choice) !f32 {
    var src = zigprop.Source.initReplay(allocator, choices, 100_000);
    defer src.deinit();
    var ctx = zigprop.GenContext{ .src = &src, .allocator = allocator, .limits = .{} };
    return zigprop.generate(f32, &ctx);
}

fn replayValue(allocator: std.mem.Allocator, choices: []const zigprop.Choice) !Value {
    var src = zigprop.Source.initReplay(allocator, choices, 100_000);
    defer src.deinit();
    var ctx = zigprop.GenContext{ .src = &src, .allocator = allocator, .limits = .{} };
    return zigprop.generate(Value, &ctx);
}

fn filteredKeyLen(src: *zigprop.Source) usize {
    var n: usize = 0;
    for (src.recorded_skip.items) |skip| {
        if (!skip) n += 1;
    }
    return n;
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

    // ---------------- T3 ----------------
    out.print("\n== T3 f32 codec (mutant: mantissa low byte dropped) ==\n", .{});
    out.print("seed | zigprop: cases, shrunk bits, tier, evals | hand loop: found, best rank\n", .{});
    var t3_discovered: usize = 0;
    var t3_subnormal: usize = 0;
    var t3_exact: usize = 0;
    var t3_control_ok: usize = 0;
    for (0..10) |seed| {
        var report = try zigprop.check(allocator, f32, propF32Mutant, .{ .seed = seed, .max_cases = 200 });
        defer report.deinit();
        var hand_prng = std.Random.DefaultPrng.init(seed);
        const hand_rand = hand_prng.random();
        var hand_found = false;
        var hand_best_rank: u64 = std.math.maxInt(u64);
        for (0..200) |_| {
            const bits = hand_rand.int(u32);
            const x: f32 = @bitCast(bits);
            if (!propF32Mutant(x)) {
                hand_found = true;
                const r = f32RankOfBits(bits);
                if (r < hand_best_rank) hand_best_rank = r;
            }
        }
        switch (report) {
            .failed => |f| {
                t3_discovered += 1;
                const shrunk = try replayF32(allocator, f.shrunk_choices);
                const sbits: u32 = @bitCast(shrunk);
                const sexp: u32 = (sbits >> 23) & 0xff;
                const smant: u32 = sbits & 0x7fffff;
                const is_sub = sexp == 0 and smant != 0;
                const is_exact = sbits == 1;
                if (is_sub) t3_subnormal += 1;
                if (is_exact) t3_exact += 1;
                out.print("{d:>4} | cases {d}, bits 0x{x:0>8}, {s}, evals {d} | hand: {s}, best rank {d}\n", .{
                    seed,                                 f.attempt_index + 1, sbits, if (is_exact) "EXACT (rank 2)" else (if (is_sub) "subnormal" else "other"), f.shrink_evaluations,
                    if (hand_found) "found" else "none ", hand_best_rank,
                });
            },
            else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(report)) }),
        }
        var control = try zigprop.check(allocator, f32, propF32Correct, .{ .seed = seed, .max_cases = 200 });
        defer control.deinit();
        if (std.meta.activeTag(control) == .passed) t3_control_ok += 1;
    }
    out.print("T3: discovered {d}/10, subnormal {d}/10, exact rank-2 {d}/10, control passed {d}/10\n", .{ t3_discovered, t3_subnormal, t3_exact, t3_control_ok });
    out.print("T3 criterion (gate: >=8 discovered AND >=8 subnormal; exact reported): {s}\n", .{
        if (t3_discovered >= 8 and t3_subnormal >= 8) "MET" else "NOT MET",
    });

    // ---------------- T4 ----------------
    out.print("\n== T4 recursive union codec (mutant: lists truncated to 2) ==\n", .{});
    out.print("seed | zigprop: cases, shrunk shape, evals | hand loop: found, best key length\n", .{});
    var t4_discovered: usize = 0;
    var t4_exact: usize = 0;
    var t4_control_ok: usize = 0;
    for (0..10) |seed| {
        var report = try zigprop.check(allocator, Value, propValueMutant, .{ .seed = seed, .max_cases = 200 });
        defer report.deinit();
        // Hand loop: raw generation without shrinking, same budget.
        var hand_found = false;
        var hand_best_keys: usize = std.math.maxInt(usize);
        for (0..200) |attempt| {
            var src = zigprop.Source.initRandom(allocator, zigprop.deriveSeed(seed, attempt), 100_000);
            defer src.deinit();
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var ctx = zigprop.GenContext{ .src = &src, .allocator = arena.allocator(), .limits = .{} };
            const v = zigprop.generate(Value, &ctx) catch continue;
            if (!propValueMutant(v)) {
                hand_found = true;
                const k = filteredKeyLen(&src);
                if (k < hand_best_keys) hand_best_keys = k;
            }
        }
        switch (report) {
            .failed => |f| {
                t4_discovered += 1;
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const shrunk = try replayValue(arena.allocator(), f.shrunk_choices);
                const exact = isExpectedT4Minimum(shrunk);
                if (exact) t4_exact += 1;
                out.print("{d:>4} | cases {d}, shrunk {s}, evals {d} | hand: {s}, best keys {d}\n", .{
                    seed,                                 f.attempt_index + 1, if (exact) "list[int 0, int 0, int 0] (exact)" else "other shape", f.shrink_evaluations,
                    if (hand_found) "found" else "none ", hand_best_keys,
                });
            },
            else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(report)) }),
        }
        var control = try zigprop.check(allocator, Value, propValueCorrect, .{ .seed = seed, .max_cases = 200 });
        defer control.deinit();
        if (std.meta.activeTag(control) == .passed) t4_control_ok += 1;
    }
    out.print("T4: discovered {d}/10, exact list[int 0 x3] {d}/10, control passed {d}/10\n", .{ t4_discovered, t4_exact, t4_control_ok });
    out.print("T4 criterion (>=8 discovered AND >=8 exact): {s}\n", .{
        if (t4_discovered >= 8 and t4_exact >= 8) "MET" else "NOT MET",
    });
}
