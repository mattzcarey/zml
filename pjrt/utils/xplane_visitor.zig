const math_utils = @import("math_utils.zig");
const std = @import("std");
const xplane_proto = @import("//tsl:xplane_proto");
const xplane_schema = @import("xplane_schema.zig");

pub const XStatVisitor = struct {
    stat: *const xplane_proto.XStat,
    metadata: *const xplane_proto.XStatMetadata,
    plane: *const XPlaneVisitor,
    type_: ?xplane_schema.StatType = null,

    pub fn init(plane: *const XPlaneVisitor, stat: *const xplane_proto.XStat) XStatVisitor {
        return XStatVisitor.internalInit(
            plane,
            stat,
            plane.getStatMetadata(stat.metadata_id),
            plane.getStatType(stat.metadata_id),
        );
    }

    pub fn internalInit(
        plane: *const XPlaneVisitor,
        stat: *const xplane_proto.XStat,
        metadata: *const xplane_proto.XStatMetadata,
        type_: ?xplane_schema.StatType,
    ) XStatVisitor {
        return .{
            .stat = stat,
            .metadata = metadata,
            .plane = plane,
            .type_ = type_,
        };
    }

    pub fn id(self: *const XStatVisitor) i64 {
        return self.stat.metadata_id;
    }

    pub fn name(self: *const XStatVisitor) []const u8 {
        return self.metadata.name.getSlice();
    }

    pub fn @"type"(self: *const XStatVisitor) ?xplane_schema.StatType {
        return self.type_;
    }

    pub fn description(self: *const XStatVisitor) []const u8 {
        return self.metadata.description.getSlice();
    }

    pub fn boolValue(self: *const XStatVisitor) bool {
        return self.intValue() != 0;
    }

    pub fn intValue(self: *const XStatVisitor) i64 {
        return self.stat.value.?.int64_value;
    }

    pub fn uintValue(self: *const XStatVisitor) u64 {
        return self.stat.value.?.uint64_value;
    }

    pub fn bytesValue(self: *const XStatVisitor) []const u8 {
        return self.stat.value.?.bytes_value.getSlice();
    }

    pub fn intOrUintValue(self: *const XStatVisitor) u64 {
        return switch (self.stat.value.?) {
            .uint64_value => self.uintValue(),
            else => @intCast(self.intValue()),
        };
    }

    pub fn doubleValue(self: *const XStatVisitor) f64 {
        return self.stat.value.?.double_value;
    }

    pub fn strOrRefValue(self: *const XStatVisitor) []const u8 {
        if (self.stat.value) |value| {
            return switch (value) {
                .str_value => |v| v.getSlice(),
                // TODO: implement `getStatMetadata`
                .ref_value => |v| self.plane_.getStatMetadata(v).name.getSlice(),
                inline else => &[_]u8{},
            };
        } else return &[_]u8{};
    }

    pub fn rawStat(self: *const XStatVisitor) xplane_proto.XStat {
        return self.stat_.*;
    }

    pub fn toString(self: *const XStatVisitor, allocator: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).init(allocator);
        var writer = out.writer();
        if (self.stat.value) |vc| {
            switch (vc) {
                inline .int64_value, .uint64_value, .double_value => |v| try writer.print("{d}", .{v}),
                .str_value => |v| try writer.writeAll(v.getSlice()),
                .bytes_value => try writer.writeAll("<opaque bytes>"),
                .ref_value => |v| try writer.writeAll(self.plane.getStatMetadata(@intCast(v)).name.getSlice()),
            }
        }
        return out.toOwnedSlice();
    }
};

