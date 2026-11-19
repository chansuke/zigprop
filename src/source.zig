//! Choice, Source, GenContext and Limits — the foundation of zigprop.
//!
//! Design: `zigprop-phase0-design-2026-11-19.md` §2–§3 (v2).
//! Generators never draw values directly from a random source; they consume
//! a sequence of choices. Shrinking transforms the choice sequence and
//! re-runs generation, so every generator is written against `Source`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One recorded decision. Valid iff `bound == 0 or value < bound`;
/// `bound == 0` is the sentinel for the full u64 domain (design §2, MF1).
pub const Choice = struct {
    bound: u64,
    value: u64,
};

/// A structural annotation of the recorded sequence (design v0.3 §3.2,
/// D18): the positions `[start, end)` of one slice element or of one
/// container occurrence. Spans are metadata only: they never enter
/// the key sequence or the acceptance rule, so a wrong or stale span
/// can only cost shrink efficiency, never soundness (§3.4).
pub const Span = struct {
    start: usize,
    end: usize,
    info: Info,

    pub const Info = union(enum) {
        /// One element of a slice; `length_pos` is the recorded
        /// position of that slice's length draw.
        element: struct { length_pos: usize },
        /// One generation of a struct or union; `type_id` is the
        /// 64-bit hash of `@typeName` (collisions only cost
        /// efficiency, §3.2).
        occurrence: struct { type_id: u64 },
    };
};

/// Generation limits shared by automatic and custom generators (design §3).
pub const Limits = struct {
    /// Inclusive upper bound for slice lengths.
    max_len: usize = 32,
    /// Total number of elements generated for one case, across nesting.
    max_total_elements: usize = 4096,
    /// Maximum number of draws for one case.
    max_draws: usize = 100_000,
    /// Maximum nesting depth of recursive occurrences (design
    /// v0.2 §3.4). Must not exceed gen.max_depth_cap (the comptime
    /// unfolding cap); the runner rejects larger values as
    /// InvalidConfig.
    max_depth: usize = 8,
};

/// The context handed to generators (design §3, MF6; v0.3 §5.2, D28).
/// Its only fields are the attempt allocator, a copy of the limits and
/// the internal state; generators draw through the methods, never
/// through the Source.
pub const GenContext = struct {
    /// Per-attempt arena: generated values live here and die with the attempt.
    allocator: Allocator,
    /// Read-only copy: writing it does not change generation, which
    /// reads the limits from the internal state.
    limits: Limits,
    /// Internal state (recording, depth, element budget); not covered
    /// by any stability promise.
    impl: *GenState,

    pub fn range(self: *GenContext, bound: u64) u64 {
        return self.impl.src.range(bound);
    }

    pub fn boolean(self: *GenContext) bool {
        return self.impl.src.boolean();
    }

    pub fn index(self: *GenContext, n: u64) u64 {
        return self.impl.src.index(n);
    }

    pub fn length(self: *GenContext, max_inclusive: usize) usize {
        return self.impl.src.length(max_inclusive);
    }

    /// Built-in generation, sharing depth and the element budget and
    /// adding key annotations and spans.
    pub fn generate(self: *GenContext, comptime T: type) anyerror!T {
        return @import("gen.zig").generate(T, self);
    }

    /// Counts one element against the per-case budget when a custom
    /// generator builds a slice or array itself.
    pub fn countElement(self: *GenContext) error{InvalidGeneration}!void {
        return @import("gen.zig").countElement(self);
    }
};

/// Internal generation state behind a GenContext (design v0.3 §5.2):
/// the recording Source, the generation limits, the element budget
/// used so far and the recursion depth.
pub const GenState = struct {
    src: *Source,
    limits: Limits,
    /// Array/slice elements generated so far in this attempt (design
    /// §4, MF8). Generators increment this via countElement.
    elements_generated: usize = 0,
    /// Current nesting depth of recursive occurrences (design
    /// v0.2 §3.4). Generation increments it when entering a
    /// recursive occurrence and restores it on every exit path;
    /// custom generators calling back into generate share it.
    depth: usize = 0,
};

/// Builds a GenContext over `src` (internal; design v0.3 §5.2): used
/// by the shrinker and runner, and by zigprop's own tests and
/// validation. `state` provides the storage the context points into
/// and must outlive it.
pub fn genContextForTest(state: *GenState, src: *Source, allocator: Allocator, limits: Limits) GenContext {
    state.* = .{ .src = src, .limits = limits };
    return .{ .allocator = allocator, .limits = limits, .impl = state };
}

