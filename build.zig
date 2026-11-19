const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigprop", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit and meta tests");

    const unit_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const meta_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/meta.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigprop", .module = mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(meta_tests).step);
}
