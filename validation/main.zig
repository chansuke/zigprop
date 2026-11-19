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
//! T6 tree subtree promotion and T7 slice element deletion (v0.3
//! design §8.2): gates found >= 8/10 AND minimal (keys [14, 0] /
//! [1, 7]) >= 8/10, controls 10/10. The P6-off / P5-off ablations
//! and the v0.2.1 baseline (M0-e) are measurements only.
//!
//! T9 / T9e (v0.3 design §8.2): T4 written with checkWith (codec as
//! context, case.allocator, no globals). T9 gates: found >= 8/10 AND
//! structure >= 8/10 AND per-seed shrunk choices identical to T4's
//! AND zero leaks under DebugAllocator. T9e: the decoder returns
//! error.UnexpectedLength; the failure must be reported with that
//! kind and keep it on every shrink acceptance (internal hook).
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
    const n = 1 + ctx.length(max_runs - 1); // 1..5 runs
    const runs = try ctx.allocator.alloc(Run, n);
    for (runs) |*r| {
        r.* = .{
            .value = @intCast(ctx.range(256)),
            .len = 200 + @as(u32, @intCast(ctx.range(101))), // 200..300
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

// ---------------------------------------------------------------------
// T9 / T9e: the T4 codec through checkWith (design v0.3 §8.2). The
// codec configuration is the property's context; encoding and
// decoding use the per-case allocator. There is no container-level
// buffer for T9 (gate 4): every byte lives in `case.allocator`.
// ---------------------------------------------------------------------

const Codec = struct {
    mode: Mode,

    const Mode = enum {
        correct,
        /// T4's mutant: every list is truncated to its first 2 elements.
        truncate,
        /// T9e: lists of 3 or more elements are rejected with an error.
        reject,
    };

    fn encodeAlloc(_: *const Codec, a: std.mem.Allocator, v: Value) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        try encodeList(&list, a, v);
        return list.items;
    }

    fn encodeList(list: *std.ArrayList(u8), a: std.mem.Allocator, v: Value) !void {
        switch (v) {
            .int => |n| {
                try list.append(a, 0);
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, n, .little);
                try list.appendSlice(a, &b);
            },
            .str => |s| {
                try list.append(a, 1);
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @intCast(s.len), .little);
                try list.appendSlice(a, &b);
                try list.appendSlice(a, s);
            },
            .list => |items| {
                try list.append(a, 2);
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @intCast(items.len), .little);
                try list.appendSlice(a, &b);
                for (items) |item| try encodeList(list, a, item);
            },
        }
    }

    fn decode(self: *const Codec, a: std.mem.Allocator, bytes: []const u8) !Value {
        var pos: usize = 0;
        return switch (self.mode) {
            .correct => decodeValue(bytes, &pos, a, false),
            .truncate => decodeValue(bytes, &pos, a, true),
            .reject => decodeRejecting(bytes, &pos, a),
        };
    }

    fn decodeRejecting(bytes: []const u8, pos: *usize, a: std.mem.Allocator) !Value {
        if (bytes[pos.*] == 2) {
            const n = std.mem.readInt(u32, bytes[pos.* + 1 ..][0..4], .little);
            if (n >= 3) return error.UnexpectedLength;
            pos.* += 5;
            const items = try a.alloc(Value, n);
            for (items) |*item| item.* = try decodeRejecting(bytes, pos, a);
            return .{ .list = items };
        }
        return decodeValue(bytes, pos, a, false);
    }
};

fn propT9(codec: *const Codec, case: *zigprop.Case, v: Value) anyerror!bool {
    const enc = try codec.encodeAlloc(case.allocator, v);
    const dec = try codec.decode(case.allocator, enc); // an error is a failure (§5.3)
    return valueEql(v, dec);
}

/// Internal acceptance hook for T9e: counts acceptances whose failure
/// kind differs from the expected one (design v0.3 §3.9, §8.2 T9e).
const KindMonitor = struct {
    expected: zigprop.Failure,
    accepts: usize = 0,
    violations: usize = 0,

    fn hook(self: *KindMonitor) zigprop.internal.AcceptHook {
        return .{ .context = self, .call = call };
    }

    fn call(context: *anyopaque, e: zigprop.internal.AcceptEvent) void {
        const self: *KindMonitor = @ptrCast(@alignCast(context));
        self.accepts += 1;
        if (!e.failure.eql(self.expected)) self.violations += 1;
    }
};

