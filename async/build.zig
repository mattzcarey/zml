const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const use_threaded = b.option(bool, "THREADED", "indicates whether async will be threaded") orelse true;

    const libcoro = b.dependency("zigcoro", .{
        .target = target,
        .optimize = optimize,
    }).module("libcoro");

    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    }).artifact("libxev");

    _ = b.addModule("asynk", .{
        .root_source_file = if (use_threaded) b.path("threaded.zig") else b.path("zigcoro.zig"),
        .imports = &.{
            .{ .name = "libcoro", .module = libcoro },
            .{ .name = "libxev", .module = libxev },
        },
    });
}
