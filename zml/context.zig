const builtin = @import("builtin");
const std = @import("std");
const mlir = @import("mlir");
const c = @import("c");
const runfiles = @import("runfiles");
const runtimes = @import("runtimes");

const platform = @import("platform.zig");
const pjrt = @import("pjrtx.zig");

const available_targets = @import("platform.zig").available_targets;
const Buffer = @import("buffer.zig").Buffer;
const HostBuffer = @import("hostbuffer.zig").HostBuffer;
const Target = @import("platform.zig").Target;
const Platform = @import("platform.zig").Platform;

const log = std.log.scoped(.zml);

const PjrtApiMap = std.EnumArray(Target, ?*const pjrt.Api);
const PlatformsMap = std.EnumArray(Target, ?Platform);

/// Every program using ZML must start with a `zml.Context.init(.{});`
/// The ZML context contains global state to interact with the different
/// devices available on your system.
/// Note that the runtimes available depends on how the program was compiled.
/// For example you need to compile your program with `--//runtimes:cuda=true`
/// to have the CUDA runtime available.
pub const Context = struct {
    var apis = PjrtApiMap.initFill(null);
    var apis_once = std.once(struct {
        fn call() void {
            inline for (comptime std.enums.values(runtimes.Platform)) |t| {
                if (runtimes.load(t)) |api| {
                    Context.apis.set(t, api);
                } else |_| {}
            }
        }
    }.call);

    var mlir_once = std.once(struct {
        fn call() void {
            mlir.registerPasses("Transforms");
        }
    }.call);

    var runfiles_once = std.once(struct {
        fn call_() !void {
            if (std.process.hasEnvVarConstant("RUNFILES_MANIFEST_FILE") or std.process.hasEnvVarConstant("RUNFILES_DIR")) {
                return;
            }

            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            const allocator = arena.allocator();
            defer arena.deinit();

            var envMap = std.process.EnvMap.init(allocator);
            var r = (try runfiles.Runfiles.create(.{ .allocator = allocator })) orelse return;
            try r.environment(&envMap);

            var it = envMap.iterator();
            while (it.next()) |entry| {
                const keyZ = try allocator.dupeZ(u8, entry.key_ptr.*);
                const valueZ = try allocator.dupeZ(u8, entry.value_ptr.*);
                _ = c.setenv(keyZ.ptr, valueZ.ptr, 1);
            }
        }

        fn call() void {
            call_() catch @panic("Unable to init runfiles env");
        }
    }.call);

    platforms: PlatformsMap,

    /// Creates a ZML Context and returns it.
    pub fn init() !Context {
        Context.runfiles_once.call();
        Context.apis_once.call();
        Context.mlir_once.call();

        var platforms = PlatformsMap.initFill(null);
        var num_platforms: u8 = 0;
        var it = Context.apis.iterator();
        while (it.next()) |entry| {
            if (entry.value.*) |api| {
                const target = entry.key;
                const p = Platform.init(target, api) catch |err| {
                    log.err("Failed to load platform .{s}: {}", .{ @tagName(target), err });
                    continue;
                };
                if (p.getDevices().len == 0) {
                    log.err("No device found for platform {} !", .{target});
                    continue;
                }
                if (target == .cuda) {
                    try cuda.registerZmlCustomCalls(p);
                }
                platforms.set(target, p);
                num_platforms += 1;
            }
        }
        if (num_platforms == 0) return error.NotFound;
        return .{
            .platforms = platforms,
        };
    }

    fn platformToLibrary(comptime target: Target) []const u8 {
        const ext = switch (builtin.os.tag) {
            .windows => ".dll",
            .macos, .ios, .watchos => ".dylib",
            else => ".so",
        };
        return switch (target) {
            inline else => "libpjrt_" ++ @tagName(target) ++ ext,
        };
    }

    pub fn pjrtApi(target: Target) *const pjrt.Api {
        return Context.apis.get(target).?;
    }

    pub fn deinit(self: *Context) void {
        var iterator = self.platforms.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.*) |*p| {
                p.deinit();
            }
        }
        self.* = undefined;
    }

    /// Automatically selects the best Platform loaded in the current Context.
    ///
    /// For example, if supported, this will select a platform corresponding to an accelerator (GPU, TPU, ...).
    pub fn autoPlatform(self: *Context) Platform {
        // the last platform is the one that with the high enum number, so considered
        // to be the "best" one
        var platform_: ?Platform = null;
        var iterator = self.platforms.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.*) |p| {
                platform_ = p;
            }
        }
        return platform_ orelse @panic("No platform found !");
    }

    pub const HostCallbackCtx = struct {
        host: HostBuffer,
        platform: Platform,
        mutex: std.Thread.Mutex = std.Thread.Mutex{},
    };
    pub const HostCallback = fn (HostBuffer) void;
};

const cuda = struct {
    pub fn registerZmlCustomCalls(cuda_platform: Platform) !void {
        std.debug.assert(cuda_platform.target == .cuda);

        const registry = cuda_platform.pjrt_api.customCallRegistry().?;
        try registry.register(cuda_platform.pjrt_api, 0, "zmlHostBufferCallback", &hostBufferCallback);
    }

    fn getContext(args: [*]const u8, args_len: usize) struct { *const Context.HostCallback, *Context.HostCallbackCtx } {
        std.debug.assert(args_len == @sizeOf(*anyopaque) * 2);

        const raw_fn_ptr: usize = @bitCast(args[0..@sizeOf(*anyopaque)].*);
        const fn_ptr: *const Context.HostCallback = @ptrFromInt(raw_fn_ptr);

        const raw_ctx_ptr: usize = @bitCast(args[@sizeOf(*anyopaque)..][0..@sizeOf(*anyopaque)].*);
        const ctx_ptr: *Context.HostCallbackCtx = @ptrFromInt(raw_ctx_ptr);
        return .{ fn_ptr, ctx_ptr };
    }

    fn hostBufferCallback(
        stream: *anyopaque,
        buffers: [*]*anyopaque,
        args: [*]const u8,
        args_len: usize,
    ) callconv(.C) void {
        const src: *anyopaque = buffers[0];
        const callback, const ctx = getContext(args, args_len);

        // On cuda stream is cuStream ie a pointer to the internal Cuda stream struct.
        // pjrt.CreateViewOfDeviceBuffer takes a pointer to cuStream.
        // see: https://github.com/openxla/xla/blob/c5346ef5527edcddf194e6d33bcde082f544e8b1/xla/pjrt/pjrt_stream_executor_client.cc#L1307-L1307
        // where stream is dereferenced before calling GetStreamFromExternalStream
        const stream_ptr: *const anyopaque = &@intFromPtr(stream);
        const device_buffer = Buffer.asViewOfDeviceBuffer(ctx.platform, ctx.host.shape(), stream_ptr, src) catch |err| {
            std.debug.print("[ERR] Failed to retrieve device buffer {} with stream={} : {}\n", .{ err, stream, ctx.host.shape() });
            return;
        };

        // Lock because we reuse the ctx.host.data across different callbacks.
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        _ = device_buffer.toHost(@constCast(ctx.host.data)) catch |err| {
            std.debug.print("[ERR] Failed to copy device buffer {} to host: {}\n", .{ err, ctx.host.shape() });
            return;
        };
        callback(ctx.host);
    }
};