/// Derives the independent PRNG seed for one attempt (design §5).
///
/// Fixed by specification: a SplitMix64 mix of `seed + attempt * phi`.
/// These constants are part of zigprop's reproducibility contract; the
/// meta tests pin the exact outputs.
pub fn deriveSeed(seed: u64, attempt: u64) u64 {
    var z = seed +% attempt *% 0x9E37_79B9_7F4A_7C15;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

/// A source of choices, in random mode or replay mode.
///
/// Every draw is recorded (normalized, semantic value) into `recorded`, so
/// an attempt's consumed sequence can be stored, replayed and shrunk.
/// Recording failures never corrupt the sequence silently: they are kept in
/// `sticky_error` and checked by the runner at attempt boundaries (MF9).
pub const Source = struct {
    mode: Mode,
    allocator: Allocator,
    recorded: std.ArrayList(Choice) = .empty,
    /// Canonical comparison key per recorded choice (design §4.1/§6,
    /// v2.1). Defaults to the choice value; integer generation annotates
    /// a pair with the generated value's rank so shrink acceptance
    /// compares value simplicity, not class encodings.
    recorded_keys: std.ArrayList(u64) = .empty,
    /// Recorded positions excluded from the key comparison: the second
    /// choice of an annotated integer pair.
    recorded_skip: std.ArrayList(bool) = .empty,
    /// Span annotations in pre-order of their start (design v0.3
    /// §3.2). Metadata only; see `Span`.
    recorded_spans: std.ArrayList(Span) = .empty,
    /// Replay cursor.
    pos: usize = 0,
    /// Set when a replay ran past the end of the recorded sequence.
    exhausted: bool = false,
    /// Set when the draw budget was exceeded; the attempt is a discard.
    limit_exceeded: bool = false,
    sticky_error: ?anyerror = null,
    draws: usize = 0,
    max_draws: usize,

    const Mode = union(enum) {
        random: std.Random.DefaultPrng,
        replay: []const Choice,
    };

    pub fn initRandom(allocator: Allocator, derived_seed: u64, max_draws: usize) Source {
        return .{
            .mode = .{ .random = std.Random.DefaultPrng.init(derived_seed) },
            .allocator = allocator,
            .max_draws = max_draws,
        };
    }

    pub fn initReplay(allocator: Allocator, choices: []const Choice, max_draws: usize) Source {
        return .{
            .mode = .{ .replay = choices },
            .allocator = allocator,
            .max_draws = max_draws,
        };
    }

    pub fn deinit(self: *Source) void {
        self.recorded.deinit(self.allocator);
        self.recorded_keys.deinit(self.allocator);
        self.recorded_skip.deinit(self.allocator);
        self.recorded_spans.deinit(self.allocator);
    }

    /// Sentinel returned by `beginSpan` when the span could not be
    /// stored; `endSpan` ignores it.
    pub const no_span = std.math.maxInt(usize);

    /// Opens a span at the current recorded position. Returns the
    /// span's index for `endSpan`. Spans draw nothing and change no
    /// recorded choice, key or skip (design v0.3 D18). A storage
    /// failure is kept as the sticky error, like a recording failure.
    pub fn beginSpan(self: *Source, info: Span.Info) usize {
        const start = self.recorded.items.len;
        self.recorded_spans.append(self.allocator, .{ .start = start, .end = start, .info = info }) catch |err| {
            if (self.sticky_error == null) self.sticky_error = err;
            return no_span;
        };
        return self.recorded_spans.items.len - 1;
    }

    /// Closes the span opened by `beginSpan` at the current recorded
    /// position.
    pub fn endSpan(self: *Source, idx: usize) void {
        if (idx == no_span) return;
        self.recorded_spans.items[idx].end = self.recorded.items.len;
    }

    fn record(self: *Source, choice: Choice) void {
        self.recorded.append(self.allocator, choice) catch |err| {
            if (self.sticky_error == null) self.sticky_error = err;
            return;
        };
        self.recorded_keys.append(self.allocator, choice.value) catch |err| {
            if (self.sticky_error == null) self.sticky_error = err;
            return;
        };
        self.recorded_skip.append(self.allocator, false) catch |err| {
            if (self.sticky_error == null) self.sticky_error = err;
        };
    }

    /// Annotates the two recorded choices starting at `start` as one
    /// integer draw whose canonical key is `key` (the generated value's
    /// rank): the first position carries the key, the second is skipped
    /// in key comparisons (design §4.1, v2.1). Out-of-range positions
    /// (a draw limit tripped mid-pair) are ignored; such attempts are
    /// discards anyway.
    pub fn annotatePair(self: *Source, start: usize, key: u64) void {
        if (start < self.recorded_keys.items.len) {
            self.recorded_keys.items[start] = key;
        }
        if (start + 1 < self.recorded_skip.items.len) {
            self.recorded_skip.items[start + 1] = true;
        }
    }

    /// The one base primitive. `bound > 0` draws uniformly from
    /// `[0, bound)`; `bound == 0` draws from the full u64 domain.
    /// In replay mode the recorded value is normalized against the
    /// requested bound (`value % bound`, or verbatim for the sentinel).
    pub fn range(self: *Source, bound: u64) u64 {
        self.draws += 1;
        if (self.limit_exceeded) {
            // The attempt is already a discard; stop recording so the
            // recorded sequence stays bounded by max_draws + 1 entries.
            return 0;
        }
        if (self.draws > self.max_draws) {
            self.limit_exceeded = true;
            self.record(.{ .bound = bound, .value = 0 });
            return 0;
        }
        const value: u64 = switch (self.mode) {
            .random => |*prng| blk: {
                const r = prng.random();
                break :blk if (bound == 0)
                    r.int(u64)
                else
                    r.intRangeLessThan(u64, 0, bound);
            },
            .replay => |choices| blk: {
                if (self.pos >= choices.len) {
                    self.exhausted = true;
                    break :blk 0;
                }
                const raw = choices[self.pos].value;
                self.pos += 1;
                break :blk if (bound == 0) raw else raw % bound;
            },
        };
        self.record(.{ .bound = bound, .value = value });
        return value;
    }

    pub fn boolean(self: *Source) bool {
        return self.range(2) != 0;
    }

    /// Draws an index in `[0, n)`. `n == 0` is the empty set, not the
    /// full-domain sentinel: it records `error.InvalidBound` as the
    /// sticky error and returns 0 (design §2, MF1).
    pub fn index(self: *Source, n: u64) u64 {
        if (n == 0) {
            if (self.sticky_error == null) self.sticky_error = error.InvalidBound;
            self.record(.{ .bound = 0, .value = 0 });
            return 0;
        }
        return self.range(n);
    }

    /// Draws a length in `[0, max_inclusive]`.
    pub fn length(self: *Source, max_inclusive: usize) usize {
        const bound: u128 = @as(u128, max_inclusive) + 1;
        if (bound > std.math.maxInt(u64)) {
            if (self.sticky_error == null) self.sticky_error = error.InvalidBound;
            return 0;
        }
        return @intCast(self.range(@intCast(bound)));
    }
};

test "deriveSeed fixed values" {
    // Pinned by specification (design §5); computed from the constants in
    // deriveSeed. Changing these outputs breaks seed reproducibility.
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0000_0000), deriveSeed(0, 0));
    try std.testing.expectEqual(@as(u64, 0xe220_a839_7b1d_cdaf), deriveSeed(0, 1));
    try std.testing.expectEqual(@as(u64, 0xa759_ea27_d472_7622), deriveSeed(42, 0));
    try std.testing.expectEqual(@as(u64, 0x37e9_671c_4537_6d5d), deriveSeed(42, 7));
    try std.testing.expectEqual(@as(u64, 0x382f_f84c_b272_81e9), deriveSeed(std.math.maxInt(u64), 3));
    // Wrapping-arithmetic boundary inputs.
    try std.testing.expectEqual(@as(u64, 0xb4d0_55fc_f2cb_bd7b), deriveSeed(std.math.maxInt(u64), 0));
    try std.testing.expectEqual(@as(u64, 0x3365_03c6_b835_bec0), deriveSeed(0, std.math.maxInt(u64)));
}

