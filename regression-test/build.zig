//! Copyright (c) 2025, Theodore Sackos, All rights reserved.
//! SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Bring in the bbq module from the parent workspace dependency declared in build.zig.zon
    const bbq_dep = b.dependency("bbq", .{ .target = target, .optimize = optimize });

    const bbqt_mod = b.addModule("bbq-test", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    // Allow main.zig to `@import("bbq")`
    bbqt_mod.addImport("bbq", bbq_dep.module("bbq"));

    const bbqt_exe = b.addExecutable(.{
        .name = "bbq-regress",
        .linkage = .static,
        .root_module = bbqt_mod,
    });

    // Install the binary
    b.installArtifact(bbqt_exe);

    // Add a run step that executes the artifact
    const run_cmd = b.addRunArtifact(bbqt_exe);
    const run_step = b.step("run", "runs the application");
    run_step.dependOn(&run_cmd.step);
}
