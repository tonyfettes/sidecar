const std = @import("std");
const builtin = @import("builtin");

pub const SidecarCtx = opaque {};

pub const SidecarApi = extern struct {
    abi_version: u32,
    write_out: *const fn (ctx: *SidecarCtx, data: [*]const u8, len: usize) callconv(.c) c_int,
    reserve_out: *const fn (ctx: *SidecarCtx, cap: usize) callconv(.c) ?[*]u8,
    commit_out: *const fn (ctx: *SidecarCtx, written_len: usize) callconv(.c) c_int,
    write_err: *const fn (ctx: *SidecarCtx, data: [*]const u8, len: usize) callconv(.c) c_int,
    is_cancelled: *const fn (ctx: *SidecarCtx) callconv(.c) bool,
};

pub const SidecarFn = *const fn (
    api: *const SidecarApi,
    ctx: *SidecarCtx,
    input: [*]const u8,
    input_len: usize,
) callconv(.c) u16;

pub const LibInitFn = *const fn () callconv(.c) i32;
pub const LibDeinitFn = *const fn () callconv(.c) void;

pub const SharedLib = struct {
    const is_windows = builtin.os.tag == .windows;

    handle: if (is_windows) std.os.windows.HMODULE else *anyopaque,

    const win = if (is_windows) struct {
        const HMODULE = std.os.windows.HMODULE;
        const FARPROC = std.os.windows.FARPROC;
        const LPCWSTR = std.os.windows.LPCWSTR;
        const LPCSTR = std.os.windows.LPCSTR;
        const DWORD = std.os.windows.DWORD;
        const BOOL = std.os.windows.BOOL;
        const LOAD_WITH_ALTERED_SEARCH_PATH: DWORD = 0x00000008;

        extern "kernel32" fn LoadLibraryExW(
            lpLibFileName: LPCWSTR,
            hFile: ?*anyopaque,
            dwFlags: DWORD,
        ) callconv(.winapi) ?HMODULE;

        extern "kernel32" fn LoadLibraryW(lpLibFileName: LPCWSTR) callconv(.winapi) ?HMODULE;
        extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: LPCSTR) callconv(.winapi) ?FARPROC;
        extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) BOOL;
    } else struct {};

    pub const OpenResult = union(enum) {
        ok: SharedLib,
        err: []u8,
    };

    pub fn open(gpa: std.mem.Allocator, path: []const u8) !OpenResult {
        if (comptime is_windows) {
            const path_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch {
                return .{ .err = try gpa.dupe(u8, "invalid UTF-8/WTF-8 library path") };
            };
            defer gpa.free(path_w);
            const h = win.LoadLibraryExW(path_w.ptr, null, win.LOAD_WITH_ALTERED_SEARCH_PATH) orelse
                win.LoadLibraryW(path_w.ptr) orelse {
                return .{ .err = try std.fmt.allocPrint(gpa, "LoadLibraryExW failed for '{s}'", .{path}) };
            };
            return .{ .ok = .{ .handle = h } };
        } else {
            const path_z = try gpa.dupeZ(u8, path);
            defer gpa.free(path_z);
            const h = std.c.dlopen(path_z.ptr, .{ .LAZY = true }) orelse {
                const msg = if (std.c.dlerror()) |c_err| std.mem.span(c_err) else "dlopen failed";
                return .{ .err = try gpa.dupe(u8, msg) };
            };
            return .{ .ok = .{ .handle = h } };
        }
    }

    pub fn lookup(self: SharedLib, comptime T: type, symbol_z: [:0]const u8) ?T {
        if (comptime is_windows) {
            const raw = win.GetProcAddress(self.handle, symbol_z.ptr) orelse return null;
            return @ptrCast(@alignCast(raw));
        } else {
            const raw = std.c.dlsym(self.handle, symbol_z.ptr) orelse return null;
            return @ptrCast(@alignCast(raw));
        }
    }

    pub fn close(self: SharedLib) void {
        if (comptime is_windows) {
            _ = win.FreeLibrary(self.handle);
        } else {
            _ = std.c.dlclose(self.handle);
        }
    }
};

const LibEntry = struct {
    id: u32,
    lib: SharedLib,
    deinit_fn: ?LibDeinitFn,
    active_calls: usize = 0,
    unloading: bool = false,
    func_ids: std.ArrayList(u32) = .empty,
};

