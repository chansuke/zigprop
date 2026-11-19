//! Comptime generation of values from types (design §4 and §4.1).
//!
//! Every type decomposes into Source primitives. The draw shape for a
//! given type is fixed (e.g. integers always consume a class draw
//! first), so choice sequences stay comparable across shrink steps.

const std = @import("std");
const source = @import("source.zig");
const GenContext = source.GenContext;

/// Bumped whenever generation semantics change; regression entries
/// carry the version they were recorded with (design §7, MF11).
/// It tracks the replay meaning of normalized sequences only (design
/// v0.3 D16). Version 2 (v0.3 M7): reachability-scoped cuts change what
/// a recursive type's sequence means; version-1 entries are stale
/// (`gen_version_mismatch`) and are not replayed (§7.3).
pub const generator_version: u32 = 2;

/// Counts one array/slice element against the per-case budget
/// (design §4, MF8). Exceeding the budget fails the generation with
/// `error.InvalidGeneration`, which the runner classifies as discard.
pub fn countElement(ctx: *GenContext) error{InvalidGeneration}!void {
    ctx.impl.elements_generated += 1;
    if (ctx.impl.elements_generated > ctx.impl.limits.max_total_elements) {
        return error.InvalidGeneration;
    }
}

/// Comptime unfolding cap for recursive types (design v0.2 §3.2,
/// MF1): a generation path may take at most this many recursive
/// occurrences (re-entries of a container type already entered on
/// the path). The specialization at the cap generates the cut form
/// and contains no further recursive calls, which is what makes
/// compilation of recursive types terminate — a runtime check
/// alone cannot do that. `Limits.max_depth` must not exceed this
/// value.
///
/// Termination: the comptime unfolding state is (set, n), where the
/// set holds the container types entered on the current path and n
/// counts the recursive occurrences the path has taken. Along any
/// path the set grows only by first entries (bounded by the number
/// of distinct container types reachable from the root) and n only
/// by re-entries (bounded by this cap); scalars and channel types
/// leave the state unchanged, and chains of channels alone cannot
/// cycle in a legal type graph. Hence the space of (type, set, n)
/// instantiations is finite, and two paths that reach the same type
/// with the same set and count share one instantiation, whatever
/// route and order they took to get there.
pub const max_depth_cap: usize = 16;

pub fn generate(comptime T: type, ctx: *GenContext) !T {
    return generateRec(T, ctx, @Tuple(&.{}), 0);
}

/// The occurrence span annotation for one generation of the
/// container type T (design v0.3 §3.2): `type_id` is the 64-bit
/// FNV-1a hash of `@typeName(T)`, computed at comptime.
pub fn typeId(comptime T: type) u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        break :blk std.hash.Fnv1a_64.hash(@typeName(T));
    };
}

fn occurrenceInfo(comptime T: type) source.Span.Info {
    return .{ .occurrence = .{ .type_id = typeId(T) } };
}

// ---------------------------------------------------------------------
// Canonical comptime unfolding state (design v0.2 §3.2).
//
// The set of container types entered on the current path is a tuple
// type whose field types are the members, deduplicated and sorted by
// @typeName. Tuple types are interned structurally, so equal sets
// are the same type regardless of the order in which they were
// built, and generic instantiations keyed on them are shared. (If
// two distinct types ever shared a @typeName, their relative order
// would depend on insertion order: canonicality — and with it
// instantiation sharing — would degrade, but membership still uses
// `==`, so correctness would not.)
// ---------------------------------------------------------------------

fn setHas(comptime Set: type, comptime T: type) bool {
    inline for (@typeInfo(Set).@"struct".field_types) |S| {
        if (S == T) return true;
    }
    return false;
}

fn setInsertSorted(comptime Set: type, comptime T: type) type {
    const old = @typeInfo(Set).@"struct".field_types;
    var out: [old.len + 1]type = undefined;
    var i: usize = 0;
    var inserted = false;
    for (old) |S| {
        if (!inserted and std.mem.order(u8, @typeName(T), @typeName(S)) == .lt) {
            out[i] = T;
            i += 1;
            inserted = true;
        }
        out[i] = S;
        i += 1;
    }
    if (!inserted) out[i] = T;
    const final = out;
    return @Tuple(&final);
}

