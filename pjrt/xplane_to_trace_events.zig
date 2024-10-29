const std = @import("std");
const tf_op_utils = @import("utils/tf_op_utils.zig");
const xplane_schema = @import("utils/xplane_schema.zig");
const xplane_visitor = @import("utils/xplane_visitor.zig");
const trace_events_proto = @import("//tsl:trace_events_proto");
const trace_utils = @import("utils/trace_utils.zig");
const xplane_proto = @import("//tsl:xplane_proto");
const math_utils = @import("utils/math_utils.zig");
const xplane_utils = @import("utils/xplane_utils.zig");

const XPlaneVisitor = xplane_visitor.XPlaneVisitor;

pub const TraceContainer = struct {
    arena: std.heap.ArenaAllocator,
    metadata_: trace_events_proto.Trace = trace_events_proto.Trace.init(),
    events_: std.ArrayList(*trace_events_proto.TraceEvent),

    pub fn init(allocator: std.mem.Allocator) TraceContainer {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .events_ = std.ArrayList(*trace_events_proto.TraceEvent).init(allocator),
        };
    }

    pub fn deinit(self: TraceContainer) void {
        self.events_.deinit();
        self.arena.deinit();
    }

    pub fn createEvent(self: *TraceContainer) !*trace_events_proto.TraceEvent {
        const event = try self.arena.allocator().create(trace_events_proto.TraceEvent);
        event.* = trace_events_proto.TraceEvent.init();
        try self.events_.append(event);
        return event;
    }

    pub fn mutableDevice(self: *TraceContainer, allocator: std.mem.Allocator, device_id: u32) !*trace_events_proto.Device {
        try self.metadata_.devices.ensureTotalCapacity(allocator, device_id + 1);
        self.metadata_.devices.expandToCapacity();
        self.metadata_.devices.items[device_id] = .{ .key = device_id, .value = trace_events_proto.Device.init() };
        return &self.metadata_.devices.items[device_id].value.?;
    }

    pub fn capEvents(self: *TraceContainer, max_count: u64) void {
        const total_count = self.events_.items.len;
        if (total_count <= max_count) {
            // Nothing to do. Events are not known sorted after return.
            return;
        }
        // Partially sort the events according to start time.
        std.mem.sort(*trace_events_proto.TraceEvent, self.events_.items, {}, struct {
            pub fn call(_: void, lhs: *trace_events_proto.TraceEvent, rhs: *trace_events_proto.TraceEvent) bool {
                return lhs.timestamp_ps < rhs.timestamp_ps;
            }
        }.call);
        //  leave for arena?
        // for (self.events_.items[max_count..]) |event| {
        //     event.deinit(allocator);
        //     allocator.destroy(event);
        // }
        self.events_.shrinkRetainingCapacity(max_count);
    }
};

fn buildDeviceAndResources(
    allocator: std.mem.Allocator,
    device_id: u32,
    plane: XPlaneVisitor,
    device: *trace_events_proto.Device,
) !void {
    // TODO: verify this isn't going to leak
    device.name = .{ .Const = plane.plane.name.getSlice() };
    device.device_id = device_id;

    const sort_by_ordinal = (device_id == trace_utils.kHostThreadsDeviceId);
    var ordinal: u32 = 0;
    // try plane.forEachLine()
    for (plane.plane.lines.items) |line| {
        const resource_id: u32 = @intCast(line.display_id);
        try device.resources.ensureTotalCapacity(allocator, resource_id + 1);
        device.resources.expandToCapacity();
        device.resources.items[resource_id] = .{ .key = resource_id, .value = trace_events_proto.Resource.init() };
        var resource = &device.resources.items[resource_id].value.?;
        resource.resource_id = resource_id;
        // TODO: verify this isn't going to leak
        resource.name = .{ .Const = line.display_name.getSlice() };
        if (sort_by_ordinal) {
            // When sort_index is absent (i.e. 0), resource id will be used.
            // Therefore sort_index starts with 1.
            ordinal += 1;
            resource.sort_index = ordinal;
        }
    }
}

