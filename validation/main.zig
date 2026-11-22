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
//! T5 / T5s mid-range varint over u64 / zigzag i64 (v0.3 design
//! §8.2): gates found >= 8/10 AND minimal (2^21 / 2^20) >= 8/10,
//! controls 10/10. T5-F (ordinary f64 values) is a measurement.
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
// T5 / T5s: mid-range varint (design v0.3 §8.2). u64 LEB128 (max 10
// bytes); the mutant decoder ignores the 4th byte when the encoding is
// exactly 4 bytes long, so it fails iff x in [2^21, 2^28). Expected
// minimum: 2^21 (T5) and, through protobuf zigzag of i64, rank 2^21,
// i.e. x = 2^20 (T5s).
// ---------------------------------------------------------------------

fn leb128Encode(x: u64, buf: *[10]u8) []const u8 {
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

fn leb128Decode(bytes: []const u8, mutant: bool) u64 {
    var result: u64 = 0;
    var shift: u7 = 0;
    for (bytes, 0..) |byte, i| {
        const ignore = mutant and bytes.len == 4 and i == 3;
        if (!ignore) result |= @as(u64, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

fn propT5(x: u64, mutant: bool) bool {
    var buf: [10]u8 = undefined;
    return leb128Decode(leb128Encode(x, &buf), mutant) == x;
}

fn propT5Mutant(x: u64) bool {
    return propT5(x, true);
}

fn propT5Correct(x: u64) bool {
    return propT5(x, false);
}

/// protobuf zigzag: 0 -> 0, -1 -> 1, 1 -> 2 (zigprop's rank order).
fn zigzag(x: i64) u64 {
    return @bitCast((x << 1) ^ (x >> 63));
}

fn unzigzag(z: u64) i64 {
    return @as(i64, @bitCast(z >> 1)) ^ -@as(i64, @bitCast(z & 1));
}

fn propT5s(x: i64, mutant: bool) bool {
    var buf: [10]u8 = undefined;
    return unzigzag(leb128Decode(leb128Encode(zigzag(x), &buf), mutant)) == x;
}

fn propT5sMutant(x: i64) bool {
    return propT5s(x, true);
}

fn propT5sCorrect(x: i64) bool {
    return propT5s(x, false);
}

/// Counts P4 (lateral) acceptances during a shrink (T5 measurement).
const P4Counter = struct {
    lateral: usize = 0,

    fn hook(self: *P4Counter) zigprop.internal.AcceptHook {
        return .{ .context = self, .call = call };
    }

    fn call(context: *anyopaque, e: zigprop.internal.AcceptEvent) void {
        const self: *P4Counter = @ptrCast(@alignCast(context));
        if (e.lateral) self.lateral += 1;
    }
};

/// Re-runs the shrink of `choices` with the P4 counter attached and
/// returns the number of P4 acceptances (measurement only).
fn countP4(comptime T: type, arena: std.mem.Allocator, property: *const fn (T) bool, choices: []const zigprop.Choice) !usize {
    var src = zigprop.internal.Source.initReplay(arena, choices, 100_000);
    var st: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&st, &src, arena, .{});
    _ = try zigprop.generate(T, &ctx);
    var counter: P4Counter = .{};
    _ = try zigprop.internal.shrinkSpanned(arena, T, null, property, .{}, 2000, src.recorded.items, src.recorded_keys.items, src.recorded_skip.items, src.recorded_spans.items, .{ .on_accept = counter.hook() });
    return counter.lateral;
}

/// T5-F (measurement only): f64 over seeds 0..9 x attempts 0..199;
/// the share with an unbiased exponent in [-20, 20] and non-zero low
/// 20 mantissa bits.
fn t5fOrdinary(allocator: std.mem.Allocator, seeds: Seeds) !usize {
    var hits: usize = 0;
    for (seeds.from..seeds.to + 1) |seed| {
        for (0..200) |attempt| {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var src = zigprop.internal.Source.initRandom(arena.allocator(), zigprop.internal.deriveSeed(seed, attempt), 100_000);
            var st: zigprop.internal.GenState = undefined;
            var ctx = zigprop.internal.genContextForTest(&st, &src, arena.allocator(), .{});
            const x = try zigprop.generate(f64, &ctx);
            const bits: u64 = @bitCast(x);
            const e: i64 = @as(i64, @intCast((bits >> 52) & 0x7ff)) - 1023;
            if (e >= -20 and e <= 20 and (bits & 0xfffff) != 0) hits += 1;
        }
    }
    return hits;
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
// T8: stale detection (design v0.3 §8.2). Entries are printed by
// Report.Failed.regressionEntry for T1 (u32), T6 (Tree) and T7
// ([]const u8) failures on seeds 0..9, parsed back from that text, and
// replayed under the changes of rows (a)-(j). Row (f)'s "variant
// added" needs a union-typed entry, which T1/T6/T7 cannot provide: it
// uses T4 (Value) failures (a deviation from the registered entry
// sources, reported). Row (j) needs a custom-generator entry: T1's
// type and mutant through a custom single-draw generator.
// ---------------------------------------------------------------------

fn hasSevenGeneric(comptime TT: type, comptime vname: []const u8, comptime kname: []const u8, t: TT) bool {
    if (@field(t, vname) == 7) return true;
    for (@field(t, kname)) |k| {
        if (hasSevenGeneric(TT, vname, kname, k)) return true;
    }
    return false;
}

/// Tree with a type rename only (row g).
const TreeRenamed = struct { value: i64, kids: []const TreeRenamed };
/// Tree with its fields renamed (row g).
const TreeFieldsRenamed = struct { val: i64, children: []const TreeFieldsRenamed };
/// Tree with its fields reordered (row f).
const TreeReordered = struct { kids: []const TreeReordered, value: i64 };

fn propTreeRenamedMutant(t: TreeRenamed) bool {
    return !hasSevenGeneric(TreeRenamed, "value", "kids", t);
}

fn propTreeFieldsRenamedMutant(t: TreeFieldsRenamed) bool {
    return !hasSevenGeneric(TreeFieldsRenamed, "val", "children", t);
}

fn propTreeReorderedMutant(t: TreeReordered) bool {
    return !hasSevenGeneric(TreeReordered, "value", "kids", t);
}

/// u32 widened to u64 (row f); fails exactly where T1's mutant does.
fn propU64Mutant(x: u64) bool {
    return x < (1 << 28);
}

/// Value with one more variant (row f).
const ValueMore = union(enum) { int: i64, str: []const u8, list: []const ValueMore, flag: bool };

fn valueMoreHasLongList(v: ValueMore) bool {
    switch (v) {
        .list => |items| {
            if (items.len >= 3) return true;
            for (items) |item| {
                if (valueMoreHasLongList(item)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn propValueMoreMutant(v: ValueMore) bool {
    return !valueMoreHasLongList(v);
}

fn genU32Single(ctx: *zigprop.GenContext) anyerror!u32 {
    return @intCast(ctx.range(1 << 32));
}

/// Row (j): the same draw shape as genU32Single, a different mapping.
fn genU32Shifted(ctx: *zigprop.GenContext) anyerror!u32 {
    return @as(u32, @intCast(ctx.range(1 << 32))) ^ 0x5555;
}

/// The printed entry of a failure, parsed back from its text (what a
/// user pastes into regressions.zon). Arena-owned.
fn t8Entry(arena: std.mem.Allocator, f: *const zigprop.Report.Failed) !zigprop.Regression {
    const line = try f.regressionEntry(arena, "t8");
    const text = try std.fmt.allocPrintSentinel(arena, ".{{ .version = 1, .entries = .{{ {s} }} }}", .{line}, 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const file = try std.zon.parse.fromSlice(zigprop.RegressionFile, .{ .gpa = arena, .arena = arena, .source = text, .diagnostics = &diag });
    if (file.entries.len != 1 or file.entries[0].fingerprint == null) return error.UnexpectedEntry;
    return file.entries[0];
}

/// What one T8 replay produced.
const T8Outcome = struct {
    /// The report is a failure that came from the entry.
    failed_from_entry: bool = false,
    origin_stale: ?zigprop.StaleReason = null,
    passed: usize = 0,
    unverified: usize = 0,
    stale_count: usize = 0,
    stale: ?zigprop.StaleEntry = null,
};

fn t8Replay(comptime T: type, gpa: std.mem.Allocator, generator: ?zigprop.Generator(T), property: *const fn (T) bool, entry: zigprop.Regression, limits: zigprop.Limits) !T8Outcome {
    const entries = [_]zigprop.Regression{entry};
    const cfg: zigprop.Config = .{ .seed = 1234, .max_cases = 1, .limits = limits, .regressions = &entries, .regression_id = entry.id };
    var r = if (generator) |g| try zigprop.checkCustom(gpa, T, g, property, cfg) else try zigprop.check(gpa, T, property, cfg);
    defer r.deinit();
    const summary = switch (r) {
        .passed => |p| p.regressions,
        .gave_up => |g| g.regressions,
        .failed => |f| f.regressions,
    };
    var out: T8Outcome = .{ .passed = summary.passed, .unverified = summary.unverified, .stale_count = summary.stale.len };
    if (summary.stale.len > 0) out.stale = summary.stale[0];
    if (r == .failed and r.failed.origin == .regression) {
        out.failed_from_entry = true;
        out.origin_stale = r.failed.origin.regression.stale;
    }
    return out;
}

fn t8Stale(o: T8Outcome, reason: zigprop.StaleReason) bool {
    return o.stale_count == 1 and o.stale.?.reason == reason and !o.failed_from_entry;
}

fn withSuffix(arena: std.mem.Allocator, e: zigprop.Regression) !zigprop.Regression {
    var out = e;
    const c = try arena.alloc(u64, e.choices.len + 1);
    @memcpy(c[0..e.choices.len], e.choices);
    c[e.choices.len] = 0;
    out.choices = c;
    return out;
}

fn withoutFingerprint(e: zigprop.Regression) zigprop.Regression {
    var out = e;
    out.fingerprint = null;
    return out;
}

const T8Row = struct {
    name: []const u8,
    ok: usize = 0,
    total: usize = 0,
    /// The row expects the change to be missed (row j).
    known_miss: bool = false,

    fn add(self: *T8Row, ok: bool) void {
        self.total += 1;
        if (ok) self.ok += 1;
    }
};

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
// v0.4 targets (design v0.4 §4). Their output goes after T8's, under
// `== v0.4 targets ==`, so the T1-T9e prefix stays byte-identical
// (D59). Gates are the values frozen after M0 (Amendment A-M0).
// ---------------------------------------------------------------------

// T14: tail-dependent verdict (P5 discrimination, design v0.4 §4 T14).
const T14E = struct { a: u8, flag: bool };

/// Sum of the `a` fields. The mutant mis-sums every a == 7 element,
/// unless the last element's a is 0 (the trailing zero hides the bug).
fn t14Sum(xs: []const T14E, mutant: bool) u64 {
    const hidden = xs.len > 0 and xs[xs.len - 1].a == 0;
    var s: u64 = 0;
    for (xs) |x| s += if (mutant and !hidden and x.a == 7) 0 else x.a;
    return s;
}

fn propT14Mutant(xs: []const T14E) bool {
    return t14Sum(xs, true) == t14Sum(xs, false);
}

fn propT14Correct(xs: []const T14E) bool {
    return t14Sum(xs, false) == t14Sum(xs, false);
}

/// The P5-off stop the design predicts for first-7 position f:
/// keys [f+1, 0,0 (f times), 7, 0].
fn t14P5OffShape(arena: std.mem.Allocator, f: usize) ![]u64 {
    const keys = try arena.alloc(u64, 1 + 2 * (f + 1));
    @memset(keys, 0);
    keys[0] = f + 1;
    keys[1 + 2 * f] = 7;
    return keys;
}

fn runT14(allocator: std.mem.Allocator, seeds: Seeds) !void {
    const out = std.debug;
    out.print("\n== T14 tail-dependent verdict ([]const struct {{ a: u8, flag: bool }}; mutant: a 7 is mis-summed unless the last a is 0) ==\n", .{});
    out.print("seed | P5 on: cases, f, shrunk keys, evals, outcome | P5 off (measurement): keys, evals, f-shape\n", .{});
    var found: usize = 0;
    var minimal: usize = 0;
    var off_min: usize = 0;
    var off_shape: usize = 0;
    var ctl: usize = 0;
    var evals: usize = 0;
    var off_evals: usize = 0;
    for (seeds.from..seeds.to + 1) |seed| {
        var r = try zigprop.check(allocator, []const T14E, propT14Mutant, .{ .seed = seed, .max_cases = 200 });
        defer r.deinit();
        switch (r) {
            .failed => |f| {
                found += 1;
                evals += f.shrink_evaluations;
                var arena_state = std.heap.ArenaAllocator.init(allocator);
                defer arena_state.deinit();
                const a = arena_state.allocator();
                const orig = try replayWithKeys([]const T14E, a, f.choices, .{});
                var first7: usize = orig.value.len;
                for (orig.value, 0..) |x, i| {
                    if (x.a == 7) {
                        first7 = i;
                        break;
                    }
                }
                const rep = try replayWithKeys([]const T14E, a, f.shrunk_choices, .{});
                const is_min = std.mem.eql(u64, rep.keys, &.{ 1, 7, 0 });
                if (is_min) minimal += 1;
                const off = try shrinkMasked([]const T14E, a, propT14Mutant, .{}, f.choices, .{ .p5 = false });
                const off_is_min = std.mem.eql(u64, off.keys, &.{ 1, 7, 0 });
                if (off_is_min) off_min += 1;
                const shape = std.mem.eql(u64, off.keys, try t14P5OffShape(a, first7));
                if (shape) off_shape += 1;
                off_evals += off.evaluations;
                out.print("{d:>4} | cases {d}, f {d}, shrunk {any}{s}, evals {d}, {s} | P5 off: keys len {d}{s}, evals {d}, f-shape {s}\n", .{
                    seed,         f.origin.random.attempt_index + 1,    first7,          rep.keys,                           if (is_min) " (minimal)" else "", f.shrink_evaluations, @tagName(f.shrink_outcome),
                    off.keys.len, if (off_is_min) " (minimal)" else "", off.evaluations, if (shape) "match" else "no match",
                });
            },
            else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(r)) }),
        }
        var c = try zigprop.check(allocator, []const T14E, propT14Correct, .{ .seed = seed, .max_cases = 200 });
        defer c.deinit();
        if (std.meta.activeTag(c) == .passed) ctl += 1;
    }
    const n = seeds.count();
    out.print("T14: discovered {d}/{d}, minimal [1,7,0] {d}/{d}, control passed {d}/{d}\n", .{ found, n, minimal, found, ctl, n });
    out.print("T14 measurements: total evals {d}; P5 off: minimal {d}/{d}, f-shape match {d}/{d}, total evals {d}; M0 (v0.3.1): P5 off minimal 0/10, f-shape 6/10\n", .{ evals, off_min, found, off_shape, found, off_evals });
    out.print("T14 criterion (>=8 discovered AND >=8 minimal, control 10/10; P5-off <= 4/10 was the M0 condition): {s}\n", .{if (found >= 8 and minimal >= 8 and ctl == n) "MET" else "NOT MET"});
}

// T11: interactive draws whose type and count depend on an earlier
// draw (design v0.4 §4 T11). The isolation control makes the same
// draws in a custom generator (what v0.3.1 can write); its per-seed
// shrunk choices and evaluation counts were recorded at M0.
const T11Width = enum { wide, narrow };
const T11V = struct { w: T11Width, xs: []const u16 };

/// M0 reference (HEAD 1cab5f7, research note §4.3): per-seed shrink
/// evaluations of the control; every seed shrank to t11_m0_choices.
const t11_m0_evals = [_]usize{ 98, 89, 101, 101, 105, 92, 79, 119, 98, 115 };
const t11_m0_choices = [_]zigprop.Choice{ .{ .bound = 2, .value = 0 }, .{ .bound = 33, .value = 1 }, .{ .bound = 4, .value = 3 }, .{ .bound = 65536, .value = 1000 } };

fn t11Widen(allocator: std.mem.Allocator, n: []const u4) ![]const u16 {
    const ws = try allocator.alloc(u16, n.len);
    for (n, ws) |x, *y| y.* = x;
    return ws;
}

fn genT11(_: u32, g: *zigprop.GenContext) anyerror!T11V {
    const w = try g.generate(T11Width);
    const xs: []const u16 = switch (w) {
        .wide => try g.generate([]const u16),
        .narrow => try t11Widen(g.allocator, try g.generate([]const u4)),
    };
    return .{ .w = w, .xs = xs };
}

fn t11Sum(xs: []const u16) u32 {
    var s: u32 = 0;
    for (xs) |x| s += x;
    return s;
}

fn propT11Generator(limit: u32, _: *zigprop.Case, v: T11V) anyerror!bool {
    return t11Sum(v.xs) < limit;
}

/// The interactive form: T = void, every draw inside the property.
fn propT11(limit: u32, case: *zigprop.Case, _: void) anyerror!bool {
    const w = try case.generate(T11Width);
    const xs: []const u16 = switch (w) {
        .wide => try case.generate([]const u16),
        .narrow => try t11Widen(case.allocator, try case.generate([]const u4)),
    };
    return t11Sum(xs) < limit;
}

fn choicesEql(a: []const zigprop.Choice, b: []const zigprop.Choice) bool {
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

/// The value and filtered keys of a T11 sequence, replayed through the
/// generator form (the draws are the same in both forms).
fn replayT11(arena: std.mem.Allocator, choices: []const zigprop.Choice) !struct { value: T11V, keys: []u64 } {
    var src = zigprop.internal.Source.initReplay(arena, choices, 100_000);
    var st: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&st, &src, arena, .{});
    const v = try genT11(0, &ctx);
    var keys: std.ArrayList(u64) = .empty;
    for (src.recorded_keys.items, src.recorded_skip.items) |k, s| {
        if (!s) try keys.append(arena, k);
    }
    return .{ .value = v, .keys = keys.items };
}

fn runT11(allocator: std.mem.Allocator, seeds: Seeds) !void {
    const out = std.debug;
    out.print("\n== T11 interactive draws (T = void; draw Width, then []const u16 or []const u4; fails iff sum >= 1000) ==\n", .{});
    out.print("seed | interactive: cases, failure, shrunk keys, evals | generator form: evals, same shrunk choices and evals | entry replay\n", .{});
    var found: usize = 0;
    var minimal: usize = 0;
    var same: usize = 0;
    var control_m0: usize = 0;
    var replayed: usize = 0;
    var ctl: usize = 0;
    var evals: usize = 0;
    for (seeds.from..seeds.to + 1) |seed| {
        const cfg: zigprop.Config = .{ .seed = seed, .max_cases = 200 };
        var r = try zigprop.checkWith(allocator, void, u32, 1000, null, propT11, cfg);
        defer r.deinit();
        var g = try zigprop.checkWith(allocator, T11V, u32, 1000, genT11, propT11Generator, cfg);
        defer g.deinit();
        if (g == .failed and seeds.isDefault() and seed < t11_m0_evals.len and
            g.failed.shrink_evaluations == t11_m0_evals[seed] and choicesEql(g.failed.shrunk_choices, &t11_m0_choices))
            control_m0 += 1;
        switch (r) {
            .failed => |f| {
                found += 1;
                evals += f.shrink_evaluations;
                var arena_state = std.heap.ArenaAllocator.init(allocator);
                defer arena_state.deinit();
                const a = arena_state.allocator();
                const rep = try replayT11(a, f.shrunk_choices);
                const is_min = std.mem.eql(u64, rep.keys, &.{ 0, 1, 1000 });
                if (is_min) minimal += 1;
                const is_same = g == .failed and choicesEql(f.shrunk_choices, g.failed.shrunk_choices) and
                    f.shrink_evaluations == g.failed.shrink_evaluations;
                if (is_same) same += 1;
                // Gate (4): the printed entry, parsed back, replays to the
                // same failure.
                const entry = try t8Entry(a, &f);
                const entries = [_]zigprop.Regression{entry};
                var e = try zigprop.checkWith(allocator, void, u32, 1000, null, propT11, .{ .seed = 1234, .max_cases = 1, .regressions = &entries, .regression_id = entry.id });
                defer e.deinit();
                const ok = e == .failed and e.failed.origin == .regression and e.failed.origin.regression.stale == null and
                    e.failed.failure.eql(f.failure);
                if (ok) replayed += 1;
                out.print("{d:>4} | cases {d}, {s}, keys {any}{s}, evals {d} | generator: evals {d}, same {} | entry fails again: {}\n", .{
                    seed,                             f.origin.random.attempt_index + 1, if (f.failure == .returned_false) "returned_false" else "returned_error", rep.keys,
                    if (is_min) " (minimal)" else "", f.shrink_evaluations,              if (g == .failed) g.failed.shrink_evaluations else 0,                     is_same,
                    ok,
                });
            },
            else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(r)) }),
        }
        var c = try zigprop.checkWith(allocator, void, u32, 1 << 20, null, propT11, cfg);
        defer c.deinit();
        if (std.meta.activeTag(c) == .passed) ctl += 1;
    }
    const n = seeds.count();
    out.print("T11: discovered {d}/{d}, minimal [0,1,1000] {d}/{d}, shrunk choices and evals identical to the generator form {d}/{d}, entry replays fail with the same kind {d}/{d}, control (sum >= 2^20) passed {d}/{d}\n", .{ found, n, minimal, found, same, n, replayed, found, ctl, n });
    out.print("T11 measurements: total evals {d}; generator form reproduces the M0 reference {d}/{d}\n", .{ evals, control_m0, n });
    out.print("T11 criterion (gates 1, 2, 4: >=8 discovered AND >=8 minimal, identical to the generator form 10/10, entry replays 10/10, control 10/10; gates 3, 5 at M5): {s}\n", .{if (found >= 8 and minimal >= 8 and same == n and replayed == n and ctl == n) "MET" else "NOT MET"});
}

// T10: model-based test of a slot map with generation-checked handles
// (design v0.4 §4 T10). SUT and model are the M0 harness's
// (research note §3); the property is the D54 recipe.
const SlotMap = struct {
    const cap = 4;
    gens: [cap]u32 = .{ 1, 1, 1, 1 },
    occupied: [cap]bool = .{ false, false, false, false },
    values: [cap]u8 = .{ 0, 0, 0, 0 },
    /// Slots ever handed out (new slots are used in order).
    used: usize = 0,
    /// LIFO free list.
    free: [cap]usize = undefined,
    free_len: usize = 0,
    /// Mutant: remove does not bump the generation.
    mutant: bool,

    fn insert(self: *SlotMap, v: u8) ?u64 {
        var slot: usize = undefined;
        if (self.free_len > 0) {
            self.free_len -= 1;
            slot = self.free[self.free_len];
        } else if (self.used < cap) {
            slot = self.used;
            self.used += 1;
        } else return null;
        self.occupied[slot] = true;
        self.values[slot] = v;
        return (@as(u64, self.gens[slot]) << 32) | slot;
    }

    fn lookup(self: *const SlotMap, h: u64) ?usize {
        const slot = h & 0xffff_ffff;
        if (slot >= self.used) return null;
        if (!self.occupied[slot] or self.gens[slot] != h >> 32) return null;
        return @intCast(slot);
    }

    fn remove(self: *SlotMap, h: u64) bool {
        const s = self.lookup(h) orelse return false;
        self.occupied[s] = false;
        if (!self.mutant) self.gens[s] += 1;
        self.free[self.free_len] = s;
        self.free_len += 1;
        return true;
    }

    fn get(self: *const SlotMap, h: u64) ?u8 {
        const s = self.lookup(h) orelse return null;
        return self.values[s];
    }
};

const SlotModel = struct {
    /// Live handles in insertion order (removal keeps the order).
    live: std.ArrayList(u64) = .empty,
    live_vals: std.ArrayList(u8) = .empty,
    /// Every handle ever issued, in issue order.
    issued: std.ArrayList(u64) = .empty,

    fn liveIndex(self: *const SlotModel, h: u64) ?usize {
        return std.mem.indexOfScalar(u64, self.live.items, h);
    }

    fn wasIssued(self: *const SlotModel, h: u64) bool {
        return std.mem.indexOfScalar(u64, self.issued.items, h) != null;
    }

    fn insert(self: *SlotModel, a: std.mem.Allocator, h: u64, v: u8) !void {
        try self.live.append(a, h);
        try self.live_vals.append(a, v);
        try self.issued.append(a, h);
    }

    fn remove(self: *SlotModel, h: u64) void {
        const i = self.liveIndex(h).?;
        _ = self.live.orderedRemove(i);
        _ = self.live_vals.orderedRemove(i);
    }

    fn get(self: *const SlotModel, h: u64) ?u8 {
        const i = self.liveIndex(h) orelse return null;
        return self.live_vals.items[i];
    }
};

const T10Cfg = struct { mutant: bool };
const T10Op = enum { insert, remove, get };

/// The v0.4 form (D54): choose an enabled operation, then draw its
/// payload against the model's state; each postcondition has its own
/// error name (D56).
fn propT10(cfg: *const T10Cfg, case: *zigprop.Case, _: void) anyerror!bool {
    const a = case.allocator;
    var sut: SlotMap = .{ .mutant = cfg.mutant };
    var model: SlotModel = .{};
    var s = case.steps(16);
    while (s.next()) {
        var en: std.EnumSet(T10Op) = .empty;
        if (model.live.items.len < SlotMap.cap) en.insert(.insert);
        if (model.live.items.len > 0) en.insert(.remove);
        if (model.issued.items.len > 0) en.insert(.get);
        switch (try case.choose(T10Op, en)) {
            .insert => {
                const v = try case.generate(u8);
                const h = sut.insert(v).?;
                if (model.wasIssued(h)) return error.HandleReused;
                try model.insert(a, h, v);
            },
            .remove => {
                const h = model.live.items[try case.index(model.live.items.len)];
                if (!sut.remove(h)) return error.RemoveMismatch;
                model.remove(h);
            },
            .get => {
                const h = model.issued.items[try case.index(model.issued.items.len)];
                if (!std.meta.eql(sut.get(h), model.get(h))) return error.GetMismatch;
            },
        }
    }
    return true;
}

// The v0.3 encodings the design compares against (§4 T10, M0 §4.2).
const T10CmdB1 = union(enum) { insert: u8, remove: u64, get: u64 };
const T10CmdB2 = union(enum) { insert: u8, remove: u8, get: u8 };
const t10_limits: zigprop.Limits = .{ .max_len = 16 };
/// M0 reference (HEAD 1cab5f7, research note §4.2): B2's per-seed
/// shrink evaluations.
const t10_m0_b2_evals = [_]usize{ 131, 153, 131, 130, 127, 143, 140, 145, 127, 147 };

fn t10Insert(sut: *SlotMap, model: *SlotModel, a: std.mem.Allocator, v: u8) !void {
    if (model.live.items.len == SlotMap.cap) return;
    const h = sut.insert(v).?;
    if (model.wasIssued(h)) return error.HandleReused;
    try model.insert(a, h, v);
}

fn t10Remove(sut: *SlotMap, model: *SlotModel, h: u64) !void {
    const expected = model.liveIndex(h) != null;
    if (sut.remove(h) != expected) return error.RemoveMismatch;
    if (expected) model.remove(h);
}

fn t10Get(sut: *SlotMap, model: *SlotModel, h: u64) !void {
    if (!std.meta.eql(sut.get(h), model.get(h))) return error.GetMismatch;
}

/// B1: blind handles; an invalid handle is a no-op for both sides.
fn propT10B1(cfg: *const T10Cfg, case: *zigprop.Case, cmds: []const T10CmdB1) anyerror!bool {
    var sut: SlotMap = .{ .mutant = cfg.mutant };
    var model: SlotModel = .{};
    for (cmds) |c| switch (c) {
        .insert => |v| try t10Insert(&sut, &model, case.allocator, v),
        .remove => |h| try t10Remove(&sut, &model, h),
        .get => |h| try t10Get(&sut, &model, h),
    };
    return true;
}

/// B2: payloads read against the state; inapplicable commands skip.
fn propT10B2(cfg: *const T10Cfg, case: *zigprop.Case, cmds: []const T10CmdB2) anyerror!bool {
    var sut: SlotMap = .{ .mutant = cfg.mutant };
    var model: SlotModel = .{};
    for (cmds) |c| switch (c) {
        .insert => |v| try t10Insert(&sut, &model, case.allocator, v),
        .remove => |idx| {
            const n = model.live.items.len;
            if (n > 0) try t10Remove(&sut, &model, model.live.items[idx % n]);
        },
        .get => |idx| {
            const n = model.issued.items.len;
            if (n > 0) try t10Get(&sut, &model, model.issued.items[idx % n]);
        },
    };
    return true;
}

fn failureName(f: zigprop.Failure) []const u8 {
    return switch (f) {
        .returned_false => "returned_false",
        .returned_error => |e| @errorName(e),
    };
}

/// The non-skipped keys of one T10 evaluation replaying `choices`,
/// with the failure it produced (null when it passed or discarded).
fn t10Replay(arena: std.mem.Allocator, cfg: *const T10Cfg, choices: []const zigprop.Choice) !struct { keys: []u64, failed: bool } {
    var src = zigprop.internal.Source.initReplay(arena, choices, 100_000);
    const r = try zigprop.internal.evaluateAttempt(arena, void, *const T10Cfg, cfg, null, propT10, &src, arena, .{}, false);
    var keys: std.ArrayList(u64) = .empty;
    for (src.recorded_keys.items, src.recorded_skip.items) |k, skip| {
        if (!skip) try keys.append(arena, k);
    }
    return .{ .keys = keys.items, .failed = r == .fail };
}

fn runT10(seeds: Seeds) !void {
    const out = std.debug;
    out.print("\n== T10 slot map with generation-checked handles (T = void; steps(16), choose Op, payload against the model; mutant: remove keeps the generation) ==\n", .{});
    out.print("seed | cases, failure, shrunk keys, evals, outcome | hook: acceptances, kind violations, rerun reproduces | P5 off (measurement): keys, evals | B2 (measurement): evals\n", .{});
    const expected_failure: zigprop.Failure = .{ .returned_error = error.HandleReused };
    const expected_keys = [_]u64{ 3, 0, 0, 1, 0, 0, 0 };
    const mutant: T10Cfg = .{ .mutant = true };
    const correct: T10Cfg = .{ .mutant = false };
    var found: usize = 0;
    var minimal: usize = 0;
    var kind_ok: usize = 0;
    var accepts: usize = 0;
    var violations: usize = 0;
    var reproduces: usize = 0;
    var leaks: usize = 0;
    var ctl: usize = 0;
    var ctl_leaks: usize = 0;
    var ctl_discards: usize = 0;
    var evals: usize = 0;
    var off_min: usize = 0;
    var off_evals: usize = 0;
    var b1_found: usize = 0;
    var b2_found: usize = 0;
    var b2_min: usize = 0;
    var b2_evals: usize = 0;
    var b2_m0: usize = 0;
    for (seeds.from..seeds.to + 1) |seed| {
        const cfg: zigprop.Config = .{ .seed = seed, .max_cases = 200 };
        var dbg: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        {
            const gpa = dbg.allocator();
            var r = try zigprop.checkWith(gpa, void, *const T10Cfg, &mutant, null, propT10, cfg);
            defer r.deinit();
            var b2 = try zigprop.checkWith(gpa, []const T10CmdB2, *const T10Cfg, &mutant, null, propT10B2, .{ .seed = seed, .max_cases = 200, .limits = t10_limits });
            defer b2.deinit();
            var b2_evals_seed: usize = 0;
            if (b2 == .failed) {
                b2_found += 1;
                b2_evals_seed = b2.failed.shrink_evaluations;
                b2_evals += b2_evals_seed;
                if (seeds.isDefault() and seed < t10_m0_b2_evals.len and b2_evals_seed == t10_m0_b2_evals[seed]) b2_m0 += 1;
                var arena_state = std.heap.ArenaAllocator.init(gpa);
                defer arena_state.deinit();
                const rep = try replayWithKeys([]const T10CmdB2, arena_state.allocator(), b2.failed.shrunk_choices, t10_limits);
                if (std.mem.eql(u64, rep.keys, &expected_keys)) b2_min += 1;
            }
            var b1 = try zigprop.checkWith(gpa, []const T10CmdB1, *const T10Cfg, &mutant, null, propT10B1, .{ .seed = seed, .max_cases = 200, .limits = t10_limits });
            defer b1.deinit();
            if (b1 == .failed) b1_found += 1;
            switch (r) {
                .failed => |f| {
                    found += 1;
                    evals += f.shrink_evaluations;
                    if (f.failure.eql(expected_failure)) kind_ok += 1;
                    var arena_state = std.heap.ArenaAllocator.init(gpa);
                    defer arena_state.deinit();
                    const a = arena_state.allocator();
                    const rep = try t10Replay(a, &mutant, f.shrunk_choices);
                    const is_min = std.mem.eql(u64, rep.keys, &expected_keys);
                    if (is_min) minimal += 1;
                    // Re-run the shrink from the confirmed failing sequence
                    // with the acceptance hook (as T9e), and with P5 off.
                    var src = zigprop.internal.Source.initReplay(a, f.choices, 100_000);
                    const first = try zigprop.internal.evaluateAttempt(a, void, *const T10Cfg, &mutant, null, propT10, &src, a, .{}, false);
                    const ff = first.fail;
                    var mon: KindMonitor = .{ .expected = expected_failure };
                    const sr = try zigprop.internal.shrinkWith(a, void, *const T10Cfg, &mutant, null, propT10, f.failure, .{}, 2000, ff.choices, ff.keys, ff.skips, ff.spans, ff.draws, .{ .on_accept = mon.hook() });
                    const same = choicesEql(sr.choices, f.shrunk_choices) and sr.evaluations == f.shrink_evaluations;
                    if (same) reproduces += 1;
                    accepts += mon.accepts;
                    violations += mon.violations;
                    const off = try zigprop.internal.shrinkWith(a, void, *const T10Cfg, &mutant, null, propT10, f.failure, .{}, 2000, ff.choices, ff.keys, ff.skips, ff.spans, ff.draws, .{ .passes = .{ .p5 = false } });
                    const off_rep = try t10Replay(a, &mutant, off.choices);
                    const off_is_min = std.mem.eql(u64, off_rep.keys, &expected_keys);
                    if (off_is_min) off_min += 1;
                    off_evals += off.evaluations;
                    out.print("{d:>4} | cases {d}, {s}, keys {any}{s}, evals {d}, {s} | hook: {d} acceptances, {d} violations, reproduces {} | P5 off: keys {any}{s}, evals {d} | B2: evals {d}\n", .{
                        seed,        f.origin.random.attempt_index + 1, failureName(f.failure), rep.keys,     if (is_min) " (minimal)" else "",     f.shrink_evaluations, @tagName(f.shrink_outcome),
                        mon.accepts, mon.violations,                    same,                   off_rep.keys, if (off_is_min) " (minimal)" else "", off.evaluations,      b2_evals_seed,
                    });
                },
                else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(r)) }),
            }
        }
        if (dbg.deinit() == .leak) leaks += 1;
        var dbg_c: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        {
            var c = try zigprop.checkWith(dbg_c.allocator(), void, *const T10Cfg, &correct, null, propT10, cfg);
            defer c.deinit();
            if (c == .passed) {
                ctl += 1;
                ctl_discards += c.passed.discards;
            }
        }
        if (dbg_c.deinit() == .leak) ctl_leaks += 1;
    }
    const n = seeds.count();
    out.print("T10: discovered {d}/{d}, minimal keys [3,0,0,1,0,0,0] {d}/{d}, failure = returned_error(HandleReused) {d}/{d}, kind kept on {d} acceptances with {d} violations, hook rerun reproduces {d}/{d}, leaking seeds {d}, control passed {d}/{d} (leaking seeds {d})\n", .{ found, n, minimal, found, kind_ok, found, accepts, violations, reproduces, found, leaks, ctl, n, ctl_leaks });
    out.print("T10 measurements: total evals {d}; P5 off: minimal {d}/{d}, total evals {d}; B1 discovered {d}/{d} (M0: 0/10); B2 discovered {d}/{d}, minimal {d}/{d}, total evals {d}, evals equal to M0 {d}/{d}; control discards (Limits) {d}\n", .{ evals, off_min, found, off_evals, b1_found, n, b2_found, n, b2_min, b2_found, b2_evals, b2_m0, n, ctl_discards });
    out.print("T10 criterion (>=8 discovered AND >=8 minimal, HandleReused on every discovery AND 0 kind violations, 0 leaks, control 10/10; display and reproduced at M5): {s}\n", .{if (found >= 8 and minimal >= 8 and kind_ok == found and violations == 0 and leaks == 0 and ctl == n and ctl_leaks == 0) "MET" else "NOT MET"});
}

// ---------------------------------------------------------------------

/// The inclusive seed range every target runs (`--seeds <from>..<to>`).
/// The default, 0..9, is the range §8.3 registers the gates for; any
/// other range is the Amendment A3 sweep: no gate verdicts, a success
/// ratio per target and one `sweep-below-threshold:` line.
const Seeds = struct {
    from: usize = 0,
    to: usize = 9,

    fn count(s: Seeds) usize {
        return s.to - s.from + 1;
    }

    fn isDefault(s: Seeds) bool {
        return s.from == 0 and s.to == 9;
    }
};

fn parseSeeds(arena: std.mem.Allocator, init: std.process.Init) !Seeds {
    const args = try init.minimal.args.toSlice(arena);
    var seeds: Seeds = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const ok = std.mem.eql(u8, args[i], "--seeds") and i + 1 < args.len and blk: {
            i += 1;
            const dots = std.mem.indexOf(u8, args[i], "..") orelse break :blk false;
            seeds.from = std.fmt.parseInt(usize, args[i][0..dots], 10) catch break :blk false;
            seeds.to = std.fmt.parseInt(usize, args[i][dots + 2 ..], 10) catch break :blk false;
            break :blk seeds.from <= seeds.to;
        };
        if (!ok) {
            std.debug.print("validation: bad argument `{s}`\nusage: zigprop-validation [--seeds <from>..<to>]  (inclusive, default 0..9)\n", .{args[i]});
            std.process.exit(2);
        }
    }
    return seeds;
}