/// A recursive occurrence is the re-entry of a named container
/// type (struct or union) already entered on the current path.
/// The channels that mediate recursion in legal Zig types —
/// slices, optionals, arrays — also repeat along a cycle, but
/// they are not occurrences: counting them would cut a recursive
/// value's own kids slice the moment depth is spent. Every cycle
/// in a legal type graph passes through a struct or union (a cycle
/// through channels alone would be infinitely sized), so gating on
/// containers loses no recursion.
fn generateRec(comptime T: type, ctx: *GenContext, comptime Set: type, comptime n: usize) !T {
    switch (@typeInfo(T)) {
        .@"struct", .@"union" => {
            if (comptime setHas(Set, T)) {
                // n mirrors the runtime ctx.impl.depth (one level per
                // occurrence on the path); since max_depth <= cap is
                // validated, the comptime cut at n = cap coincides
                // with the runtime cut for every legal config.
                if (comptime n >= max_depth_cap) {
                    // The re-entered type is the cut type R.
                    return cutRel(T, T, ctx);
                } else {
                    return generateNormal(T, ctx, true, Set, n + 1);
                }
            } else {
                return generateNormal(T, ctx, false, setInsertSorted(Set, T), n);
            }
        },
        else => return generateNormal(T, ctx, false, Set, n),
    }
}

/// `Set` and `n` are the state T's children are generated with,
/// already updated for T itself.
fn generateNormal(comptime T: type, ctx: *GenContext, comptime is_recursive: bool, comptime Set: type, comptime n: usize) !T {
    // A recursive occurrence spends one level of the runtime depth
    // budget (design v0.2 §3.4, MF5). The restore is deferred at
    // function scope — a defer inside the if block would run when
    // the block closes, before any field is generated.
    if (is_recursive) {
        if (ctx.impl.depth >= ctx.impl.limits.max_depth) {
            return cutRel(T, T, ctx);
        }
        ctx.impl.depth += 1;
    }
    defer if (is_recursive) {
        ctx.impl.depth -= 1;
    };
    switch (@typeInfo(T)) {
        .bool => return ctx.impl.src.boolean(),
        .int => return generateInt(T, ctx),
        .float => return generateFloat(T, ctx),
        .@"union" => {
            const sp = ctx.impl.src.beginSpan(occurrenceInfo(T));
            defer ctx.impl.src.endSpan(sp);
            return generateUnion(T, ctx, Set, n);
        },
        .@"enum" => return generateEnum(T, ctx),
        .optional => |opt| {
            if (ctx.impl.src.boolean()) {
                return try generateRec(opt.child, ctx, Set, n);
            }
            return null;
        },
        .array => |arr| {
            var result: T = undefined;
            for (&result) |*elem| {
                try countElement(ctx);
                elem.* = try generateRec(arr.child, ctx, Set, n);
            }
            return result;
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) {
                @compileError("zigprop: unsupported pointer type " ++ @typeName(T) ++
                    " (only slices are generated; use checkCustom for other shapes)");
            }
            if (ptr.sentinel() != null) {
                @compileError("zigprop: sentinel-terminated slices are not supported: " ++
                    @typeName(T) ++ " (use the plain slice type instead)");
            }
            const length_pos = ctx.impl.src.recorded.items.len;
            const len = ctx.impl.src.length(ctx.impl.limits.max_len);
            const buf = try ctx.allocator.alloc(ptr.child, len);
            // On an element error the partial buffer is released here;
            // anything already stored inside elements (nested slices in
            // an array, say) remains the caller's arena's problem.
            errdefer ctx.allocator.free(buf);
            for (buf) |*elem| {
                try countElement(ctx);
                // Element span (design v0.3 §3.2): metadata only.
                const sp = ctx.impl.src.beginSpan(.{ .element = .{ .length_pos = length_pos } });
                elem.* = try generateRec(ptr.child, ctx, Set, n);
                ctx.impl.src.endSpan(sp);
            }
            return buf;
        },
        .@"struct" => |st| {
            const sp = ctx.impl.src.beginSpan(occurrenceInfo(T));
            defer ctx.impl.src.endSpan(sp);
            var result: T = undefined;
            inline for (st.field_names, st.field_types, st.field_attrs) |name, F, attrs| {
                if (attrs.@"comptime") {
                    // Comptime fields keep their comptime value (design §4).
                    @field(result, name) = attrs.defaultValue(F) orelse
                        @compileError("zigprop: comptime field without a value: " ++ name);
                } else {
                    @field(result, name) = try generateRec(F, ctx, Set, n);
                }
            }
            return result;
        },
        else => @compileError("zigprop: unsupported type " ++ @typeName(T) ++
            " (generates bool, integers of 1-64 bits, f16/f32/f64, enums, tagged unions, " ++
            "optionals, arrays, slices and structs; use checkCustom for anything else)"),
    }
}