test "index(0) is InvalidBound, not the full-domain sentinel" {
    var src = Source.initRandom(std.testing.allocator, deriveSeed(1, 0), 100);
    defer src.deinit();
    try std.testing.expectEqual(@as(u64, 0), src.index(0));
    try std.testing.expectEqual(error.InvalidBound, src.sticky_error.?);
}

test "draw limit marks the attempt as exceeded" {
    var src = Source.initRandom(std.testing.allocator, deriveSeed(1, 0), 3);
    defer src.deinit();
    _ = src.range(10);
    _ = src.range(10);
    _ = src.range(10);
    try std.testing.expect(!src.limit_exceeded);
    try std.testing.expectEqual(@as(u64, 0), src.range(10));
    try std.testing.expect(src.limit_exceeded);
}

test "length stays within the inclusive bound" {
    var src = Source.initRandom(std.testing.allocator, deriveSeed(7, 0), 1000);
    defer src.deinit();
    for (0..1000) |_| {
        try std.testing.expect(src.length(5) <= 5);
    }
}

test "length(0) is always 0 and index stays in range" {
    var src = Source.initRandom(std.testing.allocator, deriveSeed(7, 1), 1000);
    defer src.deinit();
    for (0..100) |_| {
        try std.testing.expectEqual(@as(usize, 0), src.length(0));
        try std.testing.expect(src.index(7) < 7);
        try std.testing.expectEqual(@as(u64, 0), src.index(1));
    }
}

test "recorded sequence stays bounded after the draw limit" {
    var src = Source.initRandom(std.testing.allocator, deriveSeed(1, 0), 3);
    defer src.deinit();
    for (0..100) |_| _ = src.range(10);
    try std.testing.expect(src.limit_exceeded);
    try std.testing.expect(src.recorded.items.len <= 4);
}

test "recording failure surfaces as sticky error, values still flow" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var src = Source.initRandom(failing.allocator(), deriveSeed(1, 0), 100);
    defer src.deinit();
    _ = src.range(10);
    try std.testing.expectEqual(error.OutOfMemory, src.sticky_error.?);
    try std.testing.expectEqual(@as(usize, 0), src.recorded.items.len);
}