const FuncEntry = struct {
    lib_id: u32,
    fn_ptr: SidecarFn,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    next_lib_id: u32 = 1,
    next_func_id: u32 = 1,
    libs: std.AutoHashMapUnmanaged(u32, *LibEntry) = .empty,
    funcs: std.AutoHashMapUnmanaged(u32, FuncEntry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        self.libs.deinit(self.gpa);
        self.funcs.deinit(self.gpa);
    }

    pub const LoadResult = union(enum) {
        ok: u32,
        err: []u8,
    };

    pub fn load(self: *Registry, io: std.Io, path: []const u8) !LoadResult {
        const opened = try SharedLib.open(self.gpa, path);
        const lib = switch (opened) {
            .ok => |l| l,
            .err => |msg| return .{ .err = msg },
        };

        if (lib.lookup(LibInitFn, "sidecar_lib_init")) |init_fn| {
            const rc = init_fn();
            if (rc != 0) {
                lib.close();
                return .{ .err = try std.fmt.allocPrint(self.gpa, "sidecar_lib_init returned {d}", .{rc}) };
            }
        }

        const deinit_fn = lib.lookup(LibDeinitFn, "sidecar_lib_deinit");

        const entry = try self.gpa.create(LibEntry);
        errdefer self.gpa.destroy(entry);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const lib_id = self.allocLibId();
        entry.* = .{
            .id = lib_id,
            .lib = lib,
            .deinit_fn = deinit_fn,
        };
        try self.libs.put(self.gpa, lib_id, entry);
        return .{ .ok = lib_id };
    }

    pub const FindResult = union(enum) {
        ok: u32,
        invalid_lib,
        symbol_not_found,
    };

    pub fn find(self: *Registry, io: std.Io, lib_id: u32, symbol: []const u8) !FindResult {
        const symbol_z = try self.gpa.dupeZ(u8, symbol);
        defer self.gpa.free(symbol_z);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const entry = self.libs.get(lib_id) orelse return .invalid_lib;
        if (entry.unloading) return .invalid_lib;

        const fn_ptr = entry.lib.lookup(SidecarFn, symbol_z) orelse return .symbol_not_found;
        const func_id = self.allocFuncId();
        try entry.func_ids.append(self.gpa, func_id);
        errdefer _ = entry.func_ids.pop();
        try self.funcs.put(self.gpa, func_id, .{
            .lib_id = lib_id,
            .fn_ptr = fn_ptr,
        });
        return .{ .ok = func_id };
    }

    pub const AcquiredCall = struct {
        lib_id: u32,
        fn_ptr: SidecarFn,
    };

    pub fn acquireCall(self: *Registry, io: std.Io, func_id: u32) ?AcquiredCall {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const f = self.funcs.get(func_id) orelse return null;
        const entry = self.libs.get(f.lib_id) orelse return null;
        if (entry.unloading) return null;
        entry.active_calls += 1;
        return .{
            .lib_id = f.lib_id,
            .fn_ptr = f.fn_ptr,
        };
    }

    pub fn releaseCall(self: *Registry, io: std.Io, lib_id: u32) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.libs.get(lib_id)) |entry| {
            std.debug.assert(entry.active_calls > 0);
            entry.active_calls -= 1;
            if (entry.active_calls == 0 and entry.unloading) {
                self.cond.broadcast(io);
            }
        }
    }

    pub fn unload(self: *Registry, io: std.Io, lib_id: u32) bool {
        var entry: *LibEntry = undefined;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            entry = self.libs.get(lib_id) orelse return false;
            if (entry.unloading) return false;
            entry.unloading = true;

            for (entry.func_ids.items) |fid| {
                _ = self.funcs.remove(fid);
            }
            entry.func_ids.clearRetainingCapacity();

            while (entry.active_calls > 0) {
                self.cond.waitUncancelable(io, &self.mutex);
            }
            _ = self.libs.remove(lib_id);
        }

        if (entry.deinit_fn) |deinit_fn| {
            deinit_fn();
        }
        entry.lib.close();
        entry.func_ids.deinit(self.gpa);
        self.gpa.destroy(entry);
        return true;
    }

    pub fn closeAll(self: *Registry, io: std.Io) void {
        var to_close: std.ArrayList(*LibEntry) = .empty;
        defer to_close.deinit(self.gpa);

        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            self.funcs.clearRetainingCapacity();

            var it = self.libs.valueIterator();
            while (it.next()) |entry_ptr| {
                entry_ptr.*.unloading = true;
                entry_ptr.*.func_ids.clearRetainingCapacity();
            }

            while (true) {
                var any_active = false;
                var check_it = self.libs.valueIterator();
                while (check_it.next()) |entry_ptr| {
                    if (entry_ptr.*.active_calls > 0) {
                        any_active = true;
                        break;
                    }
                }
                if (!any_active) break;
                self.cond.waitUncancelable(io, &self.mutex);
            }

            var collect_it = self.libs.valueIterator();
            while (collect_it.next()) |entry_ptr| {
                to_close.append(self.gpa, entry_ptr.*) catch {};
            }
            self.libs.clearRetainingCapacity();
        }

        for (to_close.items) |entry| {
            if (entry.deinit_fn) |deinit_fn| {
                deinit_fn();
            }
            entry.lib.close();
            entry.func_ids.deinit(self.gpa);
            self.gpa.destroy(entry);
        }
    }

    fn allocLibId(self: *Registry) u32 {
        while (true) {
            const id = self.next_lib_id;
            self.next_lib_id +%= 1;
            if (self.next_lib_id == 0) self.next_lib_id = 1;
            if (!self.libs.contains(id)) return id;
        }
    }

    fn allocFuncId(self: *Registry) u32 {
        while (true) {
            const id = self.next_func_id;
            self.next_func_id +%= 1;
            if (self.next_func_id == 0) self.next_func_id = 1;
            if (!self.funcs.contains(id)) return id;
        }
    }
};
