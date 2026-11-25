const std = @import("std");
const protocol = @import("protocol.zig");
const dynlib = @import("dynlib.zig");

const CallState = struct {
    gpa: std.mem.Allocator,
    max_frame_size: u32,
    closing_flag: *const std.atomic.Value(bool),
    cancelled: std.atomic.Value(bool) = .init(false),
    /// First `protocol.header_len` (12) bytes reserved for the CALLED header.
    out_buf: std.ArrayList(u8) = .empty,
    /// First `protocol.header_len + 2` (14) bytes reserved for ERROR header + u16le code.
    err_buf: std.ArrayList(u8) = .empty,
    reserved_cap: usize = 0,
    overflowed: bool = false,

    fn init(
        gpa: std.mem.Allocator,
        max_frame_size: u32,
        closing_flag: *const std.atomic.Value(bool),
    ) !CallState {
        var state: CallState = .{
            .gpa = gpa,
            .max_frame_size = max_frame_size,
            .closing_flag = closing_flag,
        };
        try state.out_buf.resize(gpa, protocol.header_len);
        errdefer state.out_buf.deinit(gpa);
        try state.err_buf.resize(gpa, protocol.header_len + 2);
        return state;
    }

    fn deinit(self: *CallState) void {
        self.out_buf.deinit(self.gpa);
        self.err_buf.deinit(self.gpa);
    }

    fn fromOpaque(ctx: *dynlib.SidecarCtx) *CallState {
        return @ptrCast(@alignCast(ctx));
    }

    fn toOpaque(self: *CallState) *dynlib.SidecarCtx {
        return @ptrCast(self);
    }

    fn outPayloadLen(self: *const CallState) usize {
        return self.out_buf.items.len - protocol.header_len;
    }

    fn errMsgLen(self: *const CallState) usize {
        return self.err_buf.items.len - (protocol.header_len + 2);
    }
};

fn cWriteOut(ctx: *dynlib.SidecarCtx, data: [*]const u8, len: usize) callconv(.c) c_int {
    const state = CallState.fromOpaque(ctx);
    state.reserved_cap = 0;
    if (len == 0) return 0;
    const cur = state.outPayloadLen();
    if (len > state.max_frame_size or cur > state.max_frame_size - len) {
        state.overflowed = true;
        return -1;
    }
    state.out_buf.appendSlice(state.gpa, data[0..len]) catch {
        state.overflowed = true;
        return -1;
    };
    return 0;
}

fn cReserveOut(ctx: *dynlib.SidecarCtx, cap: usize) callconv(.c) ?[*]u8 {
    const state = CallState.fromOpaque(ctx);
    state.reserved_cap = 0;
    const cur = state.outPayloadLen();
    if (cap > state.max_frame_size or cur > state.max_frame_size - cap) {
        state.overflowed = true;
        return null;
    }
    state.out_buf.ensureUnusedCapacity(state.gpa, cap) catch {
        state.overflowed = true;
        return null;
    };
    state.reserved_cap = cap;
    return state.out_buf.items.ptr + state.out_buf.items.len;
}

fn cCommitOut(ctx: *dynlib.SidecarCtx, written_len: usize) callconv(.c) c_int {
    const state = CallState.fromOpaque(ctx);
    if (written_len > state.reserved_cap) {
        return -1;
    }
    state.out_buf.items.len += written_len;
    state.reserved_cap = 0;
    return 0;
}

fn cWriteErr(ctx: *dynlib.SidecarCtx, data: [*]const u8, len: usize) callconv(.c) c_int {
    const state = CallState.fromOpaque(ctx);
    if (len == 0) return 0;
    const max_err = state.max_frame_size - 2;
    const cur = state.errMsgLen();
    if (len > max_err or cur > max_err - len) {
        return -1;
    }
    state.err_buf.appendSlice(state.gpa, data[0..len]) catch return -1;
    return 0;
}

fn cIsCancelled(ctx: *dynlib.SidecarCtx) callconv(.c) bool {
    const state = CallState.fromOpaque(ctx);
    return state.cancelled.load(.acquire) or state.closing_flag.load(.acquire);
}