pub const XLineVisitor = struct {
    plane_: *const XPlaneVisitor,
    line_: *const xplane_proto.XLine,

    pub fn init(plane: *const XPlaneVisitor, line: *const xplane_proto.XLine) XLineVisitor {
        return .{
            .plane_ = plane,
            .line_ = line,
        };
    }

    pub fn id(self: *const XLineVisitor) i64 {
        return self.line_.display_id;
    }

    pub fn displayId(self: *const XLineVisitor) i64 {
        return if (self.line_.display_id != 0) self.line_.display_id else self.id();
    }

    pub fn name(self: *const XLineVisitor) []const u8 {
        return self.line_.name.getSlice();
    }

    pub fn displayName(self: *const XLineVisitor) []const u8 {
        return if (self.line_.display_name != .Empty) self.line_.display_name.getSlice() else self.name();
    }

    pub fn timestampNs(self: *const XLineVisitor) i64 {
        return self.line_.timestamp_ns;
    }

    pub fn durationPs(self: *const XLineVisitor) i64 {
        return self.line_.duration_ps;
    }

    pub fn numEvents(self: *const XLineVisitor) usize {
        return self.line_.events.len;
    }

    pub fn forEachEvent(
        self: *const XLineVisitor,
        allocator: std.mem.Allocator,
        cb: fn (allocator: std.mem.Allocator, event: XEventVisitor, ctx: ?*anyopaque) std.mem.Allocator.Error!void,
        ctx: ?*anyopaque,
    ) !void {
        for (self.line_.events.items) |*event| {
            std.debug.print("{any}\n", .{event.*});
            try cb(allocator, XEventVisitor.init(self.plane_, self.line_, event), ctx);
        }
    }
};

pub const XEventMetadataVisitor = struct {
    plane: *const XPlaneVisitor,
    stats_owner: *const xplane_proto.XEventMetadata,

    pub fn init(plane: *const XPlaneVisitor, metadata: *const xplane_proto.XEventMetadata) XEventMetadataVisitor {
        return .{
            .plane = plane,
            .stats_owner = metadata,
        };
    }

    pub fn forEachStat(
        self: *const XEventMetadataVisitor,
        allocator: std.mem.Allocator,
        cb: fn (allocator: std.mem.Allocator, xstat: XStatVisitor, ctx: ?*anyopaque) std.mem.Allocator.Error!void,
        ctx: ?*anyopaque,
    ) !void {
        for (self.stats_owner.stats.items) |*stat| {
            try cb(allocator, XStatVisitor.init(self.plane, stat), ctx);
        }
    }
};

pub const XEventVisitor = struct {
    plane: *const XPlaneVisitor,
    line: *const xplane_proto.XLine,
    event: *const xplane_proto.XEvent,
    metadata: *const xplane_proto.XEventMetadata,
    type_: ?xplane_schema.HostEventType,

    pub fn init(
        plane: *const XPlaneVisitor,
        line: *const xplane_proto.XLine,
        event: *const xplane_proto.XEvent,
    ) XEventVisitor {
        return .{
            .plane = plane,
            .line = line,
            .event = event,
            .metadata = plane.getEventMetadata(event.metadata_id),
            .type_ = plane.getEventType(event.metadata_id),
        };
    }

    pub fn hasDisplayName(self: *const XEventVisitor) bool {
        return self.metadata.display_name != .Empty;
    }

    pub fn displayName(self: *const XEventVisitor) []const u8 {
        return self.metadata.display_name.getSlice();
    }

    pub fn name(self: *const XEventVisitor) []const u8 {
        return self.metadata.name.getSlice();
    }

    pub fn timestampPs(self: *const XEventVisitor) i64 {
        std.debug.print("{d} {d}\n", .{ self.line.timestamp_ns, self.event.data.?.offset_ps });
        return (math_utils.nanoToPico(i64, self.line.timestamp_ns) catch 0) + self.event.data.?.offset_ps;
    }

    pub fn durationPs(self: *const XEventVisitor) i64 {
        return self.event.duration_ps;
    }

    pub fn metadataVisitor(self: *const XEventVisitor) XEventMetadataVisitor {
        return XEventMetadataVisitor.init(self.plane, self.metadata);
    }

    pub fn forEachStat(
        self: *const XEventVisitor,
        allocator: std.mem.Allocator,
        cb: fn (allocator: std.mem.Allocator, xstat: XStatVisitor, ctx: ?*anyopaque) std.mem.Allocator.Error!void,
        ctx: ?*anyopaque,
    ) !void {
        for (self.event.stats.items) |*stat| {
            try cb(allocator, XStatVisitor.init(self.plane, stat), ctx);
        }
    }
};