fn isExpectedT4Minimum(v: Value) bool {
    if (std.meta.activeTag(v) != .list or v.list.len != 3) return false;
    for (v.list) |item| {
        if (std.meta.activeTag(item) != .int or item.int != 0) return false;
    }
    return true;
}

// ---------------------------------------------------------------------
// T6: tree subtree promotion (design v0.3 §8.2). Tree { value: i64,
// kids }, max_len = 4, max_depth = 3. The SUT `summarize` computes
// (node count, wrapping value sum); the mutant miscounts any node
// whose value is 7, so the property fails iff some node has value 7.
// Expected minimum: Tree{ .value = 7, .kids = &.{} }, keys [14, 0].
// ---------------------------------------------------------------------

const Tree = struct { value: i64, kids: []const Tree };
const t6_limits: zigprop.Limits = .{ .max_len = 4, .max_depth = 3 };

const Summary = struct { nodes: u64, sum: i64 };

fn summarize(t: Tree, mutant: bool) Summary {
    var s: Summary = .{ .nodes = 1, .sum = t.value };
    if (mutant and t.value == 7) s.nodes += 1;
    for (t.kids) |k| {
        const ks = summarize(k, mutant);
        s.nodes += ks.nodes;
        s.sum +%= ks.sum;
    }
    return s;
}

fn propT6(t: Tree, mutant: bool) bool {
    const got = summarize(t, mutant);
    const want = summarize(t, false);
    return got.nodes == want.nodes and got.sum == want.sum;
}

fn propT6Mutant(t: Tree) bool {
    return propT6(t, true);
}

fn propT6Correct(t: Tree) bool {
    return propT6(t, false);
}

// ---------------------------------------------------------------------
// T7: slice element deletion (design v0.3 §8.2). []const u8, default
// limits. The SUT sums the bytes; the mutant mis-sums any element
// equal to 7, so the property fails iff some element is 7. Expected
// minimum: [7], keys [1, 7].
// ---------------------------------------------------------------------

fn sumBytes(xs: []const u8, mutant: bool) u64 {
    var s: u64 = 0;
    for (xs) |x| s += if (mutant and x == 7) 0 else x;
    return s;
}

fn propT7(xs: []const u8, mutant: bool) bool {
    return sumBytes(xs, mutant) == sumBytes(xs, false);
}

fn propT7Mutant(xs: []const u8) bool {
    return propT7(xs, true);
}

fn propT7Correct(xs: []const u8) bool {
    return propT7(xs, false);
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

/// Replays `choices` for T and returns the value plus its filtered key
/// sequence (skip positions removed), arena-owned.
fn replayWithKeys(comptime T: type, arena: std.mem.Allocator, choices: []const zigprop.Choice, limits: zigprop.Limits) !struct { value: T, keys: []u64 } {
    var src = zigprop.internal.Source.initReplay(arena, choices, 100_000);
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena, limits);
    const v = try zigprop.generate(T, &ctx);
    var keys: std.ArrayList(u64) = .empty;
    for (src.recorded_keys.items, src.recorded_skip.items) |k, s| {
        if (!s) try keys.append(arena, k);
    }
    return .{ .value = v, .keys = keys.items };
}

/// Shrinks a confirmed failing sequence with an internal pass mask
/// (the T6/T7 ablations, measurement only). The initial keys, skips
/// and spans come from replaying the sequence, which is exactly what
/// the runner hands the shrinker. Returns the filtered keys of the
/// shrunk sequence (arena-owned) and the shrink statistics.
fn shrinkMasked(comptime T: type, arena: std.mem.Allocator, property: *const fn (T) bool, limits: zigprop.Limits, choices: []const zigprop.Choice, mask: zigprop.internal.ShrinkPassMask) !struct { keys: []u64, evaluations: usize, outcome: zigprop.ShrinkOutcome } {
    var src = zigprop.internal.Source.initReplay(arena, choices, 100_000);
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena, limits);
    _ = try zigprop.generate(T, &ctx);
    const r = try zigprop.internal.shrinkSpanned(arena, T, null, property, limits, 2000, src.recorded.items, src.recorded_keys.items, src.recorded_skip.items, src.recorded_spans.items, .{ .passes = mask });
    const rep = try replayWithKeys(T, arena, r.choices, limits);
    return .{ .keys = rep.keys, .evaluations = r.evaluations, .outcome = r.outcome };
}

