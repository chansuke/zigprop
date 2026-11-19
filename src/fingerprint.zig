//! Regression fingerprints (design v0.3 §4, D23): a structural hash of
//! the generated type plus the Limits fields that change what a stored
//! sequence means, normalized away when they cannot matter for T.
//!
//! The hash definition below is a compatibility surface: changing it
//! makes every recorded entry stale (§4.3). The golden values are
//! pinned in tests/meta11.zig.

const std = @import("std");
const source = @import("source.zig");
const Limits = source.Limits;

/// Recorded with a regression entry (design v0.3 §4.4).
pub const Fingerprint = struct {
    /// The structural hash of the generated type (§4.3).
    type_hash: u64,
    /// Normalized to 0 when T reaches no slice (built-in generation).
    max_len: u64,
    /// Normalized to 0 when T is not recursive (built-in generation).
    max_depth: u8,
    /// Recorded with a custom generator; then nothing is normalized.
    custom_generator: bool,
};

/// Which fingerprint fields differ (design v0.3 §4.5 row 2).
pub const Mismatch = struct {
    type_hash: bool = false,
    max_len: bool = false,
    max_depth: bool = false,
    custom_generator: bool = false,

    pub fn any(self: Mismatch) bool {
        return self.type_hash or self.max_len or self.max_depth or self.custom_generator;
    }
};

pub fn compare(stored: Fingerprint, current: Fingerprint) Mismatch {
    return .{
        .type_hash = stored.type_hash != current.type_hash,
        .max_len = stored.max_len != current.max_len,
        .max_depth = stored.max_depth != current.max_depth,
        .custom_generator = stored.custom_generator != current.custom_generator,
    };
}

/// The fingerprint of a run over T (design v0.3 §4.2, D23). With a
/// custom generator, `max_len` and `max_depth` are always kept: the
/// generator may read any limit or call back into `generate`.
pub fn of(comptime T: type, limits: Limits, custom_generator: bool) Fingerprint {
    const keep_len = custom_generator or comptime reachesSlice(T);
    const keep_depth = custom_generator or comptime isRecursive(T);
    return .{
        .type_hash = typeHash(T),
        .max_len = if (keep_len) limits.max_len else 0,
        .max_depth = if (keep_depth) @intCast(limits.max_depth) else 0,
        .custom_generator = custom_generator,
    };
}

// ---------------------------------------------------------------------
// Reachability over the type graph (design v0.3 §1.3). The edges are
// the non-comptime struct field types, the union payload types, the
// optional child, the child of an array with N > 0, and the slice
// child. void, scalars, enums and [0]X have no outgoing edges.
// ---------------------------------------------------------------------

const quota = 100_000;

fn edges(comptime T: type) []const type {
    comptime {
        var out: []const type = &.{};
        switch (@typeInfo(T)) {
            .@"struct" => |st| {
                for (st.field_types, st.field_attrs) |F, a| {
                    if (!a.@"comptime") out = out ++ &[_]type{F};
                }
            },
            .@"union" => |un| {
                for (un.field_types) |P| out = out ++ &[_]type{P};
            },
            .optional => |o| out = out ++ &[_]type{o.child},
            .array => |a| if (a.len > 0) {
                out = out ++ &[_]type{a.child};
            },
            .pointer => |p| if (p.size == .slice) {
                out = out ++ &[_]type{p.child};
            },
            else => {},
        }
        return out;
    }
}

fn contains(comptime list: []const type, comptime T: type) bool {
    for (list) |S| {
        if (S == T) return true;
    }
    return false;
}

/// The types reachable from T by one or more edges (iterative DFS
/// with a visited list; finite because the type graph is finite).
fn reachableFrom(comptime T: type) []const type {
    comptime {
        @setEvalBranchQuota(quota);
        var visited: []const type = &.{};
        var stack: []const type = edges(T);
        while (stack.len > 0) {
            const X = stack[stack.len - 1];
            stack = stack[0 .. stack.len - 1];
            if (contains(visited, X)) continue;
            visited = visited ++ &[_]type{X};
            stack = stack ++ edges(X);
        }
        return visited;
    }
}

/// `reaches(A, B)`: B is reachable from A by one or more edges.
pub fn reaches(comptime A: type, comptime B: type) bool {
    return comptime contains(reachableFrom(A), B);
}

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice,
        else => false,
    };
}

/// T is a slice or reaches one (design v0.3 §4.2: `max_len` matters).
pub fn reachesSlice(comptime T: type) bool {
    return comptime reachesSliceImpl(T);
}

fn reachesSliceImpl(comptime T: type) bool {
    @setEvalBranchQuota(quota);
    if (isSlice(T)) return true;
    for (reachableFrom(T)) |X| {
        if (isSlice(X)) return true;
    }
    return false;
}

