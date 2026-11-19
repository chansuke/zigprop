//! zigprop — property-based testing for Zig.
//!
//! Phase 0 prototype. Design: `docs/design-v2.md`.

const source = @import("source.zig");
const gen_mod = @import("gen.zig");
const runner_mod = @import("runner.zig");

pub const Choice = source.Choice;
pub const Limits = source.Limits;
pub const GenContext = source.GenContext;
pub const Source = source.Source;
pub const deriveSeed = source.deriveSeed;

pub const generate = gen_mod.generate;
pub const generator_version = gen_mod.generator_version;
pub const max_depth_cap = gen_mod.max_depth_cap;

pub const shrink = @import("shrink.zig").shrink;
pub const ShrinkResult = @import("shrink.zig").ShrinkResult;

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