pub const XPlaneVisitor = struct {
    plane: *const xplane_proto.XPlane,
    event_type_by_id: std.AutoHashMap(i64, i64),
    stat_type_by_id: std.AutoHashMap(i64, i64),
    stat_metadata_by_type: std.AutoHashMap(i64, *xplane_proto.XStatMetadata),

    pub fn init(
        allocator: std.mem.Allocator,
        plane: *const xplane_proto.XPlane,
        event_type_getter_list: []const *const fn ([]const u8) ?i64,
        stat_type_getter_list: []const *const fn ([]const u8) ?i64,
    ) !XPlaneVisitor {
        var res: XPlaneVisitor = .{
            .plane = plane,
            .event_type_by_id = std.AutoHashMap(i64, i64).init(allocator),
            .stat_type_by_id = std.AutoHashMap(i64, i64).init(allocator),
            .stat_metadata_by_type = std.AutoHashMap(i64, *xplane_proto.XStatMetadata).init(allocator),
        };
        try res.buildEventTypeMap(plane, event_type_getter_list);
        try res.buildStatTypeMap(plane, stat_type_getter_list);
        return res;
    }

    pub fn deinit(self: *XPlaneVisitor) void {
        self.event_type_by_id.deinit();
        self.stat_type_by_id.deinit();
        self.stat_metadata_by_type.deinit();
    }

    pub fn buildEventTypeMap(
        self: *XPlaneVisitor,
        plane: *const xplane_proto.XPlane,
        event_type_getter_list: []const *const fn ([]const u8) ?i64,
    ) !void {
        if (event_type_getter_list.len == 0) return;
        for (plane.event_metadata.items) |event_metadata| {
            const metadata_id = event_metadata.key;
            const metadata = event_metadata.value.?;
            for (event_type_getter_list) |event_type_getter| {
                if (event_type_getter(metadata.name.getSlice())) |event_type| {
                    try self.event_type_by_id.put(metadata_id, event_type);
                    break;
                }
            }
        }
    }

    pub fn buildStatTypeMap(
        self: *XPlaneVisitor,
        plane: *const xplane_proto.XPlane,
        stat_type_getter_list: []const *const fn ([]const u8) ?i64,
    ) !void {
        if (stat_type_getter_list.len == 0) return;
        for (plane.stat_metadata.items) |stat_metadata| {
            const metadata_id = stat_metadata.key;
            const metadata = stat_metadata.value.?;
            for (stat_type_getter_list) |stat_type_getter| {
                if (stat_type_getter(metadata.name.getSlice())) |stat_type| {
                    try self.stat_type_by_id.put(metadata_id, stat_type);
                    break;
                }
            }
        }
    }

    pub fn getEventMetadata(self: *const XPlaneVisitor, event_metadata_id: i64) *const xplane_proto.XEventMetadata {
        for (self.plane.event_metadata.items) |event_metadata| {
            if (event_metadata.value) |*v| {
                if (v.id == event_metadata_id) return v;
            }
        }

        return &xplane_proto.XEventMetadata.init();
    }

    pub fn getEventType(self: *const XPlaneVisitor, event_metadata_id: i64) ?xplane_schema.HostEventType {
        if (self.event_type_by_id.get(event_metadata_id)) |event_type| {
            return @enumFromInt(event_type);
        }
        return null;
    }

    pub fn getStatMetadata(self: *const XPlaneVisitor, stat_metadata_id: i64) *const xplane_proto.XStatMetadata {
        for (self.plane.stat_metadata.items) |stat_metadata| {
            if (stat_metadata.value) |*v| {
                if (v.id == stat_metadata_id) return v;
            }
        }
        return &xplane_proto.XStatMetadata.init();
    }

    pub fn getStatType(self: *const XPlaneVisitor, stat_metadata_id: i64) ?xplane_schema.StatType {
        if (self.stat_type_by_id.get(stat_metadata_id)) |stat_type| {
            return @enumFromInt(stat_type);
        }
        return null;
    }

    pub fn forEachLine(
        self: *const XPlaneVisitor,
        allocator: std.mem.Allocator,
        cb: fn (allocator: std.mem.Allocator, xline: XLineVisitor, ctx: ?*anyopaque) std.mem.Allocator.Error!void,
        ctx: ?*anyopaque,
    ) !void {
        for (self.plane.lines.items) |*line| {
            try cb(allocator, XLineVisitor.init(self, line), ctx);
        }
    }
};
