const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zml",
        .root_source_file = b.path("zml/zml.zig"),
        .target = target,
        .optimize = optimize,
    });

    // register modules
    const asynk_module = b.dependency("async", .{
        .target = target,
        .optimize = optimize,
    }).module("async");

    const mlir_dep = b.dependency("mlir", .{
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibrary(mlir_dep.artifact("mlir"));

    lib.root_module.addImport("async", asynk_module);
    lib.root_module.addImport("stdx", b.dependency("stdx", .{
        .target = target,
        .optimize = optimize,
    }).module("stdx"));
    lib.root_module.addImport("mlir", mlir_dep.module("mlir"));
    lib.root_module.addImport("mlir/dialects", mlir_dep.module("mlir/dialects"));
    lib.root_module.addImport("mlir/dialects/stablehlo", mlir_dep.module("mlir/dialects/stablehlo"));

    // exposes `async` as a module when depending on `zml`
    try b.modules.put(b.dupe("async"), asynk_module);

    b.installArtifact(lib);
}
