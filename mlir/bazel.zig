const std = @import("std");

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

pub fn configTranslateC(b: *std.Build, translate_c: *std.Build.Step.TranslateC, dep: []const u8) !void {
    const query_res = try std.process.Child.run(.{
        .argv = &.{ "bazel", "query", "--output=location", "'deps(", dep, ")'" },
        .allocator = b.allocator,
    });
    std.debug.print("query_res.stdout: {s}\n", .{query_res.stdout});
    var include_dirs: std.StringArrayHashMapUnmanaged(void) = undefined;
    var line_iter = std.mem.splitScalar(u8, query_res.stdout, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, ":1:1: source file ")) |end| {
            const hdr_path = line[0..end];
            std.debug.print("hdr_path: {s}\n", .{hdr_path});
            if (!std.mem.eql(u8, std.fs.path.extension(hdr_path), ".h")) continue;
            if (std.fs.path.dirname(hdr_path)) |dirname| {
                if (std.mem.indexOf(u8, dirname, "/include/")) |pos| {
                    const include_dir_path = dirname[0 .. pos + "/include".len];
                    const entry = try include_dirs.getOrPut(b.allocator, include_dir_path);
                    if (!entry.found_existing) translate_c.addIncludePath(b.path(include_dir_path));
                }
            }
        }
    }
}
