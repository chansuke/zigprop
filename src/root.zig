//! zigprop — property-based testing for Zig.
//!
//! Phase 0 prototype. Design: `docs/design-v2.md`.

const source = @import("source.zig");
const gen_mod = @import("gen.zig");
const runner_mod = @import("runner.zig");
const shrink_mod = @import("shrink.zig");

pub const Choice = source.Choice;
pub const Limits = source.Limits;
pub const GenContext = source.GenContext;

pub const generate = gen_mod.generate;
pub const generator_version = gen_mod.generator_version;
pub const max_depth_cap = gen_mod.max_depth_cap;

/// Not covered by any stability promise (design v0.3 §5.6, D28): the
/// surface zigprop's own tests and validation use.
pub const internal = struct {
    pub const Source = source.Source;
    pub const GenState = source.GenState;
    pub const Span = source.Span;
    pub const deriveSeed = source.deriveSeed;
    pub const genContextForTest = source.genContextForTest;
    pub const shrink = shrink_mod.shrink;
    pub const shrinkSpanned = shrink_mod.shrinkSpanned;
    pub const ShrinkResult = shrink_mod.ShrinkResult;
    pub const ShrinkOptions = shrink_mod.ShrinkOptions;
    pub const ShrinkPassMask = shrink_mod.ShrinkPassMask;
    pub const ShrinkPass = shrink_mod.ShrinkPass;
    pub const AcceptEvent = shrink_mod.AcceptEvent;
    pub const AcceptHook = shrink_mod.AcceptHook;
};

pub const Config = runner_mod.Config;
pub const Report = runner_mod.Report;
pub const Regression = runner_mod.Regression;
pub const ShrinkOutcome = runner_mod.ShrinkOutcome;
pub const check = runner_mod.check;
pub const checkCustom = runner_mod.checkCustom;
pub const checkOrError = runner_mod.checkOrError;

test {
    _ = source;
    _ = gen_mod;
    _ = @import("shrink.zig");
    _ = runner_mod;
}