fn treeDesc(buf: []u8, t: Tree) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeTree(&w, t) catch return "(long)";
    return w.buffered();
}

fn writeTree(w: *std.Io.Writer, t: Tree) !void {
    try w.print("{{{d},[", .{t.value});
    for (t.kids, 0..) |k, i| {
        if (i > 0) try w.writeAll(",");
        try writeTree(w, k);
    }
    try w.writeAll("]}");
}

fn replayU32(allocator: std.mem.Allocator, choices: []const zigprop.Choice) !u32 {
    var src = zigprop.internal.Source.initReplay(allocator, choices, 100_000);
    defer src.deinit();
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, allocator, .{});
    return zigprop.generate(u32, &ctx);
}

fn replayF32(allocator: std.mem.Allocator, choices: []const zigprop.Choice) !f32 {
    var src = zigprop.internal.Source.initReplay(allocator, choices, 100_000);
    defer src.deinit();
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, allocator, .{});
    return zigprop.generate(f32, &ctx);
}

fn replayValue(allocator: std.mem.Allocator, choices: []const zigprop.Choice) !Value {
    var src = zigprop.internal.Source.initReplay(allocator, choices, 100_000);
    defer src.deinit();
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, allocator, .{});
    return zigprop.generate(Value, &ctx);
}

fn filteredKeyLen(src: *zigprop.internal.Source) usize {
    var n: usize = 0;
    for (src.recorded_skip.items) |skip| {
        if (!skip) n += 1;
    }
    return n;
}