fn xplaneToTraceEvents(allocator: std.mem.Allocator, device_id: u32, xplane: XPlaneVisitor, container: *TraceContainer) !void {
    // std.debug.print("xplaneToTraceEvents\n", .{});
    // Convert devices and resources.
    try buildDeviceAndResources(allocator, device_id, xplane, try container.mutableDevice(allocator, device_id));

    // Convert events.
    var line_ctx: std.meta.Tuple(&.{ u32, *TraceContainer }) = .{ device_id, container };
    try xplane.forEachLine(allocator, struct {
        pub fn call(a1: std.mem.Allocator, xline: xplane_visitor.XLineVisitor, l_ctx: ?*anyopaque) !void {
            const parsed_line_ctx: *std.meta.Tuple(&.{ u32, *TraceContainer }) = @ptrCast(@alignCast(l_ctx));
            const resource_id: u32 = @intCast(xline.displayId());
            if (std.mem.eql(u8, xline.displayName(), xplane_schema.kXlaAsyncOpLineName)) return;
            var evt_ctx: std.meta.Tuple(&.{ u32, u32, *TraceContainer }) = .{ parsed_line_ctx[0], resource_id, parsed_line_ctx[1] };
            try xline.forEachEvent(a1, struct {
                pub fn call(a2: std.mem.Allocator, xevent: xplane_visitor.XEventVisitor, e_ctx: ?*anyopaque) !void {
                    std.debug.print("callback executing\n", .{});
                    const parsed_event_ctx: *std.meta.Tuple(&.{ u32, u32, *TraceContainer }) = @ptrCast(@alignCast(e_ctx));
                    const event_type: ?xplane_schema.HostEventType = xevent
                        .type_ orelse .kUnknownHostEventType;
                    if (xplane_schema.isInternalEvent(event_type)) return;
                    var event = try parsed_event_ctx[2].createEvent();
                    var args = &event.args;
                    event.device_id = parsed_event_ctx[0];
                    event.resource_id = parsed_event_ctx[1];
                    if (xevent.hasDisplayName()) {
                        event.name = .{ .Const = xevent.displayName() };
                        try args.append(a2, .{ .key = .{ .Const = "long_name" }, .value = .{ .Const = xevent.name() } });
                    } else {
                        event.name = .{ .Const = xevent.name() };
                    }
                    event.timestamp_ps = @intCast(xevent.timestampPs());
                    event.duration_ps = @intCast(xevent.durationPs());

                    var stat_ctx: std.meta.Tuple(&.{ *trace_events_proto.TraceEvent, *std.ArrayListUnmanaged(trace_events_proto.TraceEvent.ArgsEntry) }) = .{ event, args };
                    const for_each_stat = struct {
                        pub fn call(a3: std.mem.Allocator, xstat: xplane_visitor.XStatVisitor, s_ctx: ?*anyopaque) !void {
                            const parsed_stat_ctx: *std.meta.Tuple(&.{ *trace_events_proto.TraceEvent, *std.ArrayListUnmanaged(trace_events_proto.TraceEvent.ArgsEntry) }) = @ptrCast(@alignCast(s_ctx));

                            if (xstat.stat.value == null) return;
                            if (xplane_schema.isInternalStat(xstat.type())) return;
                            if (xstat.type() == .kStepName) {
                                parsed_stat_ctx[0].name = .{ .Owned = try xstat.toString(a3) };
                            }
                            try parsed_stat_ctx[1].append(a3, .{ .key = .{ .Const = xstat.name() }, .value = .{ .Owned = try xstat.toString(a3) } });
                        }
                    }.call;
                    try xevent.metadataVisitor().forEachStat(a2, for_each_stat, &stat_ctx);
                    try xevent.forEachStat(a2, for_each_stat, &stat_ctx);
                }
            }.call, &evt_ctx);
        }
    }.call, &line_ctx);
}

fn xspaceToTraceContainer(allocator: std.mem.Allocator, xspace: xplane_proto.XSpace) !TraceContainer {
    var container = TraceContainer.init(allocator);
    if (xplane_utils.findPlaneWithName(xspace, xplane_schema.kHostThreadsPlaneName)) |hp| {
        std.debug.print("host plane found\n", .{});
        var xplane = try XPlaneVisitor.init(
            allocator,
            hp,
            &.{ xplane_schema.findHostEventType, xplane_schema.findTfOpEventType },
            &.{xplane_schema.findStatType},
        );
        defer xplane.deinit();
        try xplaneToTraceEvents(allocator, trace_utils.kHostThreadsDeviceId, xplane, &container);
    }

    var device_planes = try xplane_utils.findPlanesWithPrefix(allocator, xspace, xplane_schema.kGpuPlanePrefix);
    defer device_planes.deinit();
    // We don't expect GPU and TPU planes and custom devices to be present in the
    // same XSpace.
    if (device_planes.items.len == 0) {
        device_planes = try xplane_utils.findPlanesWithPrefix(allocator, xspace, xplane_schema.kTpuPlanePrefix);
    }
    if (device_planes.items.len == 0) {
        device_planes = try xplane_utils.findPlanesWithPrefix(allocator, xspace, xplane_schema.kCustomPlanePrefix);
    }
    for (device_planes.items) |device_plane| {
        var xplane = try XPlaneVisitor.init(
            allocator,
            device_plane,
            &.{ xplane_schema.findHostEventType, xplane_schema.findTfOpEventType },
            &.{xplane_schema.findStatType},
        );
        defer xplane.deinit();
        const device_id: u32 = trace_utils.kFirstDeviceId + @as(u32, @intCast(xplane.plane.id));
        try xplaneToTraceEvents(allocator, device_id, xplane, &container);
    }

    // Trace viewer (non-streaming) has scalability issues, we need to drop
    // events to avoid loading failure for trace viewer.
    const viewer_max_events = try getTraceViewerMaxEvents();
    container.capEvents(viewer_max_events);

    return container;
}

pub fn getTraceViewerMaxEvents() !u64 {
    const kMaxEvents = 1000000;
    if (std.posix.getenv("TF_PROFILER_TRACE_VIEWER_MAX_EVENTS")) |max_events| {
        return std.fmt.parseInt(u64, max_events, 10);
    } else return kMaxEvents;
}

