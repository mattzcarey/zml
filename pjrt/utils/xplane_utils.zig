const std = @import("std");
const xplane_proto = @import("//tsl:xplane_proto");

pub fn find(comptime T: type, array: []const T, comptime eqlFn: fn (val: T) bool) ?usize {
    for (array, 0..) |v, i| {
        if (eqlFn(v)) return i;
    }
    return null;
}

pub fn findPlaneWithName(space: xplane_proto.XSpace, name: []const u8) ?*xplane_proto.XPlane {
    for (space.planes.items) |*v| {
        // std.debug.print("v.name.getSlice(): {s} -- name: {s}\n", .{ v.name.getSlice(), name });
        if (std.mem.eql(u8, v.name.getSlice(), name)) return v;
    }
    return null;
}

pub fn findPlanesWithPrefix(
    allocator: std.mem.Allocator,
    space: xplane_proto.XSpace,
    prefix: []const u8,
) !std.ArrayList(*const xplane_proto.XPlane) {
    var res = std.ArrayList(*const xplane_proto.XPlane).init(allocator);
    for (space.planes.items) |*p| {
        if (std.mem.startsWith(u8, p.name.getSlice(), prefix)) try res.append(p);
    }
    return res;
}
