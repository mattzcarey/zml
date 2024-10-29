const flags = @import("tigerbeetle/flags");
const std = @import("std");
const xplane_proto = @import("//tsl:xplane_proto");

const xspaceToJson = @import("xplane_to_trace_events.zig").xspaceToJson;

const CliArgs = struct {
    pub const help =
        \\ llama --path=path_to_profiling_data
    ;
    path: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    const cli_args = flags.parse(&args, CliArgs);

    var prof_file = try std.fs.openFileAbsolute(cli_args.path, .{});
    defer prof_file.close();

    const prof_buffer = try prof_file.readToEndAlloc(allocator, (try prof_file.stat()).size);
    defer allocator.free(prof_buffer);

    try xspaceToJson(allocator, prof_buffer, "fake");
}
