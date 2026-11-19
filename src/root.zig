//! zigprop — property-based testing for Zig.
//!
//! Phase 0 prototype. Design: `zigprop-phase0-design-2026-11-19.md` (v2).

const source = @import("source.zig");

pub const Choice = source.Choice;
pub const Limits = source.Limits;
pub const GenContext = source.GenContext;
pub const Source = source.Source;
pub const deriveSeed = source.deriveSeed;

/// Bumped whenever generation semantics change; regression entries carry
/// the version they were recorded with (design §7, MF11).
pub const generator_version: u32 = 1;

test {
    _ = source;
    _ = @import("gen.zig");
    _ = @import("shrink.zig");
    _ = @import("runner.zig");
}