fn replayRuns(allocator: std.mem.Allocator, choices: []const zigprop.Choice) ![]const Run {
    var src = zigprop.internal.Source.initReplay(allocator, choices, 100_000);
    defer src.deinit();
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, allocator, .{});
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
                    seed,                                     f.origin.random.attempt_index + 1, shrunk, if (exact) " (exact)" else "", f.shrink_evaluations,
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
                    seed,                    f.origin.random.attempt_index + 1, shrunk.len, shrunk[0].len, if (exact) " (exact)" else "", f.shrink_evaluations,
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
                    seed,                                 f.origin.random.attempt_index + 1, sbits, if (is_exact) "EXACT (rank 2)" else (if (is_sub) "subnormal" else "other"), f.shrink_evaluations,
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
    // Kept for T9's gate (2): per-seed shrunk choices identical to T4's.
    var t4_shrunk: [10]?[]zigprop.Choice = @splat(null);
    defer for (t4_shrunk) |s| if (s) |c| allocator.free(c);
    for (0..10) |seed| {
        var report = try zigprop.check(allocator, Value, propValueMutant, .{ .seed = seed, .max_cases = 200 });
        defer report.deinit();
        // Hand loop: raw generation without shrinking, same budget.
        var hand_found = false;
        var hand_best_keys: usize = std.math.maxInt(usize);
        for (0..200) |attempt| {
            var src = zigprop.internal.Source.initRandom(allocator, zigprop.internal.deriveSeed(seed, attempt), 100_000);
            defer src.deinit();
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var ctx_state: zigprop.internal.GenState = undefined;
            var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena.allocator(), .{});
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
                t4_shrunk[seed] = try allocator.dupe(zigprop.Choice, f.shrunk_choices);
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const shrunk = try replayValue(arena.allocator(), f.shrunk_choices);
                const exact = isExpectedT4Minimum(shrunk);
                if (exact) t4_exact += 1;
                out.print("{d:>4} | cases {d}, shrunk {s}, evals {d} | hand: {s}, best keys {d}\n", .{
                    seed,                                 f.origin.random.attempt_index + 1, if (exact) "list[int 0, int 0, int 0] (exact)" else "other shape", f.shrink_evaluations,
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

    // ---------------- T6 ----------------
    out.print("\n== T6 tree subtree promotion (mutant: a node with value 7 is miscounted) ==\n", .{});
    out.print("seed | v0.3: cases, root=7 originally, shrunk, evals, outcome | P6 off (measurement): keys len, evals\n", .{});
    var t6_found: usize = 0;
    var t6_min: usize = 0;
    var t6_ctl: usize = 0;
    var t6_root7: usize = 0;
    var t6_exhausted: usize = 0;
    var t6_p6off_min: usize = 0;
    var t6_evals_total: usize = 0;
    for (0..10) |seed| {
        var r = try zigprop.check(allocator, Tree, propT6Mutant, .{ .seed = seed, .max_cases = 200, .limits = t6_limits });
        defer r.deinit();
        switch (r) {
            .failed => |f| {
                t6_found += 1;
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const orig = try replayWithKeys(Tree, a, f.choices, t6_limits);
                const rep = try replayWithKeys(Tree, a, f.shrunk_choices, t6_limits);
                const minimal = std.mem.eql(u64, rep.keys, &.{ 14, 0 });
                if (minimal) t6_min += 1;
                const root7 = orig.value.value == 7;
                if (root7) t6_root7 += 1;
                if (f.shrink_outcome == .budget_exhausted) t6_exhausted += 1;
                t6_evals_total += f.shrink_evaluations;
                const off = try shrinkMasked(Tree, a, propT6Mutant, t6_limits, f.choices, .{ .p6 = false });
                const off_min = std.mem.eql(u64, off.keys, &.{ 14, 0 });
                if (off_min) t6_p6off_min += 1;
                var buf: [256]u8 = undefined;
                out.print("{d:>4} | cases {d}, root7 {}, shrunk {s}{s}, evals {d}, {s} | P6 off: keys {d}{s}, evals {d}\n", .{
                    seed,         f.origin.random.attempt_index + 1, root7,           treeDesc(&buf, rep.value), if (minimal) " (minimal)" else "", f.shrink_evaluations, @tagName(f.shrink_outcome),
                    off.keys.len, if (off_min) " (minimal)" else "", off.evaluations,
                });
            },
            else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(r)) }),
        }
        var c = try zigprop.check(allocator, Tree, propT6Correct, .{ .seed = seed, .max_cases = 200, .limits = t6_limits });
        defer c.deinit();
        if (std.meta.activeTag(c) == .passed) t6_ctl += 1;
    }
    out.print("T6: discovered {d}/10, minimal {{7,[]}} {d}/10, control passed {d}/10\n", .{ t6_found, t6_min, t6_ctl });
    out.print("T6 measurements: original root=7 {d}, budget exhausted {d}, total evals {d}; P6 off minimal {d}/{d}; v0.2.1 (M0-e): found 10/10, minimal 0/10\n", .{ t6_root7, t6_exhausted, t6_evals_total, t6_p6off_min, t6_found });
    out.print("T6 criterion (>=8 discovered AND >=8 minimal, control 10/10): {s}\n", .{
        if (t6_found >= 8 and t6_min >= 8 and t6_ctl == 10) "MET" else "NOT MET",
    });

    // ---------------- T7 ----------------
    out.print("\n== T7 slice element deletion (mutant: an element 7 is mis-summed) ==\n", .{});
    out.print("seed | v0.3: cases, original len, first=7, shrunk, evals, outcome | P5 off (measurement): keys, evals\n", .{});
    var t7_found: usize = 0;
    var t7_min: usize = 0;
    var t7_ctl: usize = 0;
    var t7_first7: usize = 0;
    var t7_exhausted: usize = 0;
    var t7_p5off_min: usize = 0;
    var t7_evals_total: usize = 0;
    for (0..10) |seed| {
        var r = try zigprop.check(allocator, []const u8, propT7Mutant, .{ .seed = seed, .max_cases = 200 });
        defer r.deinit();
        switch (r) {
            .failed => |f| {
                t7_found += 1;
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const orig = try replayWithKeys([]const u8, a, f.choices, .{});
                const rep = try replayWithKeys([]const u8, a, f.shrunk_choices, .{});
                const minimal = std.mem.eql(u64, rep.keys, &.{ 1, 7 });
                if (minimal) t7_min += 1;
                const first7 = orig.value.len > 0 and orig.value[0] == 7;
                if (first7) t7_first7 += 1;
                if (f.shrink_outcome == .budget_exhausted) t7_exhausted += 1;
                t7_evals_total += f.shrink_evaluations;
                const off = try shrinkMasked([]const u8, a, propT7Mutant, .{}, f.choices, .{ .p5 = false });
                const off_min = std.mem.eql(u64, off.keys, &.{ 1, 7 });
                if (off_min) t7_p5off_min += 1;
                out.print("{d:>4} | cases {d}, len {d}, first7 {}, shrunk {any}{s}, evals {d}, {s} | P5 off: keys {any}{s}, evals {d}\n", .{
                    seed,     f.origin.random.attempt_index + 1, orig.value.len,  first7, rep.value, if (minimal) " (minimal)" else "", f.shrink_evaluations, @tagName(f.shrink_outcome),
                    off.keys, if (off_min) " (minimal)" else "", off.evaluations,
                });
            },
            else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(r)) }),
        }
        var c = try zigprop.check(allocator, []const u8, propT7Correct, .{ .seed = seed, .max_cases = 200 });
        defer c.deinit();
        if (std.meta.activeTag(c) == .passed) t7_ctl += 1;
    }
    out.print("T7: discovered {d}/10, minimal [7] {d}/10, control passed {d}/10\n", .{ t7_found, t7_min, t7_ctl });
    out.print("T7 measurements: original first=7 {d}, budget exhausted {d}, total evals {d}; P5 off minimal {d}/{d}; v0.2.1 (M0-e): found 10/10, minimal 8/10\n", .{ t7_first7, t7_exhausted, t7_evals_total, t7_p5off_min, t7_found });
    out.print("T7 criterion (>=8 discovered AND >=8 minimal [7], control 10/10): {s}\n", .{
        if (t7_found >= 8 and t7_min >= 8 and t7_ctl == 10) "MET" else "NOT MET",
    });

    // ---------------- T9 ----------------
    out.print("\n== T9 T4 through checkWith (Ctx = codec, case.allocator, no globals) ==\n", .{});
    out.print("seed | cases, shrunk shape, evals, shrunk choices == T4's\n", .{});
    var t9_found: usize = 0;
    var t9_exact: usize = 0;
    var t9_same: usize = 0;
    var t9_ctl: usize = 0;
    var t9_leaks: usize = 0;
    var t9_ctl_leaks: usize = 0;
    const truncating: Codec = .{ .mode = .truncate };
    const correct: Codec = .{ .mode = .correct };
    for (0..10) |seed| {
        var dbg: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        {
            const gpa = dbg.allocator();
            var r = try zigprop.checkWith(gpa, Value, *const Codec, &truncating, null, propT9, .{ .seed = seed, .max_cases = 200 });
            defer r.deinit();
            switch (r) {
                .failed => |f| {
                    t9_found += 1;
                    var arena = std.heap.ArenaAllocator.init(gpa);
                    defer arena.deinit();
                    const shrunk = try replayValue(arena.allocator(), f.shrunk_choices);
                    const exact = isExpectedT4Minimum(shrunk);
                    if (exact) t9_exact += 1;
                    const same = if (t4_shrunk[seed]) |c| std.mem.eql(u8, std.mem.sliceAsBytes(c), std.mem.sliceAsBytes(f.shrunk_choices)) else false;
                    if (same) t9_same += 1;
                    out.print("{d:>4} | cases {d}, shrunk {s}, evals {d}, same as T4: {}\n", .{
                        seed, f.origin.random.attempt_index + 1, if (exact) "list[int 0, int 0, int 0] (exact)" else "other shape", f.shrink_evaluations, same,
                    });
                },
                else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(r)) }),
            }
        }
        if (dbg.deinit() == .leak) t9_leaks += 1;

        var dbg_c: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        {
            var c = try zigprop.checkWith(dbg_c.allocator(), Value, *const Codec, &correct, null, propT9, .{ .seed = seed, .max_cases = 200 });
            defer c.deinit();
            if (std.meta.activeTag(c) == .passed) t9_ctl += 1;
        }
        if (dbg_c.deinit() == .leak) t9_ctl_leaks += 1;
    }
    out.print("T9: discovered {d}/10, exact list[int 0 x3] {d}/10, shrunk choices identical to T4 {d}/{d}, leaking seeds {d}, control passed {d}/10 (leaking seeds {d}); container-level T9 buffers: none (code review)\n", .{ t9_found, t9_exact, t9_same, t4_discovered, t9_leaks, t9_ctl, t9_ctl_leaks });
    out.print("T9 criterion (>=8 discovered AND >=8 exact AND identical to T4 on every seed AND 0 leaks, control 10/10): {s}\n", .{
        if (t9_found >= 8 and t9_exact >= 8 and t9_same == t4_discovered and t9_found == t4_discovered and t9_leaks == 0 and t9_ctl == 10 and t9_ctl_leaks == 0) "MET" else "NOT MET",
    });

    // ---------------- T9e ----------------
    out.print("\n== T9e error path (decoder returns error.UnexpectedLength on lists of 3+) ==\n", .{});
    out.print("seed | cases, failure, shrunk shape, evals | hook: acceptances, kind violations\n", .{});
    var t9e_found: usize = 0;
    var t9e_kind: usize = 0;
    var t9e_exact: usize = 0;
    var t9e_violations: usize = 0;
    var t9e_accepts: usize = 0;
    var t9e_leaks: usize = 0;
    const rejecting: Codec = .{ .mode = .reject };
    const expected_failure: zigprop.Failure = .{ .returned_error = error.UnexpectedLength };
    for (0..10) |seed| {
        var dbg: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        {
            const gpa = dbg.allocator();
            var r = try zigprop.checkWith(gpa, Value, *const Codec, &rejecting, null, propT9, .{ .seed = seed, .max_cases = 200 });
            defer r.deinit();
            switch (r) {
                .failed => |f| {
                    t9e_found += 1;
                    const kind_ok = f.failure.eql(expected_failure);
                    if (kind_ok) t9e_kind += 1;
                    var arena = std.heap.ArenaAllocator.init(gpa);
                    defer arena.deinit();
                    const a = arena.allocator();
                    const shrunk = try replayValue(a, f.shrunk_choices);
                    const exact = isExpectedT4Minimum(shrunk);
                    if (exact) t9e_exact += 1;
                    // Re-run the shrink from the same failing sequence
                    // with the internal acceptance hook (§3.9).
                    var src = zigprop.internal.Source.initReplay(a, f.choices, 100_000);
                    var st: zigprop.internal.GenState = undefined;
                    var gctx = zigprop.internal.genContextForTest(&st, &src, a, .{});
                    _ = try zigprop.generate(Value, &gctx);
                    var mon: KindMonitor = .{ .expected = expected_failure };
                    const sr = try zigprop.internal.shrinkWith(a, Value, *const Codec, &rejecting, null, propT9, f.failure, .{}, 2000, src.recorded.items, src.recorded_keys.items, src.recorded_skip.items, src.recorded_spans.items, .{ .on_accept = mon.hook() });
                    const same = std.mem.eql(u8, std.mem.sliceAsBytes(sr.choices), std.mem.sliceAsBytes(f.shrunk_choices));
                    t9e_violations += mon.violations;
                    t9e_accepts += mon.accepts;
                    out.print("{d:>4} | cases {d}, {s}, shrunk {s}, evals {d} | hook: {d} acceptances, {d} violations (hook rerun reproduces: {})\n", .{
                        seed,
                        f.origin.random.attempt_index + 1,
                        switch (f.failure) {
                            .returned_false => "returned false",
                            .returned_error => |e| @errorName(e),
                        },
                        if (exact) "list[int 0, int 0, int 0] (exact)" else "other shape",
                        f.shrink_evaluations,
                        mon.accepts,
                        mon.violations,
                        same,
                    });
                },
                else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(r)) }),
            }
        }
        if (dbg.deinit() == .leak) t9e_leaks += 1;
    }
    out.print("T9e: discovered {d}/10, failure = returned_error(UnexpectedLength) {d}/{d}, kind kept on {d} acceptances with {d} violations, exact list[int 0 x3] {d}/10 (measurement), leaking seeds {d}; control: T9's correct codec\n", .{ t9e_found, t9e_kind, t9e_found, t9e_accepts, t9e_violations, t9e_exact, t9e_leaks });
    out.print("T9e criterion (>=8 discovered AND kind reported on every discovery AND 0 kind violations AND 0 leaks): {s}\n", .{
        if (t9e_found >= 8 and t9e_kind == t9e_found and t9e_violations == 0 and t9e_leaks == 0) "MET" else "NOT MET",
    });
}
