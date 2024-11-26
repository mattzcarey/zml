const bazel = @import("bazel.zig");
const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const mlir_module = b.addModule("mlir", .{
        .root_source_file = b.path("mlir.zig"),
    });

    const stablehlo_module = b.addModule("mlir/dialects/stablehlo", .{
        .root_source_file = b.path("stablehlo.zig"),
        .imports = &.{
            .{ .name = "mlir", .module = mlir_module },
        },
    });

    const dialects_module = b.addModule("mlir/dialects", .{
        .root_source_file = b.path("dialects/dialects.zig"),
        .imports = &.{
            .{ .name = "mlir", .module = mlir_module },
            .{ .name = "mlir/dialects/stablehlo", .module = stablehlo_module },
        },
    });

    // init bazel
    try bazel.init(b);

    try bazel.build(b.allocator, "//mlir:mlirx");
    try bazel.build(b.allocator, "//mlir:c");
    try bazel.build(b.allocator, "@stablehlo//:stablehlo_capi");

    const lib = b.addStaticLibrary(.{
        .name = "mlir",
        .root_source_file = b.path("mlir.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // build c deps w bazel
    try bazel.link(b, lib, "//mlir:mlirx", "mlirx");
    try bazel.link(b, lib, "//mlir:c", "c");
    try bazel.link(b, lib, "@stablehlo//:stablehlo_capi", "stablehlo_capi");

    const mlir_c_translated = b.addTranslateC(.{
        .root_source_file = b.path("mlir.h"),
        .target = target,
        .optimize = optimize,
    });

    const mlirx_translated = b.addTranslateC(.{
        .root_source_file = b.path("mlirx.h"),
        .target = target,
        .optimize = optimize,
    });

    // TODO: this returns path, but missing absolute path prefix
    try bazel.addIncludeDir(b, mlir_c_translated, "//mlir:mlirx");
    try bazel.addIncludeDir(b, mlirx_translated, "//mlir:mlirx");

    const install_lib = b.addInstallArtifact(lib, .{});
    b.getInstallStep().dependOn(&install_lib.step);

    mlir_c_translated.step.dependOn(&install_lib.step);
    mlirx_translated.step.dependOn(&install_lib.step);

    const wf = b.addWriteFiles();

    const c_file = wf.add("c.zig",
        \\pub usingnamespace @import("mlirx");
        \\pub usingnamespace @import("c");
    );

    const c = b.addModule("c", .{
        .root_source_file = c_file,
        .imports = &.{
            .{ .name = "c", .module = mlir_c_translated.createModule() },
            .{ .name = "mlirx", .module = mlirx_translated.createModule() },
        },
    });

    mlir_module.addImport("c", c);
    stablehlo_module.addImport("c", c);

    const test_file = wf.add("tests.zig",
        \\const std = @import("std");
        \\test {
        \\    std.testing.refAllDecls(@import("mlir"));
        \\    std.testing.refAllDecls(@import("mlir/dialects"));
        \\    std.testing.refAllDecls(@import("mlir/dialects/stablehlo"));
        \\}
    );

    const tests = b.addTest(.{
        .root_source_file = test_file,
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("mlir", mlir_module);
    tests.root_module.addImport("mlir/dialects", dialects_module);
    tests.root_module.addImport("mlir/dialects/stablehlo", stablehlo_module);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run mlir tests");
    test_step.dependOn(&run_tests.step);
}
