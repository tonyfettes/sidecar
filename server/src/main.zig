const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const server_mod = @import("server.zig");

const Config = struct {
    port: u16,
    token: [protocol.token_len]u8,
    max_frame_size: u32 = protocol.default_max_frame_size,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cfg = parseConfig(init) catch |err| {
        std.log.err("invalid arguments: {}", .{err});
        return err;
    };

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(cfg.port) };
    const stream = try addr.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(io);

    enableTcpNoDelay(stream.socket.handle);

    var srv = server_mod.Server.init(gpa, io, stream, cfg.max_frame_size);
    defer srv.deinit();

    try srv.run(cfg.token);
}

fn parseConfig(init: std.process.Init) !Config {
    var port: ?u16 = null;
    var token_hex: ?[]const u8 = init.environ_map.get("SIDECAR_TOKEN");
    var max_frame_size: u32 = protocol.default_max_frame_size;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip(); // argv[0]

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse return error.MissingPort;
            port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, arg, "--token")) {
            token_hex = args.next() orelse return error.MissingToken;
        } else if (std.mem.eql(u8, arg, "--max-frame-size")) {
            const val = args.next() orelse return error.MissingMaxFrameSize;
            max_frame_size = try std.fmt.parseInt(u32, val, 10);
        } else {
            return error.UnknownArgument;
        }
    }

    const p = port orelse return error.MissingPort;
    const hex = token_hex orelse return error.MissingToken;
    const tok = try protocol.parseHexToken(hex);

    return .{
        .port = p,
        .token = tok,
        .max_frame_size = max_frame_size,
    };
}

fn enableTcpNoDelay(handle: std.Io.net.Socket.Handle) void {
    const one: i32 = 1;
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const win_setsockopt = struct {
            extern "ws2_32" fn setsockopt(
                s: std.Io.net.Socket.Handle,
                level: i32,
                optname: i32,
                optval: ?[*]const u8,
                optlen: i32,
            ) callconv(.winapi) i32;
        };
        _ = win_setsockopt.setsockopt(
            handle,
            ws2.IPPROTO.TCP,
            ws2.TCP.NODELAY,
            std.mem.asBytes(&one).ptr,
            @sizeOf(i32),
        );
    } else {
        std.posix.setsockopt(
            handle,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&one),
        ) catch {};
    }
}