/// T is recursive: some container X reachable from T (T included)
/// reaches itself (design v0.3 §4.2: `max_depth` matters).
pub fn isRecursive(comptime T: type) bool {
    return comptime isRecursiveImpl(T);
}

fn isRecursiveImpl(comptime T: type) bool {
    @setEvalBranchQuota(quota);
    const all = &[_]type{T} ++ reachableFrom(T);
    for (all) |X| {
        switch (@typeInfo(X)) {
            .@"struct", .@"union" => if (contains(reachableFrom(X), X)) return true,
            else => {},
        }
    }
    return false;
}

// ---------------------------------------------------------------------
// Structural hash (design v0.3 §4.3): FNV-1a 64 over a canonical
// serialization of the generation shape. Included: the kind tag; int
// signedness and width; float width; enum field count and values in
// declaration order; optional / array (length) / slice child; struct
// non-comptime field types in order; union tag presence and payloads
// in order (void distinguished). Names are not included. Named
// containers are numbered in first-visit order and later visits are
// serialized as back-references, so recursive types terminate.
// ---------------------------------------------------------------------

const Ser = struct { bytes: []const u8, seen: []const type };

fn indexOf(comptime seen: []const type, comptime T: type) ?usize {
    for (seen, 0..) |S, i| {
        if (S == T) return i;
    }
    return null;
}

fn ser(comptime T: type, comptime seen: []const type) Ser {
    const p = std.fmt.comptimePrint;
    switch (@typeInfo(T)) {
        .void => return .{ .bytes = "v;", .seen = seen },
        .bool => return .{ .bytes = "b;", .seen = seen },
        .int => |i| return .{ .bytes = p("i{c}{d};", .{ if (i.signedness == .signed) 's' else 'u', i.bits }), .seen = seen },
        .float => |f| return .{ .bytes = p("f{d};", .{f.bits}), .seen = seen },
        .@"enum" => |e| {
            var out: []const u8 = p("e{d}:", .{e.field_names.len});
            for (e.field_values) |v| out = out ++ p("{d},", .{v});
            return .{ .bytes = out ++ ";", .seen = seen };
        },
        .optional => |o| {
            const c = ser(o.child, seen);
            return .{ .bytes = "o" ++ c.bytes, .seen = c.seen };
        },
        .array => |a| {
            const c = ser(a.child, seen);
            return .{ .bytes = p("a{d}", .{a.len}) ++ c.bytes, .seen = c.seen };
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) @compileError("zigprop: unsupported pointer type in a fingerprint: " ++ @typeName(T));
            const c = ser(ptr.child, seen);
            return .{ .bytes = "s" ++ c.bytes, .seen = c.seen };
        },
        .@"struct" => |st| {
            if (indexOf(seen, T)) |k| return .{ .bytes = p("r{d};", .{k}), .seen = seen };
            var cur: []const type = seen ++ &[_]type{T};
            var n: usize = 0;
            for (st.field_attrs) |a| {
                if (!a.@"comptime") n += 1;
            }
            var out: []const u8 = p("S{d}:", .{n});
            for (st.field_types, st.field_attrs) |F, a| {
                if (a.@"comptime") continue;
                const c = ser(F, cur);
                out = out ++ c.bytes;
                cur = c.seen;
            }
            return .{ .bytes = out ++ ";", .seen = cur };
        },
        .@"union" => |un| {
            if (indexOf(seen, T)) |k| return .{ .bytes = p("r{d};", .{k}), .seen = seen };
            var cur: []const type = seen ++ &[_]type{T};
            var out: []const u8 = p("U{c}{d}:", .{ if (un.tag_type != null) 't' else 'n', un.field_types.len });
            for (un.field_types) |P| {
                const c = ser(P, cur);
                out = out ++ c.bytes;
                cur = c.seen;
            }
            return .{ .bytes = out ++ ";", .seen = cur };
        },
        else => @compileError("zigprop: unsupported type in a fingerprint: " ++ @typeName(T)),
    }
}

/// The canonical serialization of T (exposed for the golden tests).
pub fn serialization(comptime T: type) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(quota);
        break :blk ser(T, &.{}).bytes;
    };
}

/// The structural hash of T (design v0.3 §4.3). The quota of 100,000
/// is the M0-b measurement: 10,000 is not enough for a 30-field
/// struct, because std.fmt.comptimePrint is branch-hungry.
pub fn typeHash(comptime T: type) u64 {
    return comptime blk: {
        @setEvalBranchQuota(quota);
        break :blk std.hash.Fnv1a_64.hash(ser(T, &.{}).bytes);
    };
}
