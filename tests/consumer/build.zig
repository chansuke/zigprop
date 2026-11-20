//! A minimal downstream project: it depends on zigprop as a package and
//! uses only the public API, the way README.md shows. `zig build consumer`
//! in the repository root runs `zig build test` here with a fresh cache.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigprop = b.dependency("zigprop", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("consumer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigprop", .module = zigprop.module("zigprop") }},
        }),
    });
    const test_step = b.step("test", "Run the consumer test");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
