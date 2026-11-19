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
pub const generator_version: u32 = 1;

/// Counts one array/slice element against the per-case budget
/// (design §4, MF8). Exceeding the budget fails the generation with
/// `error.InvalidGeneration`, which the runner classifies as discard.
pub fn countElement(ctx: *GenContext) error{InvalidGeneration}!void {
    ctx.elements_generated += 1;
    if (ctx.elements_generated > ctx.limits.max_total_elements) {
        return error.InvalidGeneration;
    }
}

pub fn generate(comptime T: type, ctx: *GenContext) !T {
    switch (@typeInfo(T)) {
        .bool => return ctx.src.boolean(),
        .int => return generateInt(T, ctx),
        .@"enum" => return generateEnum(T, ctx),
        .optional => |opt| {
            if (ctx.src.boolean()) {
                return try generate(opt.child, ctx);
            }
            return null;
        },
        .array => |arr| {
            var result: T = undefined;
            for (&result) |*elem| {
                try countElement(ctx);
                elem.* = try generate(arr.child, ctx);
            }
            return result;
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) {
                @compileError("zigprop: unsupported pointer type " ++ @typeName(T) ++
                    " (only slices are generated; use checkCustom for other shapes)");
            }
            if (ptr.sentinel() != null) {
                @compileError("zigprop: sentinel-terminated slices are not supported in Phase 0: " ++
                    @typeName(T) ++ " (use the plain slice type instead)");
            }
            const len = ctx.src.length(ctx.limits.max_len);
            const buf = try ctx.allocator.alloc(ptr.child, len);
            // On an element error the partial buffer is released here;
            // anything already stored inside elements (nested slices in
            // an array, say) remains the caller's arena's problem.
            errdefer ctx.allocator.free(buf);
            for (buf) |*elem| {
                try countElement(ctx);
                elem.* = try generate(ptr.child, ctx);
            }
            return buf;
        },
        .@"struct" => |st| {
            var result: T = undefined;
            inline for (st.field_names, st.field_types, st.field_attrs) |name, F, attrs| {
                if (attrs.@"comptime") {
                    // Comptime fields keep their comptime value (design §4).
                    @field(result, name) = attrs.defaultValue(F) orelse
                        @compileError("zigprop: comptime field without a value: " ++ name);
                } else {
                    @field(result, name) = try generate(F, ctx);
                }
            }
            return result;
        },
        else => @compileError("zigprop: unsupported type " ++ @typeName(T) ++
            " (Phase 0 generates bool, integers of 1-64 bits, enums, optionals, " ++
            "arrays, slices and structs; use checkCustom for anything else)"),
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
        @compileError("zigprop: integers wider than 64 bits are deferred to v0.2: " ++ @typeName(T));
    }
    // Rank domain R = 2^W; the draw bound is R itself, or the sentinel
    // bound 0 when W == 64.
    const domain: u128 = @as(u128, 1) << @intCast(info.bits);
    const class = ctx.src.range(4); // the class draw is always consumed
    const rank: u64 = switch (class) {
        0 => ctx.src.range(@intCast(@min(domain, 256))),
        1 => blk: {
            const b = comptime boundaryRanks(T);
            const idx = ctx.src.index(b.len);
            break :blk b.ranks[@intCast(idx)];
        },
        2 => ctx.src.range(@intCast(@min(domain, 65536))),
        else => ctx.src.range(if (domain == (@as(u128, 1) << 64)) 0 else @intCast(domain)),
    };
    return rankToValue(T, rank);
}

fn generateEnum(comptime T: type, ctx: *GenContext) !T {
    const info = @typeInfo(T).@"enum";
    if (info.field_names.len == 0) {
        @compileError("zigprop: cannot generate an empty enum: " ++ @typeName(T));
    }
    // Non-exhaustive enums generate only their named fields (design §4);
    // the value used is the field's declared tag value.
    const idx = ctx.src.index(info.field_names.len);
    inline for (info.field_values, 0..) |v, i| {
        if (idx == i) return @fromBackingInt(@intCast(v));
    }
    unreachable;
}