pub fn xspaceToJson(allocator: std.mem.Allocator, input: []const u8, output_path: []const u8) !void {
    _ = output_path; // autofix
    if (input.len == 0) return error.EmptyBuffer;

    var xspace = try xplane_proto.XSpace.decode(input, allocator);
    defer xspace.deinit(allocator);

    var events: usize = 0;

    for (xspace.planes.items) |plane| {
        for (plane.lines.items) |line| {
            events += line.events.items.len;
        }
    }

    std.debug.print("Found {d} events across {d} spaces.\n", .{ events, xspace.planes.items.len });

    var container = try xspaceToTraceContainer(allocator, xspace);
    defer container.deinit();
    const out = try traceContainerToJson(allocator, container);
    defer allocator.free(out);
    std.debug.print("{s}\n", .{out});
}

pub fn sortByKey(
    allocator: std.mem.Allocator,
    comptime T: type,
    a: std.ArrayListUnmanaged(T),
) ![]const *const T {
    const pairs = try allocator.alloc(*const T, a.items.len);
    for (a.items, 0..) |*pair, i| {
        pairs[i] = pair;
    }
    std.mem.sort(
        *const T,
        pairs,
        {},
        struct {
            pub fn call(_: void, lhs: *const T, rhs: *const T) bool {
                return lhs.key < rhs.key;
            }
        }.call,
    );
    return pairs;
}

pub fn traceContainerToJson(allocator: std.mem.Allocator, container: TraceContainer) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    var writer = buffer.writer();
    try writer.writeAll(
        \\{"displayTimeUnit":"ns","metadata":{"highres-ticks":true},"traceEvents":[
    );

    // TODO: finish implementing
    const pairs = try sortByKey(allocator, trace_events_proto.Trace.DevicesEntry, container.metadata_.devices);
    defer allocator.free(pairs);
    for (pairs) |id_and_device| {
        const device_id = id_and_device.key;
        const device = id_and_device.value.?;
        if (device.name != .Empty) {
            try writer.print(
                \\{{"ph":"M","pid":{d},"name":"process_name","args":{{"name":"{s}"}}}},
            , .{ device_id, device.name.getSlice() });
        }
        try writer.print(
            \\{{"ph":"M","pid":{d},"name":"process_sort_index","args":{{"sort_index":{d}}}}},
        , .{
            device_id,
            device_id,
        });
        const resources = try sortByKey(allocator, trace_events_proto.Device.ResourcesEntry, device.resources);
        defer allocator.free(resources);
        for (resources) |id_and_resource| {
            const resource_id = id_and_resource.key;
            const resource = id_and_resource.value.?;
            if (resource.name != .Empty) {
                try writer.print(
                    \\{{"ph":"M","pid":{d},"tid":{d},"name":"thread_name","args":{{"name":"{s}"}}}},
                , .{
                    device_id,
                    resource_id,
                    resource.name.getSlice(),
                });
            }
            const sort_index = if (resource.sort_index != 0) resource.sort_index else resource_id;
            try writer.print(
                \\{{"ph":"M","pid":{d},"tid":{d},"name":"thread_sort_index","args":{{"sort_index":{d}}}}},
            , .{ device_id, resource_id, sort_index });
        }
    }
    std.debug.print("container.events_.items.len: {d}\n", .{container.events_.items.len});
    for (container.events_.items) |event| {
        const duration_ps = @max(event.duration_ps, 1);
        try writer.print(
            \\{{"ph":"X","pid":{d},"tid":{d},"ts":{d:.17},"dur":{d:.17},"name":"{s}"
        , .{
            event.device_id,
            event.resource_id,
            math_utils.picoToMicro(event.timestamp_ps),
            math_utils.picoToMicro(duration_ps),
            event.name.getSlice(),
        });
        if (event.args.items.len != 0) {
            try writer.writeAll(
                \\,"args":{
            );
            const sorted_args = try allocator.alloc(*const trace_events_proto.TraceEvent.ArgsEntry, event.args.items.len);
            defer allocator.free(sorted_args);
            for (event.args.items, 0..) |*arg, i| {
                sorted_args[i] = arg;
            }
            std.mem.sort(*const trace_events_proto.TraceEvent.ArgsEntry, sorted_args, {}, struct {
                pub fn call(_: void, lhs: *const trace_events_proto.TraceEvent.ArgsEntry, rhs: *const trace_events_proto.TraceEvent.ArgsEntry) bool {
                    return std.mem.order(u8, lhs.key.getSlice(), rhs.key.getSlice()).compare(std.math.CompareOperator.lt);
                }
            }.call);
            for (sorted_args) |arg| {
                try writer.print(
                    \\"{s}":"{s}",
                , .{ arg.key.getSlice(), arg.value.getSlice() });
            }

            // Replace trailing comma with closing brace.
            buffer.items[buffer.items.len - 1] = '}';
        }
        try writer.writeAll("},");
    }
    try writer.writeAll("{}]}");
    return buffer.toOwnedSlice();
}
