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

/// Generation limits shared by automatic and custom generators (design §3).
pub const Limits = struct {
    /// Inclusive upper bound for slice lengths.
    max_len: usize = 32,
    /// Total number of elements generated for one case, across nesting.
    max_total_elements: usize = 4096,
    /// Maximum number of draws for one case.
    max_draws: usize = 100_000,
};

/// The context handed to generators (design §3, MF6).
pub const GenContext = struct {
    src: *Source,
    /// Per-attempt arena: generated values live here and die with the attempt.
    allocator: Allocator,
    limits: Limits,
};

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
    }

    fn record(self: *Source, choice: Choice) void {
        self.recorded.append(self.allocator, choice) catch |err| {
            if (self.sticky_error == null) self.sticky_error = err;
        };
    }

    /// The one base primitive. `bound > 0` draws uniformly from
    /// `[0, bound)`; `bound == 0` draws from the full u64 domain.
    /// In replay mode the recorded value is normalized against the
    /// requested bound (`value % bound`, or verbatim for the sentinel).
    pub fn range(self: *Source, bound: u64) u64 {
        self.draws += 1;
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
