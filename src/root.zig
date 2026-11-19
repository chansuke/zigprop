//! zigprop — property-based testing for Zig.
//!
//! Designs: `docs/design-v2.md` (Phase 0), `docs/design-v0.2.md`,
//! `docs/design-v0.3.md`. `forAll` is reserved and deliberately not
//! defined (v0.3 Q5).

const source = @import("source.zig");
const gen_mod = @import("gen.zig");
const runner_mod = @import("runner.zig");
const shrink_mod = @import("shrink.zig");

// ---- generation ----
pub const Choice = source.Choice;
pub const Limits = source.Limits;
pub const GenContext = source.GenContext;
pub const Generator = runner_mod.Generator;
pub const GeneratorWith = runner_mod.GeneratorWith;

pub const generate = gen_mod.generate;
pub const generator_version = gen_mod.generator_version;
pub const max_depth_cap = gen_mod.max_depth_cap;

// ---- properties ----
pub const Case = runner_mod.Case;
pub const PropertyWith = runner_mod.PropertyWith;
pub const Failure = runner_mod.Failure;

// ---- entry points ----
pub const check = runner_mod.check;
pub const checkCustom = runner_mod.checkCustom;
pub const checkWith = runner_mod.checkWith;
pub const checkOrError = runner_mod.checkOrError;
pub const checkCustomOrError = runner_mod.checkCustomOrError;
pub const checkWithOrError = runner_mod.checkWithOrError;

// ---- configuration and results ----
pub const Config = runner_mod.Config;
pub const Report = runner_mod.Report;
pub const Origin = runner_mod.Origin;
pub const RegressionSummary = runner_mod.RegressionSummary;
pub const StaleReason = runner_mod.StaleReason;
pub const StaleEntry = runner_mod.StaleEntry;
pub const ShrinkOutcome = runner_mod.ShrinkOutcome;
pub const Regression = runner_mod.Regression;
pub const RegressionFile = runner_mod.RegressionFile;
pub const Fingerprint = runner_mod.Fingerprint;
pub const FingerprintMismatch = runner_mod.FingerprintMismatch;

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
    pub const shrinkWith = shrink_mod.shrinkWith;
    pub const ShrinkResult = shrink_mod.ShrinkResult;
    pub const ShrinkOptions = shrink_mod.ShrinkOptions;
    pub const ShrinkPassMask = shrink_mod.ShrinkPassMask;
    pub const ShrinkPass = shrink_mod.ShrinkPass;
    pub const AcceptEvent = shrink_mod.AcceptEvent;
    pub const AcceptHook = shrink_mod.AcceptHook;
    /// The structural hash, its serialization and the reachability
    /// predicates behind the fingerprint (design v0.3 §4.2-§4.3).
    pub const fingerprint = @import("fingerprint.zig");
};

test {
    _ = source;
    _ = gen_mod;
    _ = @import("shrink.zig");
    _ = runner_mod;
    _ = @import("fingerprint.zig");
}
