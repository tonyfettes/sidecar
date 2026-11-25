const std = @import("std");
const builtin = @import("builtin");

pub const protocol_version: u8 = 1;
pub const abi_version: u32 = 1;
pub const header_len: usize = 12;
pub const token_len: usize = 32;
pub const default_max_frame_size: u32 = 16 * 1024 * 1024;

pub const Op = enum(u8) {
    hello = 0x01,
    load = 0x02,
    loaded = 0x03,
    unload = 0x04,
    unloaded = 0x05,
    find = 0x06,
    found = 0x07,
    call = 0x08,
    called = 0x09,
    cancel = 0x0A,
    @"error" = 0xFF,

    pub fn fromByte(b: u8) ?Op {
        return switch (b) {
            0x01 => .hello,
            0x02 => .load,
            0x03 => .loaded,
            0x04 => .unload,
            0x05 => .unloaded,
            0x06 => .find,
            0x07 => .found,
            0x08 => .call,
            0x09 => .called,
            0x0A => .cancel,
            0xFF => .@"error",
            else => null,
        };
    }
};

pub const ErrorCode = enum(u16) {
    invalid_frame = 0x0001,
    lib_load_failed = 0x0002,
    invalid_lib_id = 0x0003,
    lib_busy = 0x0004,
    symbol_not_found = 0x0005,
    invalid_func_id = 0x0006,
    frame_too_large = 0x0007,
    cancelled = 0x0008,
    unsupported = 0x0009,
};

pub const Header = struct {
    version: u8 = protocol_version,
    op: Op,
    flags: u16 = 0,
    req_id: u32,
    length: u32,

    pub fn encode(self: Header, buf: *[header_len]u8) void {
        buf[0] = self.version;
        buf[1] = @intFromEnum(self.op);
        std.mem.writeInt(u16, buf[2..4], self.flags, .little);
        std.mem.writeInt(u32, buf[4..8], self.req_id, .little);
        std.mem.writeInt(u32, buf[8..12], self.length, .little);
    }

    pub fn decode(buf: *const [header_len]u8) error{ UnsupportedVersion, UnknownOp }!Header {
        const ver = buf[0];
        if (ver != protocol_version) return error.UnsupportedVersion;
        const op = Op.fromByte(buf[1]) orelse return error.UnknownOp;
        return .{
            .version = ver,
            .op = op,
            .flags = std.mem.readInt(u16, buf[2..4], .little),
            .req_id = std.mem.readInt(u32, buf[4..8], .little),
            .length = std.mem.readInt(u32, buf[8..12], .little),
        };
    }
};

pub fn hostOsName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        else => @tagName(builtin.os.tag),
    };
}

pub fn hostArchName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        .x86 => "x86",
        .arm => "arm",
        .riscv64 => "riscv64",
        else => @tagName(builtin.cpu.arch),
    };
}

pub fn hostLibExt() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "dylib",
        .windows => "dll",
        else => "so",
    };
}

pub fn encodeHelloPayload(
    gpa: std.mem.Allocator,
    token: [token_len]u8,
    max_frame_size: u32,
) ![]u8 {
    const os_name = hostOsName();
    const arch_name = hostArchName();
    const lib_ext = hostLibExt();
    const total = token_len + 4 + 4 + 2 + os_name.len + 2 + arch_name.len + 2 + lib_ext.len;
    const buf = try gpa.alloc(u8, total);
    var pos: usize = 0;

    @memcpy(buf[pos .. pos + token_len], &token);
    pos += token_len;

    std.mem.writeInt(u32, buf[pos..][0..4], abi_version, .little);
    pos += 4;

    std.mem.writeInt(u32, buf[pos..][0..4], max_frame_size, .little);
    pos += 4;

    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(os_name.len), .little);
    pos += 2;
    @memcpy(buf[pos .. pos + os_name.len], os_name);
    pos += os_name.len;

    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(arch_name.len), .little);
    pos += 2;
    @memcpy(buf[pos .. pos + arch_name.len], arch_name);
    pos += arch_name.len;

    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(lib_ext.len), .little);
    pos += 2;
    @memcpy(buf[pos .. pos + lib_ext.len], lib_ext);
    pos += lib_ext.len;

    std.debug.assert(pos == total);
    return buf;
}

pub fn parseHexToken(hex: []const u8) error{InvalidToken}![token_len]u8 {
    if (hex.len != token_len * 2) return error.InvalidToken;
    var out: [token_len]u8 = undefined;
    for (0..token_len) |i| {
        const hi = hexNibble(hex[i * 2]) orelse return error.InvalidToken;
        const lo = hexNibble(hex[i * 2 + 1]) orelse return error.InvalidToken;
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

test "header encode and decode roundtrip" {
    const h: Header = .{
        .op = .call,
        .flags = 0,
        .req_id = 0x12345678,
        .length = 42,
    };
    var raw: [header_len]u8 = undefined;
    h.encode(&raw);
    const decoded = try Header.decode(&raw);
    try std.testing.expectEqual(h, decoded);
}

test "parseHexToken" {
    const hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const tok = try parseHexToken(hex);
    for (0..token_len) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), tok[i]);
    }
}

test "encodeHelloPayload" {
    const tok: [token_len]u8 = @splat(0xAA);
    const payload = try encodeHelloPayload(std.testing.allocator, tok, default_max_frame_size);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualSlices(u8, &tok, payload[0..token_len]);
    try std.testing.expectEqual(abi_version, std.mem.readInt(u32, payload[32..36], .little));
    try std.testing.expectEqual(default_max_frame_size, std.mem.readInt(u32, payload[36..40], .little));
}