const sidecar_api: dynlib.SidecarApi = .{
    .abi_version = protocol.abi_version,
    .write_out = cWriteOut,
    .reserve_out = cReserveOut,
    .commit_out = cCommitOut,
    .write_err = cWriteErr,
    .is_cancelled = cIsCancelled,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    max_frame_size: u32,
    write_mutex: std.Io.Mutex = .init,
    registry: dynlib.Registry,
    closing: std.atomic.Value(bool) = .init(false),
    workers: std.Io.Group = .init,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        max_frame_size: u32,
    ) Server {
        return .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .max_frame_size = max_frame_size,
            .registry = dynlib.Registry.init(gpa),
        };
    }

    pub fn deinit(self: *Server) void {
        self.registry.deinit();
    }

    pub fn run(self: *Server, token: [protocol.token_len]u8) !void {
        defer {
            self.closing.store(true, .release);
            self.workers.await(self.io) catch {};
            self.registry.closeAll(self.io);
        }

        // Send initial HELLO frame with auth token and host platform metadata.
        {
            const hello_payload = try protocol.encodeHelloPayload(self.gpa, token, self.max_frame_size);
            defer self.gpa.free(hello_payload);
            try self.sendFrame(.hello, 0, hello_payload);
        }

        var read_buf: [8192]u8 = undefined;
        var stream_reader = self.stream.reader(self.io, &read_buf);
        const r = &stream_reader.interface;

        while (true) {
            var header_bytes: [protocol.header_len]u8 = undefined;
            r.readSliceAll(&header_bytes) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => break,
            };

            const hdr = protocol.Header.decode(&header_bytes) catch {
                self.sendError(0, .invalid_frame, "invalid protocol version or opcode") catch {};
                break;
            };

            if (hdr.length > self.max_frame_size) {
                self.sendError(hdr.req_id, .frame_too_large, "request frame exceeds max_frame_size") catch {};
                break;
            }

            switch (hdr.op) {
                .load => {
                    const payload = try self.gpa.alloc(u8, hdr.length);
                    defer self.gpa.free(payload);
                    r.readSliceAll(payload) catch break;
                    try self.handleLoad(hdr.req_id, payload);
                },
                .unload => {
                    if (hdr.length != 4) {
                        try drainPayload(r, hdr.length);
                        try self.sendError(hdr.req_id, .invalid_frame, "UNLOAD requires 4-byte lib_id");
                        continue;
                    }
                    var id_bytes: [4]u8 = undefined;
                    r.readSliceAll(&id_bytes) catch break;
                    const lib_id = std.mem.readInt(u32, &id_bytes, .little);
                    self.workers.concurrent(self.io, handleUnloadTask, .{ self, hdr.req_id, lib_id }) catch {
                        handleUnloadTask(self, hdr.req_id, lib_id);
                    };
                },
                .find => {
                    if (hdr.length < 5) {
                        try drainPayload(r, hdr.length);
                        try self.sendError(hdr.req_id, .invalid_frame, "FIND requires lib_id and non-empty symbol");
                        continue;
                    }
                    const payload = try self.gpa.alloc(u8, hdr.length);
                    defer self.gpa.free(payload);
                    r.readSliceAll(payload) catch break;
                    try self.handleFind(hdr.req_id, payload);
                },
                .call => {
                    if (hdr.length < 4) {
                        try drainPayload(r, hdr.length);
                        try self.sendError(hdr.req_id, .invalid_frame, "CALL requires 4-byte func_id");
                        continue;
                    }
                    var fid_bytes: [4]u8 = undefined;
                    r.readSliceAll(&fid_bytes) catch break;
                    const func_id = std.mem.readInt(u32, &fid_bytes, .little);
                    const input_len = hdr.length - 4;
                    // Allocate 16-byte aligned input buffer so C plugins can safely
                    // reinterpret structured inputs without UB.
                    const input = try self.gpa.alignedAlloc(u8, .@"16", input_len);
                    errdefer self.gpa.free(input);
                    r.readSliceAll(input) catch {
                        self.gpa.free(input);
                        break;
                    };
                    self.workers.concurrent(self.io, handleCallTask, .{ self, hdr.req_id, func_id, input }) catch {
                        handleCallTask(self, hdr.req_id, func_id, input);
                    };
                },
                .cancel => {
                    try drainPayload(r, hdr.length);
                    try self.sendError(hdr.req_id, .unsupported, "CANCEL is reserved in protocol v1");
                },
                else => {
                    try drainPayload(r, hdr.length);
                    try self.sendError(hdr.req_id, .invalid_frame, "unexpected opcode from client");
                },
            }
        }
    }

    fn handleLoad(self: *Server, req_id: u32, path: []const u8) !void {
        if (path.len == 0) {
            try self.sendError(req_id, .invalid_frame, "LOAD path must not be empty");
            return;
        }
        const res = self.registry.load(self.io, path) catch {
            try self.sendError(req_id, .frame_too_large, "out of memory loading library");
            return;
        };
        switch (res) {
            .ok => |lib_id| {
                var out: [4]u8 = undefined;
                std.mem.writeInt(u32, &out, lib_id, .little);
                try self.sendFrame(.loaded, req_id, &out);
            },
            .err => |msg| {
                defer self.gpa.free(msg);
                try self.sendError(req_id, .lib_load_failed, msg);
            },
        }
    }

    fn handleFind(self: *Server, req_id: u32, payload: []const u8) !void {
        const lib_id = std.mem.readInt(u32, payload[0..4], .little);
        const symbol = payload[4..];
        const res = self.registry.find(self.io, lib_id, symbol) catch {
            try self.sendError(req_id, .frame_too_large, "out of memory looking up symbol");
            return;
        };
        switch (res) {
            .ok => |func_id| {
                var out: [4]u8 = undefined;
                std.mem.writeInt(u32, &out, func_id, .little);
                try self.sendFrame(.found, req_id, &out);
            },
            .invalid_lib => try self.sendError(req_id, .invalid_lib_id, "invalid or unloaded lib_id"),
            .symbol_not_found => try self.sendError(req_id, .symbol_not_found, "symbol not found"),
        }
    }

    fn handleUnloadTask(self: *Server, req_id: u32, lib_id: u32) void {
        if (self.registry.unload(self.io, lib_id)) {
            self.sendFrame(.unloaded, req_id, &.{}) catch {};
        } else {
            self.sendError(req_id, .invalid_lib_id, "invalid or already unloaded lib_id") catch {};
        }
    }

    fn handleCallTask(self: *Server, req_id: u32, func_id: u32, input: []align(16) u8) void {
        defer self.gpa.free(input);

        const acquired = self.registry.acquireCall(self.io, func_id) orelse {
            self.sendError(req_id, .invalid_func_id, "invalid or unloaded func_id") catch {};
            return;
        };
        defer self.registry.releaseCall(self.io, acquired.lib_id);

        var state = CallState.init(self.gpa, self.max_frame_size, &self.closing) catch {
            self.sendError(req_id, .frame_too_large, "out of memory preparing call") catch {};
            return;
        };
        defer state.deinit();

        const code = acquired.fn_ptr(&sidecar_api, state.toOpaque(), input.ptr, input.len);

        if (code == 0) {
            if (state.overflowed) {
                self.sendError(req_id, .frame_too_large, "plugin output exceeded max_frame_size") catch {};
                return;
            }
            const hdr: protocol.Header = .{
                .op = .called,
                .req_id = req_id,
                .length = @intCast(state.outPayloadLen()),
            };
            hdr.encode(state.out_buf.items[0..protocol.header_len]);
            self.sendRawFrame(state.out_buf.items) catch {};
        } else {
            const payload_len: u32 = @intCast(2 + state.errMsgLen());
            const hdr: protocol.Header = .{
                .op = .@"error",
                .req_id = req_id,
                .length = payload_len,
            };
            hdr.encode(state.err_buf.items[0..protocol.header_len]);
            std.mem.writeInt(u16, state.err_buf.items[protocol.header_len..][0..2], code, .little);
            self.sendRawFrame(state.err_buf.items) catch {};
        }
    }

    fn sendFrame(self: *Server, op: protocol.Op, req_id: u32, payload: []const u8) !void {
        var hdr_bytes: [protocol.header_len]u8 = undefined;
        const hdr: protocol.Header = .{
            .op = op,
            .req_id = req_id,
            .length = @intCast(payload.len),
        };
        hdr.encode(&hdr_bytes);

        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);

        var w_buf: [4096]u8 = undefined;
        var stream_writer = self.stream.writer(self.io, &w_buf);
        try stream_writer.interface.writeAll(&hdr_bytes);
        if (payload.len > 0) {
            try stream_writer.interface.writeAll(payload);
        }
        try stream_writer.interface.flush();
    }

    fn sendRawFrame(self: *Server, frame: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);

        var w_buf: [4096]u8 = undefined;
        var stream_writer = self.stream.writer(self.io, &w_buf);
        try stream_writer.interface.writeAll(frame);
        try stream_writer.interface.flush();
    }

    fn sendError(self: *Server, req_id: u32, code: protocol.ErrorCode, msg: []const u8) !void {
        const buf = try self.gpa.alloc(u8, protocol.header_len + 2 + msg.len);
        defer self.gpa.free(buf);
        const hdr: protocol.Header = .{
            .op = .@"error",
            .req_id = req_id,
            .length = @intCast(2 + msg.len),
        };
        hdr.encode(buf[0..protocol.header_len]);
        std.mem.writeInt(u16, buf[protocol.header_len..][0..2], @intFromEnum(code), .little);
        @memcpy(buf[protocol.header_len + 2 ..], msg);
        try self.sendRawFrame(buf);
    }
};

fn drainPayload(r: *std.Io.Reader, len: u32) !void {
    var scratch: [1024]u8 = undefined;
    var remaining: usize = len;
    while (remaining > 0) {
        const chunk = @min(remaining, scratch.len);
        try r.readSliceAll(scratch[0..chunk]);
        remaining -= chunk;
    }
}