// ---------------------------------------------------------------------
// Cut forms (design v0.3 §1.2-§1.3, D12, D13). At a cut point the
// re-entered type R is generated in cut mode: only the components that
// reach R are cut; every other component is generated normally in the
// post-limit state (Set = ∅, n = max_depth_cap), where any further
// re-entry is cut at comptime. By the §1.3 lemma, "reaches some type
// of the path's Set" is equivalent to "reaches R", so the decision
// does not depend on the path.
//
// cutRel(C, R), for C reaching R:
//   slice    -> length 0, no draw
//   optional -> null, no draw
//   [N]E     -> each element cut (N > 0; counted against the budget)
//   struct   -> comptime fields keep their value; a field reaching R is
//               cut, any other field is generated post-limit
//   union    -> admissible(U, R) has m variants: m = 0 -> discard
//               (error.InvalidGeneration), m = 1 -> that variant with no
//               draw, m >= 2 -> an index(m) tag draw; the payload is cut
//               if it reaches R, generated post-limit otherwise, and a
//               void payload draws nothing.
// The admissible set is ONE function (I1 lesson): cutExistsRel's union
// branch is "admissible is non-empty" and cutRel's union branch picks
// from the same array.
//
// Termination: cutExistsRel and cutRel recurse only through struct
// fields, array elements and union payloads that reach R (slices and
// optionals stop at once); a cycle through those alone would be an
// infinitely-sized type, which Zig rejects. A post-limit component C
// does not reach R, so the next cut root Y below it has
// Reach(Y) ⊆ Reach(C) ⊊ Reach(R): cut nesting is bounded by the number
// of types (§1.3; an argument, not a mechanical check).
// ---------------------------------------------------------------------

const fingerprint = @import("fingerprint.zig");

/// `reaches(A, B)` of design v0.3 §1.3 (shared with the fingerprint's
/// normalization, §4.2).
pub fn reaches(comptime A: type, comptime B: type) bool {
    return fingerprint.reaches(A, B);
}

/// The admissible variants of U at a cut of R, as indices in
/// declaration order (design v0.3 §1.3, D13): payloads that do not
/// reach R, or that reach R and have a cut form.
pub fn admissible(comptime U: type, comptime R: type) []const usize {
    return comptime admissibleImpl(U, R);
}

fn admissibleImpl(comptime U: type, comptime R: type) []const usize {
    @setEvalBranchQuota(100_000);
    var out: []const usize = &.{};
    for (@typeInfo(U).@"union".field_types, 0..) |P, i| {
        if (!reaches(P, R) or cutExistsRel(P, R)) out = out ++ &[_]usize{i};
    }
    return out;
}

/// Whether C has a cut form at a cut of R (design v0.3 §1.3).
pub fn cutExistsRel(comptime C: type, comptime R: type) bool {
    return comptime cutExistsRelImpl(C, R);
}

fn cutExistsRelImpl(comptime C: type, comptime R: type) bool {
    @setEvalBranchQuota(100_000);
    if (!reaches(C, R)) return true;
    switch (@typeInfo(C)) {
        .pointer => |ptr| return ptr.size == .slice,
        .optional => return true,
        .array => |arr| return arr.len == 0 or cutExistsRel(arr.child, R),
        .@"struct" => |st| {
            for (st.field_types, st.field_attrs) |F, attrs| {
                if (!attrs.@"comptime" and !cutExistsRel(F, R)) return false;
            }
            return true;
        },
        .@"union" => return admissible(C, R).len > 0,
        // Scalars, enums and void have no edges, so they never reach R.
        else => return true,
    }
}

/// The post-limit state (design v0.3 §1.3): Set = ∅, n = cap.
const PostLimitSet = @Tuple(&.{});

