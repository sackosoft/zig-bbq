//! Copyright (c) 2025, Theodore Sackos, All rights reserved.
//! SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bbq_module = b.addModule("bbq", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/bbq.zig"),
    });

    const bbq_lib = b.addLibrary(.{
        .name = "bbq",
        .linkage = .static,
        .root_module = bbq_module,
    });

    b.installArtifact(bbq_lib);
}
