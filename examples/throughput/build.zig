//! Copyright (c) 2025, Theodore Sackos, All rights reserved.
//! SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const throughput_mod = b.addModule("bbq-throughput", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    const bbq_dep = b.dependency("bbq", .{ .target = target, .optimize = optimize });
    throughput_mod.addImport("bbq", bbq_dep.module("bbq"));

    const throughput_exe = b.addExecutable(.{
        .name = "bbq-throughput",
    .linkage = .dynamic,
        .root_module = throughput_mod,
    });

    // Install the binary
    b.installArtifact(throughput_exe);

    // Add a run step that executes the artifact
    const run_cmd = b.addRunArtifact(throughput_exe);
    const run_step = b.step("run", "runs the application");
    run_step.dependOn(&run_cmd.step);
}