/// One A3 sweep ratio: the target's primary success count over N.
const SweepLine = struct { label: []const u8, ok: usize };

fn belowThreshold(ok: usize, n: usize) bool {
    return ok * 100 < 80 * n;
}

fn printRatio(label: []const u8, ok: usize, n: usize) void {
    const tenths = ok * 1000 / n;
    std.debug.print("{s}: {d}/{d} ({d}.{d}%)\n", .{ label, ok, n, tenths / 10, tenths % 10 });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const out = std.debug;
    const seeds = try parseSeeds(init.arena.allocator(), init);
    const n = seeds.count();
    const sweep = !seeds.isDefault();

    // ---------------- T1 ----------------
    out.print("\n== T1 varint (mutant: decoder truncated at 4 bytes) ==\n", .{});
    out.print("seed | zigprop: cases, shrunk value, shrink evals | hand loop: cases, found value\n", .{});
    var t1_discovered: usize = 0;
    var t1_exact: usize = 0;
    var t1_control_ok: usize = 0;
    for (seeds.from..seeds.to + 1) |seed| {
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
    out.print("T1: discovered {d}/{d}, exact 2^28 {d}/{d}, control passed {d}/{d}\n", .{ t1_discovered, n, t1_exact, n, t1_control_ok, n });
    if (!sweep) out.print("T1 criterion (>=8 discovered AND >=8 exact): {s}\n", .{
        if (t1_discovered >= 8 and t1_exact >= 8) "MET" else "NOT MET",
    });

    // ---------------- T2 ----------------
    out.print("\n== T2 RLE (mutant: run length truncated to u8) ==\n", .{});
    out.print("seed | zigprop: cases, shrunk input, shrink evals | hand loop: cases, first failing input\n", .{});
    var t2_discovered: usize = 0;
    var t2_exact: usize = 0;
    var t2_control_ok: usize = 0;
    for (seeds.from..seeds.to + 1) |seed| {
        var report = try zigprop.checkCustom(allocator, []const Run, genRuns, propRleMutant, .{ .seed = seed, .max_cases = 200 });
        defer report.deinit();
        var hand_prng = std.Random.DefaultPrng.init(seed);
        const hand_rand = hand_prng.random();
        var hand_desc: ?[]const u8 = null;
        var hand_buf: [128]u8 = undefined;
        for (1..201) |i| {
            _ = i;
            var runs_buf: [max_runs]Run = undefined;
            const n_runs = 1 + hand_rand.intRangeLessThan(usize, 0, max_runs);
            for (runs_buf[0..n_runs]) |*r| {
                r.* = .{
                    .value = hand_rand.int(u8),
                    .len = 200 + hand_rand.intRangeLessThan(u32, 0, 101),
                };
            }
            if (!propRleMutant(runs_buf[0..n_runs])) {
                hand_desc = try std.fmt.bufPrint(&hand_buf, "{d} run(s), first len {d}", .{ n_runs, runs_buf[0].len });
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
    out.print("T2: discovered {d}/{d}, exact single-run-256 {d}/{d}, control passed {d}/{d}\n", .{ t2_discovered, n, t2_exact, n, t2_control_ok, n });
    if (!sweep) out.print("T2 criterion (>=8 discovered AND >=8 exact): {s}\n", .{
        if (t2_discovered >= 8 and t2_exact >= 8) "MET" else "NOT MET",
    });

    // ---------------- T3 ----------------
    out.print("\n== T3 f32 codec (mutant: mantissa low byte dropped) ==\n", .{});
    out.print("seed | zigprop: cases, shrunk bits, tier, evals | hand loop: found, best rank\n", .{});
    var t3_discovered: usize = 0;
    var t3_subnormal: usize = 0;
    var t3_exact: usize = 0;
    var t3_control_ok: usize = 0;
    for (seeds.from..seeds.to + 1) |seed| {
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
    out.print("T3: discovered {d}/{d}, subnormal {d}/{d}, exact rank-2 {d}/{d}, control passed {d}/{d}\n", .{ t3_discovered, n, t3_subnormal, n, t3_exact, n, t3_control_ok, n });
    if (!sweep) out.print("T3 criterion (gate: >=8 discovered AND >=8 subnormal; exact reported): {s}\n", .{
        if (t3_discovered >= 8 and t3_subnormal >= 8) "MET" else "NOT MET",
    });

    // ---------------- T4 ----------------
    out.print("\n== T4 recursive union codec (mutant: lists truncated to 2) ==\n", .{});
    out.print("seed | zigprop: cases, shrunk shape, evals | hand loop: found, best key length\n", .{});
    var t4_discovered: usize = 0;
    var t4_exact: usize = 0;
    var t4_control_ok: usize = 0;
    // Kept for T9's gate (2): per-seed shrunk choices identical to T4's.
    // Indexed by seed - seeds.from.
    const t4_shrunk = try allocator.alloc(?[]zigprop.Choice, n);
    @memset(t4_shrunk, null);
    defer allocator.free(t4_shrunk);
    defer for (t4_shrunk) |s| if (s) |c| allocator.free(c);
    for (seeds.from..seeds.to + 1) |seed| {
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
                t4_shrunk[seed - seeds.from] = try allocator.dupe(zigprop.Choice, f.shrunk_choices);
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
    out.print("T4: discovered {d}/{d}, exact list[int 0 x3] {d}/{d}, control passed {d}/{d}\n", .{ t4_discovered, n, t4_exact, n, t4_control_ok, n });
    if (!sweep) out.print("T4 criterion (>=8 discovered AND >=8 exact): {s}\n", .{
        if (t4_discovered >= 8 and t4_exact >= 8) "MET" else "NOT MET",
    });

    // ---------------- T5 / T5s ----------------
    var t5_minimal: [2]usize = .{ 0, 0 }; // T5, T5s (for the sweep ratios)
    inline for (0.., .{
        .{ "T5", "u64 LEB128", u64, propT5Mutant, propT5Correct, @as(i128, 1 << 21) },
        .{ "T5s", "i64 zigzag LEB128", i64, propT5sMutant, propT5sCorrect, @as(i128, 1 << 20) },
    }) |ti, t| {
        out.print("\n== {s} mid-range varint, {s} (mutant: 4th byte of a 4-byte encoding ignored) ==\n", .{ t[0], t[1] });
        out.print("seed | cases, shrunk value, evals, P4 acceptances\n", .{});
        var found: usize = 0;
        var minimal: usize = 0;
        var ctl: usize = 0;
        var evals_total: usize = 0;
        var p4_total: usize = 0;
        for (seeds.from..seeds.to + 1) |seed| {
            var r = try zigprop.check(allocator, t[2], t[3], .{ .seed = seed, .max_cases = 200 });
            defer r.deinit();
            switch (r) {
                .failed => |f| {
                    found += 1;
                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const rep = try replayWithKeys(t[2], arena.allocator(), f.shrunk_choices, .{});
                    const is_min = @as(i128, rep.value) == t[5];
                    if (is_min) minimal += 1;
                    const p4 = try countP4(t[2], arena.allocator(), t[3], f.choices);
                    evals_total += f.shrink_evaluations;
                    p4_total += p4;
                    out.print("{d:>4} | cases {d}, shrunk {d}{s}, evals {d}, P4 {d}\n", .{ seed, f.origin.random.attempt_index + 1, rep.value, if (is_min) " (minimal)" else "", f.shrink_evaluations, p4 });
                },
                else => out.print("{d:>4} | not discovered ({s})\n", .{ seed, @tagName(std.meta.activeTag(r)) }),
            }
            var c = try zigprop.check(allocator, t[2], t[4], .{ .seed = seed, .max_cases = 200 });
            defer c.deinit();
            if (std.meta.activeTag(c) == .passed) ctl += 1;
        }
        t5_minimal[ti] = minimal;
        out.print("{s}: discovered {d}/{d}, minimal {d} {d}/{d}, control passed {d}/{d}\n", .{ t[0], found, n, t[5], minimal, n, ctl, n });
        out.print("{s} measurements: total evals {d}, total P4 acceptances {d}; v0.2.1 (M0-e): found 0/10\n", .{ t[0], evals_total, p4_total });
        if (!sweep) out.print("{s} criterion (>=8 discovered AND >=8 minimal, control 10/10): {s}\n", .{ t[0], if (found >= 8 and minimal >= 8 and ctl == 10) "MET" else "NOT MET" });
    }

    // ---------------- T5-F ----------------
    const t5f = try t5fOrdinary(allocator, seeds);
    out.print("\n== T5-F ordinary f64 values (measurement only) ==\n", .{});
    out.print("T5-F: v0.3 {d}/{d} with exponent in [-20, 20] and non-zero low 20 mantissa bits; v0.2.1: 8/2000 (scratch run, M6)\n", .{ t5f, n * 200 });

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
    for (seeds.from..seeds.to + 1) |seed| {
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
    out.print("T6: discovered {d}/{d}, minimal {{7,[]}} {d}/{d}, control passed {d}/{d}\n", .{ t6_found, n, t6_min, n, t6_ctl, n });
    out.print("T6 measurements: original root=7 {d}, budget exhausted {d}, total evals {d}; P6 off minimal {d}/{d}; v0.2.1 (M0-e): found 10/10, minimal 0/10\n", .{ t6_root7, t6_exhausted, t6_evals_total, t6_p6off_min, t6_found });
    if (!sweep) out.print("T6 criterion (>=8 discovered AND >=8 minimal, control 10/10): {s}\n", .{
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
    for (seeds.from..seeds.to + 1) |seed| {
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
    out.print("T7: discovered {d}/{d}, minimal [7] {d}/{d}, control passed {d}/{d}\n", .{ t7_found, n, t7_min, n, t7_ctl, n });
    out.print("T7 measurements: original first=7 {d}, budget exhausted {d}, total evals {d}; P5 off minimal {d}/{d}; v0.2.1 (M0-e): found 10/10, minimal 8/10\n", .{ t7_first7, t7_exhausted, t7_evals_total, t7_p5off_min, t7_found });
    if (!sweep) out.print("T7 criterion (>=8 discovered AND >=8 minimal [7], control 10/10): {s}\n", .{
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
    for (seeds.from..seeds.to + 1) |seed| {
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
                    const same = if (t4_shrunk[seed - seeds.from]) |c| std.mem.eql(u8, std.mem.sliceAsBytes(c), std.mem.sliceAsBytes(f.shrunk_choices)) else false;
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
    out.print("T9: discovered {d}/{d}, exact list[int 0 x3] {d}/{d}, shrunk choices identical to T4 {d}/{d}, leaking seeds {d}, control passed {d}/{d} (leaking seeds {d}); container-level T9 buffers: none (code review)\n", .{ t9_found, n, t9_exact, n, t9_same, t4_discovered, t9_leaks, t9_ctl, n, t9_ctl_leaks });
    if (!sweep) out.print("T9 criterion (>=8 discovered AND >=8 exact AND identical to T4 on every seed AND 0 leaks, control 10/10): {s}\n", .{
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
    for (seeds.from..seeds.to + 1) |seed| {
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
                    const sr = try zigprop.internal.shrinkWith(a, Value, *const Codec, &rejecting, null, propT9, f.failure, .{}, 2000, src.recorded.items, src.recorded_keys.items, src.recorded_skip.items, src.recorded_spans.items, &.{}, .{ .on_accept = mon.hook() });
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
    out.print("T9e: discovered {d}/{d}, failure = returned_error(UnexpectedLength) {d}/{d}, kind kept on {d} acceptances with {d} violations, exact list[int 0 x3] {d}/{d} (measurement), leaking seeds {d}; control: T9's correct codec\n", .{ t9e_found, n, t9e_kind, t9e_found, t9e_accepts, t9e_violations, t9e_exact, n, t9e_leaks });
    if (!sweep) out.print("T9e criterion (>=8 discovered AND kind reported on every discovery AND 0 kind violations AND 0 leaks): {s}\n", .{
        if (t9e_found >= 8 and t9e_kind == t9e_found and t9e_violations == 0 and t9e_leaks == 0) "MET" else "NOT MET",
    });

    // ---------------- T8 ----------------
    out.print("\n== T8 stale detection (entries printed by regressionEntry, parsed back) ==\n", .{});
    var rows = [_]T8Row{
        .{ .name = "(a) same config, same mutant -> reported as a failure, not stale [u32]" },
        .{ .name = "(a) same config, same mutant -> reported as a failure, not stale [Tree]" },
        .{ .name = "(a) same config, same mutant -> reported as a failure, not stale [[]const u8]" },
        .{ .name = "(b) same config, correct impl -> passed, stale 0, unverified 0 [u32]" },
        .{ .name = "(b) same config, correct impl -> passed, stale 0, unverified 0 [Tree]" },
        .{ .name = "(b) same config, correct impl -> passed, stale 0, unverified 0 [[]const u8]" },
        .{ .name = "(c) []const u8, max_len 32 -> 16 -> stale fingerprint_mismatch (max_len)" },
        .{ .name = "(d) u32, max_len changed -> not stale (normalized to 0)" },
        .{ .name = "(e) Tree, max_depth 3 -> 2 -> stale fingerprint_mismatch (max_depth)" },
        .{ .name = "(f) u32 -> u64 -> stale (type_hash)" },
        .{ .name = "(f) Tree fields reordered -> stale (type_hash)" },
        .{ .name = "(f) Value + one variant -> stale (type_hash) [T4 entries, see note]" },
        .{ .name = "(g) Tree type renamed -> not stale" },
        .{ .name = "(g) Tree fields renamed -> not stale" },
        .{ .name = "(h) suffix appended, correct impl -> stale unconsumed_suffix, not passed [u32]" },
        .{ .name = "(h) suffix appended, correct impl -> stale unconsumed_suffix, not passed [Tree]" },
        .{ .name = "(h) suffix appended, correct impl -> stale unconsumed_suffix, not passed [[]const u8]" },
        .{ .name = "(i) fingerprint removed, correct impl -> passed, unverified [u32]" },
        .{ .name = "(i) fingerprint removed, correct impl -> passed, unverified [Tree]" },
        .{ .name = "(i) fingerprint removed, correct impl -> passed, unverified [[]const u8]" },
        .{ .name = "(j) KNOWN MISS: custom generator mapping changed, same draw shape -> not stale", .known_miss = true },
    };
    var t8_sources_found: usize = 0;
    {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        for (seeds.from..seeds.to + 1) |seed| {
            const cfg: zigprop.Config = .{ .seed = seed, .max_cases = 200 };
            var r1 = try zigprop.check(allocator, u32, propVarintMutant, cfg);
            defer r1.deinit();
            var r6 = try zigprop.check(allocator, Tree, propT6Mutant, .{ .seed = seed, .max_cases = 200, .limits = t6_limits });
            defer r6.deinit();
            var r7 = try zigprop.check(allocator, []const u8, propT7Mutant, cfg);
            defer r7.deinit();
            var r4 = try zigprop.check(allocator, Value, propValueMutant, cfg);
            defer r4.deinit();
            var rj = try zigprop.checkCustom(allocator, u32, genU32Single, propVarintMutant, cfg);
            defer rj.deinit();
            if (r1 != .failed or r6 != .failed or r7 != .failed or r4 != .failed or rj != .failed) {
                out.print("{d:>4} | an entry source did not fail; seed skipped\n", .{seed});
                continue;
            }
            t8_sources_found += 1;
            const e1 = try t8Entry(a, &r1.failed);
            const e6 = try t8Entry(a, &r6.failed);
            const e7 = try t8Entry(a, &r7.failed);
            const e4 = try t8Entry(a, &r4.failed);
            const ej = try t8Entry(a, &rj.failed);
            const d: zigprop.Limits = .{};
            var row: usize = 0;
            // (a)
            const a1 = try t8Replay(u32, allocator, null, propVarintMutant, e1, d);
            rows[row].add(a1.failed_from_entry and a1.origin_stale == null and a1.stale_count == 0);
            row += 1;
            const a6 = try t8Replay(Tree, allocator, null, propT6Mutant, e6, t6_limits);
            rows[row].add(a6.failed_from_entry and a6.origin_stale == null and a6.stale_count == 0);
            row += 1;
            const a7 = try t8Replay([]const u8, allocator, null, propT7Mutant, e7, d);
            rows[row].add(a7.failed_from_entry and a7.origin_stale == null and a7.stale_count == 0);
            row += 1;
            // (b)
            inline for (.{ .{ u32, e1, propVarintCorrect, d }, .{ Tree, e6, propT6Correct, t6_limits }, .{ []const u8, e7, propT7Correct, d } }) |c| {
                const o = try t8Replay(c[0], allocator, null, c[2], c[1], c[3]);
                rows[row].add(!o.failed_from_entry and o.passed == 1 and o.stale_count == 0 and o.unverified == 0);
                row += 1;
            }
            // (c)
            const oc = try t8Replay([]const u8, allocator, null, propT7Mutant, e7, .{ .max_len = 16 });
            rows[row].add(t8Stale(oc, .fingerprint_mismatch) and oc.stale.?.mismatch.max_len);
            row += 1;
            // (d)
            const od = try t8Replay(u32, allocator, null, propVarintMutant, e1, .{ .max_len = 7 });
            rows[row].add(od.failed_from_entry and od.stale_count == 0 and od.origin_stale == null);
            row += 1;
            // (e)
            const oe = try t8Replay(Tree, allocator, null, propT6Mutant, e6, .{ .max_len = 4, .max_depth = 2 });
            rows[row].add(t8Stale(oe, .fingerprint_mismatch) and oe.stale.?.mismatch.max_depth);
            row += 1;
            // (f)
            const of1 = try t8Replay(u64, allocator, null, propU64Mutant, e1, d);
            rows[row].add(t8Stale(of1, .fingerprint_mismatch) and of1.stale.?.mismatch.type_hash);
            row += 1;
            const of2 = try t8Replay(TreeReordered, allocator, null, propTreeReorderedMutant, e6, t6_limits);
            rows[row].add(t8Stale(of2, .fingerprint_mismatch) and of2.stale.?.mismatch.type_hash);
            row += 1;
            const of3 = try t8Replay(ValueMore, allocator, null, propValueMoreMutant, e4, d);
            rows[row].add(t8Stale(of3, .fingerprint_mismatch) and of3.stale.?.mismatch.type_hash);
            row += 1;
            // (g)
            const og1 = try t8Replay(TreeRenamed, allocator, null, propTreeRenamedMutant, e6, t6_limits);
            rows[row].add(og1.failed_from_entry and og1.stale_count == 0);
            row += 1;
            const og2 = try t8Replay(TreeFieldsRenamed, allocator, null, propTreeFieldsRenamedMutant, e6, t6_limits);
            rows[row].add(og2.failed_from_entry and og2.stale_count == 0);
            row += 1;
            // (h)
            inline for (.{ .{ u32, e1, propVarintCorrect, d }, .{ Tree, e6, propT6Correct, t6_limits }, .{ []const u8, e7, propT7Correct, d } }) |c| {
                const o = try t8Replay(c[0], allocator, null, c[2], try withSuffix(a, c[1]), c[3]);
                rows[row].add(t8Stale(o, .unconsumed_suffix) and o.passed == 0);
                row += 1;
            }
            // (i)
            inline for (.{ .{ u32, e1, propVarintCorrect, d }, .{ Tree, e6, propT6Correct, t6_limits }, .{ []const u8, e7, propT7Correct, d } }) |c| {
                const o = try t8Replay(c[0], allocator, null, c[2], withoutFingerprint(c[1]), c[3]);
                rows[row].add(!o.failed_from_entry and o.passed == 1 and o.unverified == 1 and o.stale_count == 0);
                row += 1;
            }
            // (j) the known miss
            const oj = try t8Replay(u32, allocator, genU32Shifted, propVarintCorrect, ej, d);
            rows[row].add(oj.stale_count == 0);
            row += 1;
            std.debug.assert(row == rows.len);
        }
    }
    var t8_all = t8_sources_found == n;
    for (rows) |r| {
        const met = r.total == n and r.ok == n;
        if (!met) t8_all = false;
        out.print("  {s}: {d}/{d}{s}\n", .{ r.name, r.ok, r.total, if (r.known_miss) " (missed, as documented)" else "" });
    }
    out.print("T8: entry sources failed on {d}/{d} seeds; rows met {s}\n", .{ t8_sources_found, n, if (t8_all) "all" else "NOT all" });
    if (!sweep) {
        out.print("T8 criterion (every row 10/10): {s}\n", .{if (t8_all) "MET" else "NOT MET"});
        // v0.4 targets: default range only until Amendment A4 adds
        // them to the sweep (design v0.4 D60).
        out.print("\n== v0.4 targets ==\n", .{});
        try runT14(allocator, seeds);
        try runT11(allocator, seeds);
        try runT10(seeds);
        return;
    }

    // ---------------- A3 sweep summary ----------------
    // Primary success per target over N (design v0.3 Amendment A3):
    // minimality for T1-T7 and T5s, correctness (exact shape) for T9,
    // the reported failure kind for T9e, and each T8 row. No gate
    // verdicts: the registered gates are for seeds 0..9.
    out.print("\n== A3 sweep: seeds {d}..{d} (N = {d}; measurement, not a gate; threshold 80%) ==\n", .{ seeds.from, seeds.to, n });
    const lines = [_]SweepLine{
        .{ .label = "T1 minimal (exact 2^28)", .ok = t1_exact },
        .{ .label = "T2 minimal (single run of 256)", .ok = t2_exact },
        .{ .label = "T3 minimal (exact rank 2)", .ok = t3_exact },
        .{ .label = "T4 minimal (list[int 0 x3])", .ok = t4_exact },
        .{ .label = "T5 minimal (2^21)", .ok = t5_minimal[0] },
        .{ .label = "T5s minimal (2^20)", .ok = t5_minimal[1] },
        .{ .label = "T6 minimal ({7,[]})", .ok = t6_min },
        .{ .label = "T7 minimal ([7])", .ok = t7_min },
        .{ .label = "T9 correct (exact list[int 0 x3])", .ok = t9_exact },
        .{ .label = "T9e kind reported (returned_error(UnexpectedLength))", .ok = t9e_kind },
    };
    var below: std.ArrayList(u8) = .empty;
    defer below.deinit(allocator);
    for (lines) |l| {
        printRatio(l.label, l.ok, n);
        if (belowThreshold(l.ok, n)) try below.print(allocator, "{s}{s} ({d}.{d}%)", .{ if (below.items.len > 0) ", " else "", l.label[0..std.mem.indexOfScalar(u8, l.label, ' ').?], l.ok * 1000 / n / 10, l.ok * 1000 / n % 10 });
    }
    for (rows) |r| {
        const label = try std.fmt.allocPrint(allocator, "T8 {s}", .{r.name});
        defer allocator.free(label);
        printRatio(label, r.ok, n);
        if (belowThreshold(r.ok, n)) try below.print(allocator, "{s}T8 {s} ({d}.{d}%)", .{ if (below.items.len > 0) ", " else "", r.name, r.ok * 1000 / n / 10, r.ok * 1000 / n % 10 });
    }
    out.print("controls (printed, not an issue condition): T1 {d}/{d}, T2 {d}/{d}, T3 {d}/{d}, T4 {d}/{d}, T6 {d}/{d}, T7 {d}/{d}, T9 {d}/{d}; leaking seeds: T9 {d} (control {d}), T9e {d}\n", .{
        t1_control_ok, n, t2_control_ok, n, t3_control_ok, n, t4_control_ok, n, t6_ctl, n, t7_ctl, n, t9_ctl, n, t9_leaks, t9_ctl_leaks, t9e_leaks,
    });
    out.print("sweep-below-threshold: {s}\n", .{if (below.items.len > 0) below.items else "none"});
}
