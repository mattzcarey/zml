const std = @import("std");

pub const Helper = struct {
    deps: []Dependency,
};

pub fn init(b: *std.Build) !void {
    var argv = [_][]const u8{ "sh", "bazel.sh" };
    _ = try std.process.Child.run(.{
        .argv = &argv,
        .allocator = b.allocator,
    });
}

pub const Dependency = struct {
    name: []const u8,
    lib_name: []const u8,
    hdr: struct {
        path: std.Build.LazyPath,
        mod_name: []const u8,
        translate_c: *std.Build.Step.TranslateC = undefined,
    },
};

pub fn build(allocator: std.mem.Allocator, dep_name: []const u8) !void {
    // build artifact
    _ = try std.process.Child.run(.{
        .argv = &.{ "bazel", "build", "-c", "opt", dep_name },
        .allocator = allocator,
    });
}

pub fn queryHdrs(allocator: std.mem.Allocator, dep_name: []const u8, known_paths: *std.StringArrayHashMap(void)) !void {
    const query_res = try std.process.Child.run(.{
        .argv = &.{ "bazel", "query", dep_name, "--output=files" },
        .allocator = allocator,
    });

    var line_iter = std.mem.splitScalar(u8, query_res.stdout, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(":1:1: source file")) |pos| {
            try known_paths.put(line[0..pos], {});
        }
    }
}

pub fn link(b: *std.Build, c: *std.Build.Step.Compile, dep_name: []const u8, lib_name: []const u8) !void {
    // query for artifact path
    var cquery_args = [_][]const u8{ "bazel", "cquery", "-c", "opt", "--output=files", dep_name };
    const cquery_res = try std.process.Child.run(.{
        .argv = &cquery_args,
        .allocator = b.allocator,
    });

    // link library
    var line_iter = std.mem.splitScalar(u8, cquery_res.stdout, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const dirname = std.fs.path.dirname(line).?;
        c.addLibraryPath(b.path(b.fmt("../{s}", .{dirname})));
        c.linkSystemLibrary(lib_name);
    }
}

pub fn addIncludeDir(b: *std.Build, translate_c: *std.Build.Step.TranslateC, bazel_dep: []const u8) !void {
    // query for artifact path
    var cquery_args = [_][]const u8{ "bazel", "cquery", "-c", "opt", "--output=files", bazel_dep };
    const cquery_res = try std.process.Child.run(.{
        .argv = &cquery_args,
        .allocator = translate_c.step.owner.allocator,
    });
    defer translate_c.step.owner.allocator.free(cquery_res.stdout);
    defer translate_c.step.owner.allocator.free(cquery_res.stderr);

    // add include path
    var line_iter = std.mem.splitScalar(u8, cquery_res.stdout, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var path_buffer: [1028]u8 = undefined;
        const include_dir = try std.fmt.bufPrint(&path_buffer, "../{s}/include", .{std.fs.path.dirname(line).?});
        translate_c.addIncludePath(b.path(include_dir));
    }
}