/// A component of a cut of R: cut if it reaches R, generated normally
/// in the post-limit state otherwise.
fn cutChild(comptime F: type, comptime R: type, ctx: *GenContext) !F {
    if (comptime reaches(F, R)) return cutRel(F, R, ctx);
    return generateRec(F, ctx, PostLimitSet, max_depth_cap);
}

/// The cut form of R itself, as generated at a cut of R (internal; for
/// the §1.7 agreement test).
pub fn generateCut(comptime R: type, ctx: *GenContext) !R {
    return cutRel(R, R, ctx);
}

fn cutRel(comptime T: type, comptime R: type, ctx: *GenContext) !T {
    switch (@typeInfo(T)) {
        .optional => return null,
        .array => |arr| {
            if (arr.len == 0) return .{};
            var result: T = undefined;
            for (&result) |*elem| {
                try countElement(ctx);
                elem.* = try cutChild(arr.child, R, ctx);
            }
            return result;
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) {
                @compileError("zigprop: unsupported pointer type " ++ @typeName(T) ++
                    " (only slices are generated; use checkCustom for other shapes)");
            }
            if (ptr.sentinel() != null) {
                @compileError("zigprop: sentinel-terminated slices are not supported: " ++
                    @typeName(T) ++ " (use the plain slice type instead)");
            }
            return ctx.allocator.alloc(ptr.child, 0);
        },
        .@"struct" => |st| {
            const sp = ctx.impl.src.beginSpan(occurrenceInfo(T));
            defer ctx.impl.src.endSpan(sp);
            var result: T = undefined;
            inline for (st.field_names, st.field_types, st.field_attrs) |name, F, attrs| {
                if (attrs.@"comptime") {
                    @field(result, name) = attrs.defaultValue(F) orelse
                        @compileError("zigprop: comptime field without a value: " ++ name);
                } else {
                    @field(result, name) = try cutChild(F, R, ctx);
                }
            }
            return result;
        },
        .@"union" => |un| {
            if (un.tag_type == null) {
                @compileError("zigprop: untagged unions are not generated: " ++ @typeName(T));
            }
            const sp = ctx.impl.src.beginSpan(occurrenceInfo(T));
            defer ctx.impl.src.endSpan(sp);
            const adm = comptime admissible(T, R);
            // m = 0: no admissible variant (believed unreachable for
            // generatable types; M0-a), the attempt is a discard.
            if (adm.len == 0) return error.InvalidGeneration;
            // m = 1: no tag draw; m >= 2: one index(m) draw.
            const k: usize = if (adm.len == 1) 0 else @intCast(ctx.impl.src.index(adm.len));
            inline for (adm, 0..) |vi, j| {
                if (k == j) {
                    const name = un.field_names[vi];
                    const Payload = un.field_types[vi];
                    if (Payload == void) return @unionInit(T, name, {});
                    return @unionInit(T, name, try cutChild(Payload, R, ctx));
                }
            }
            unreachable; // k < adm.len by construction
        },
        else => @compileError("zigprop: a cut is only formed for components that reach the cut type: " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------------
// Integers (design §4.1): generation happens in rank space.
// ---------------------------------------------------------------------

fn rankToValue(comptime T: type, rank: u64) T {
    const info = @typeInfo(T).int;
    if (info.signedness == .unsigned) {
        return @intCast(rank);
    }
    if (rank % 2 == 0) {
        return @intCast(rank / 2);
    }
    return @intCast(-@as(i128, rank / 2) - 1);
}

fn valueToRank(comptime T: type, value: i128) u64 {
    const info = @typeInfo(T).int;
    if (info.signedness == .unsigned) {
        return @intCast(value);
    }
    if (value >= 0) {
        return @intCast(2 * value);
    }
    return @intCast(-2 * value - 1);
}

/// The boundary set B(W) of design §4.1 as ranks: the values
/// {0, 1, -1, max, min, max-1, min+1} that are representable in T,
/// converted to ranks, deduplicated and sorted ascending.
/// Computed entirely at comptime.
fn boundaryRanks(comptime T: type) struct { ranks: [7]u64, len: usize } {
    const max: i128 = std.math.maxInt(T);
    const min: i128 = std.math.minInt(T);
    const candidates = [7]i128{ 0, 1, -1, max, min, max - 1, min + 1 };
    var ranks: [7]u64 = undefined;
    var len: usize = 0;
    for (candidates) |c| {
        if (c < min or c > max) continue; // not representable in T
        const r = valueToRank(T, c);
        var dup = false;
        for (ranks[0..len]) |existing| {
            if (existing == r) dup = true;
        }
        if (dup) continue;
        // insertion sort, ascending
        var i = len;
        while (i > 0 and ranks[i - 1] > r) : (i -= 1) {
            ranks[i] = ranks[i - 1];
        }
        ranks[i] = r;
        len += 1;
    }
    return .{ .ranks = ranks, .len = len };
}

fn generateInt(comptime T: type, ctx: *GenContext) !T {
    const info = @typeInfo(T).int;
    if (info.bits == 0) return 0;
    if (info.bits > 64) {
        @compileError("zigprop: integers wider than 64 bits are not supported: " ++ @typeName(T));
    }
    // Rank domain R = 2^W; the draw bound is R itself, or the sentinel
    // bound 0 when W == 64.
    const domain: u128 = @as(u128, 1) << @intCast(info.bits);
    const pair_start = ctx.impl.src.recorded.items.len;
    const class = ctx.impl.src.range(4); // the class draw is always consumed
    const rank: u64 = switch (class) {
        0 => ctx.impl.src.range(@intCast(@min(domain, 256))),
        1 => blk: {
            const b = comptime boundaryRanks(T);
            const idx = ctx.impl.src.index(b.len);
            break :blk b.ranks[@intCast(idx)];
        },
        // Class 2 is log-uniform over the rank domain (design v0.3
        // §2.2, D14): bound R (0 for W = 64), value = rank. Replay is
        // `raw % R`, the same as class 3; a v1 class-2 value v <
        // min(R, 65536) replays unchanged (§2.5).
        2 => ctx.impl.src.rangeLogUniform(info.bits),
        else => ctx.impl.src.range(if (domain == (@as(u128, 1) << 64)) 0 else @intCast(domain)),
    };
    // The pair (class draw, value draw) is one integer draw for shrink
    // purposes: annotate it with the value's rank as its canonical key
    // (design §4.1, v2.1).
    ctx.impl.src.annotatePair(pair_start, rank);
    return rankToValue(T, rank);
}

// ---------------------------------------------------------------------
// Floats (design v0.2 §1): generation happens in rank space, where
// rank = 2a + sign and a is the magnitude bit pattern (exponent and
// mantissa with the sign bit removed). The rank order is a
// sign-interleaved magnitude order: within one sign it is monotone
// in |value| (subnormals, then normals, then infinity). It is NOT
// the numeric order across signs, and shrink only needs it to be a
// well-founded simplicity order (design v0.2 §1.1).
// ---------------------------------------------------------------------

fn floatParts(comptime T: type) struct { bits: u16, exp_bits: u16, mant_bits: u16 } {
    const bits: u16 = @typeInfo(T).float.bits;
    const mant_bits: u16 = switch (bits) {
        16 => 10,
        32 => 23,
        64 => 52,
        else => unreachable,
    };
    return .{ .bits = bits, .exp_bits = bits - mant_bits - 1, .mant_bits = mant_bits };
}

/// NaN magnitudes (exponent all ones, mantissa nonzero) collapse to
/// the infinity magnitude (design v0.2 §1.3): NaN makes every
/// comparison false, so generated NaNs would fail properties for
/// reasons unrelated to the value under test.
fn floatCanonicalMagnitude(comptime T: type, a: u64) u64 {
    const p = comptime floatParts(T);
    const exp_mask: u64 = (@as(u64, 1) << @intCast(p.exp_bits)) - 1;
    const exp = (a >> @intCast(p.mant_bits)) & exp_mask;
    const mant_mask: u64 = (@as(u64, 1) << @intCast(p.mant_bits)) - 1;
    if (exp == exp_mask and (a & mant_mask) != 0) {
        return exp_mask << @intCast(p.mant_bits);
    }
    return a;
}

fn floatRankToValue(comptime T: type, rank: u64) T {
    const p = comptime floatParts(T);
    const a = floatCanonicalMagnitude(T, rank >> 1);
    const U = @Int(.unsigned, p.bits);
    const bits: U = @intCast((rank & 1) << @intCast(p.bits - 1) | a);
    return @bitCast(bits);
}

fn floatValueToRank(comptime T: type, value: T) u64 {
    const p = comptime floatParts(T);
    const U = @Int(.unsigned, p.bits);
    const bits: u64 = @as(U, @bitCast(value));
    const sign = bits >> @intCast(p.bits - 1);
    const mag_mask: u64 = (@as(u64, 1) << @intCast(p.bits - 1)) - 1;
    const a = floatCanonicalMagnitude(T, bits & mag_mask);
    return 2 * a + sign;
}

fn sortDedupRanks(ranks: []u64) usize {
    // insertion sort, ascending, with duplicates removed in place
    var len: usize = 0;
    for (ranks) |r| {
        var dup = false;
        for (ranks[0..len]) |existing| {
            if (existing == r) dup = true;
        }
        if (dup) continue;
        var i = len;
        while (i > 0 and ranks[i - 1] > r) : (i -= 1) {
            ranks[i] = ranks[i - 1];
        }
        ranks[i] = r;
        len += 1;
    }
    return len;
}

/// Class 0 (design v0.2 §1.2): the exact small integers -16..16 as
/// ranks, sorted ascending (so index 0 is +0.0).
fn floatSmallIntRanks(comptime T: type) struct { ranks: [33]u64, len: usize } {
    @setEvalBranchQuota(100_000);
    var ranks: [33]u64 = undefined;
    for (0..33) |i| {
        const k: i32 = @as(i32, @intCast(i)) - 16;
        ranks[i] = floatValueToRank(T, @floatFromInt(k));
    }
    const len = sortDedupRanks(&ranks);
    return .{ .ranks = ranks, .len = len };
}

/// Class 1 (design v0.2 §1.2): the boundary set — both signed zeros,
/// small exact landmarks, the largest finite value, the smallest
/// normal, the smallest subnormal and both infinities — as ranks,
/// sorted ascending.
fn floatBoundaryRanks(comptime T: type) struct { ranks: [14]u64, len: usize } {
    @setEvalBranchQuota(100_000);
    const p = comptime floatParts(T);
    const exp_mask: u64 = (@as(u64, 1) << @intCast(p.exp_bits)) - 1;
    const mant_mask: u64 = (@as(u64, 1) << @intCast(p.mant_bits)) - 1;
    const bias: u64 = (@as(u64, 1) << @intCast(p.exp_bits - 1)) - 1;
    const a_one: u64 = bias << @intCast(p.mant_bits);
    const a_two: u64 = (bias + 1) << @intCast(p.mant_bits);
    const a_half: u64 = (bias - 1) << @intCast(p.mant_bits);
    const a_max_finite: u64 = ((exp_mask - 1) << @intCast(p.mant_bits)) | mant_mask;
    const a_min_normal: u64 = @as(u64, 1) << @intCast(p.mant_bits);
    const a_inf: u64 = exp_mask << @intCast(p.mant_bits);
    // Candidate list (sign, magnitude): both zeros, +-1,
    // +-2, +-0.5, +-max finite, +min normal, +min subnormal, +-inf.
    const candidates = [14][2]u64{
        .{ 0, 0 },            .{ 1, 0 },
        .{ 0, a_one },        .{ 1, a_one },
        .{ 0, a_two },        .{ 1, a_two },
        .{ 0, a_half },       .{ 1, a_half },
        .{ 0, a_max_finite }, .{ 1, a_max_finite },
        .{ 0, a_min_normal }, .{ 0, 1 },
        .{ 0, a_inf },        .{ 1, a_inf },
    };
    var ranks: [14]u64 = undefined;
    for (candidates, 0..) |c, i| {
        ranks[i] = 2 * c[1] + c[0];
    }
    const len = sortDedupRanks(&ranks);
    return .{ .ranks = ranks, .len = len };
}

/// Class 2 (design v0.2 §1.2): the dyadic grid k/8 for k in
/// -1024..1024 — exactly representable in f16/f32/f64. The ranks
/// come out sorted by construction: magnitude grows with |k|, and
/// for equal magnitudes the positive rank (2a) precedes the
/// negative one (2a + 1).
fn floatGridRanks(comptime T: type) struct { ranks: [2049]u64, len: usize } {
    @setEvalBranchQuota(100_000);
    var ranks: [2049]u64 = undefined;
    ranks[0] = 0; // k = 0
    for (1..1025) |k| {
        const kf: T = @floatFromInt(@as(i32, @intCast(k)));
        const v = kf / 8;
        ranks[2 * k - 1] = floatValueToRank(T, v);
        ranks[2 * k] = floatValueToRank(T, -v);
    }
    return .{ .ranks = ranks, .len = 2049 };
}

fn generateFloat(comptime T: type, ctx: *GenContext) !T {
    const bits: u16 = @typeInfo(T).float.bits;
    if (bits != 16 and bits != 32 and bits != 64) {
        @compileError("zigprop: only f16, f32 and f64 are generated (f80/f128 need " ++
            "a wider semantic key design): " ++ @typeName(T));
    }
    // Rank domain R = 2^bits; the draw bound is R itself, or the
    // sentinel bound 0 when bits == 64.
    const pair_start = ctx.impl.src.recorded.items.len;
    // Five classes since v0.3 (design §2.3, D15): class 4 is moderate
    // magnitudes. A v1 class value c < 4 replays as c % 5 = c (§2.5).
    const class = ctx.impl.src.range(5); // the class draw is always consumed
    const rank: u64 = switch (class) {
        0 => blk: {
            const l = comptime floatSmallIntRanks(T);
            const idx = ctx.impl.src.index(l.len);
            break :blk l.ranks[@intCast(idx)];
        },
        1 => blk: {
            const l = comptime floatBoundaryRanks(T);
            const idx = ctx.impl.src.index(l.len);
            break :blk l.ranks[@intCast(idx)];
        },
        2 => blk: {
            const l = comptime floatGridRanks(T);
            const idx = ctx.impl.src.index(l.len);
            break :blk l.ranks[@intCast(idx)];
        },
        3 => ctx.impl.src.range(if (bits == 64) 0 else @as(u64, 1) << @intCast(bits)),
        // Class 4: moderate magnitudes, sampled non-uniformly in random
        // mode; recorded and replayed exactly like class 3 (the
        // canonical form stays class 3, so P4 ratchets 4 -> 3).
        else => ctx.impl.src.rangeModerateFloat(bits),
    };
    const value = floatRankToValue(T, rank);
    // The pair is annotated with the rank of the value actually
    // produced: a drawn NaN pattern collapses to infinity, whose
    // canonical rank differs from the drawn rank (design v0.2
    // §1.3, MF3). Boundary-class and remapped infinities therefore
    // share one key, and P4's "current rank" is unique.
    ctx.impl.src.annotatePair(pair_start, floatValueToRank(T, value));
    return value;
}

// ---------------------------------------------------------------------
// Tagged unions (design v0.2 §2): a tag draw (an ordinary index
// draw over the declared variants), then the payload's own draws.
// The tag is a semantic distinction, not a re-expressible encoding,
// so it gets no pair annotation and no P4 treatment: under the
// key-sequence acceptance rule the number of keys decides first
// and the tag index only breaks ties (design v0.2 §2.2).
// ---------------------------------------------------------------------

fn generateUnion(comptime T: type, ctx: *GenContext, comptime Set: type, comptime n: usize) !T {
    const un = @typeInfo(T).@"union";
    if (un.tag_type == null) {
        @compileError("zigprop: untagged unions are not generated: " ++ @typeName(T) ++
            " (declare the union with an enum tag)");
    }
    if (un.field_names.len == 0) {
        @compileError("zigprop: unions with no variants are not generated: " ++ @typeName(T));
    }
    // Only the named variants are generated; a non-exhaustive tag
    // enum's unnamed values never appear (the same rule as enums).
    const idx = ctx.impl.src.index(un.field_names.len);
    inline for (un.field_names, un.field_types, 0..) |name, Payload, i| {
        if (idx == i) {
            if (Payload == void) {
                return @unionInit(T, name, {});
            }
            return @unionInit(T, name, try generateRec(Payload, ctx, Set, n));
        }
    }
    unreachable; // the tag draw is in range by construction
}

fn generateEnum(comptime T: type, ctx: *GenContext) !T {
    const info = @typeInfo(T).@"enum";
    if (info.field_names.len == 0) {
        @compileError("zigprop: cannot generate an empty enum: " ++ @typeName(T));
    }
    // Non-exhaustive enums generate only their named fields (design §4);
    // the value used is the field's declared tag value.
    const idx = ctx.impl.src.index(info.field_names.len);
    inline for (info.field_values, 0..) |v, i| {
        if (idx == i) return @fromBackingInt(@intCast(v));
    }
    unreachable;
}
