//! Copyright (c) 2025, Theodore Sackos, All rights reserved.
//! SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bbqt_mod = b.addModule("bbq-test", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    const bbqt_exe = b.addExecutable(.{
        .name = "bbqt",
        .linkage = .static,
        .root_module = bbqt_mod,
    });

    const run_step = b.step("run", "runs the application");
    run_step.dependOn(&bbqt_exe.step);
}
