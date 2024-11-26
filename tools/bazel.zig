const std = @import("std");

pub const BazelDep = struct {
    name: []const u8,
    include_path: []const []const u8,
};

pub fn buildBazelDeps(b: *std.Build, c: *std.Build.Step.Compile, comptime dependencies: []const BazelDep) []const u8 {
    inline for (dependencies) |dep| {
        const build_cmd = b.addSystemCommand(&.{"bazel"});
        build_cmd.addArgs(&.{ "build", "-c", "opt", dep.name });
        _ = build_cmd.captureStdOut();

        const query_cmd = b.addSystemCommand(&.{"bazel"});
        // ensure `query_cmd` runs after `build_cmd`
        query_cmd.step.dependOn(&build_cmd.step);
        query_cmd.addArgs(&.{ "cquery", "-c", "opt", "--output=files", dep.name });
        c.step.dependOn(&query_cmd.step);

        // write location of mlx to `mlx_info.txt` for use w include/linking
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(build_cmd.captureStdOut(), .prefix, dep.name).step);

        var path_buffer: [1028]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "zig-out/{s}", .{dep.name});
        const query_file = try std.fs.cwd().openFile(path, .{});
        defer query_file.close();
        std.debug.print("query_file: {s}\n", .{query_file.path});
        const query_info = try query_file.readToEndAlloc(b.allocator, (try query_file.metadata()).size());
        defer b.allocator.free(query_info);

        // ensure deduplication of include paths
        var include_paths = std.StringHashMap(void).init(b.allocator);
        defer include_paths.deinit();
    }
}
