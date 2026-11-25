const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server_exe = addServerExecutable(b, "sidecar-server", target, optimize);
    b.installArtifact(server_exe);

    // Build the C example plugin for the host/target platform so tests can load it.
    const echo_plugin_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    echo_plugin_mod.addIncludePath(b.path("../include"));
    echo_plugin_mod.addCSourceFile(.{
        .file = b.path("../examples/echo_plugin/plugin.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    const echo_plugin = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "echo_plugin",
        .root_module = echo_plugin_mod,
    });
    b.installArtifact(echo_plugin);

    // Run step for manual testing.
    const run_cmd = b.addRunArtifact(server_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the sidecar server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Cross-compilation matrix step (`zig build dist`).
    const dist_step = b.step("dist", "Cross-compile sidecar-server for all supported platforms");
    const DistTarget = struct {
        name: []const u8,
        query: std.Target.Query,
    };
    const dist_targets = [_]DistTarget{
        .{
            .name = "macos-aarch64",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .macos },
        },
        .{
            .name = "macos-x86_64",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .macos },
        },
        .{
            .name = "linux-x86_64",
            .query = .{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .gnu,
                .glibc_version = .{ .major = 2, .minor = 17, .patch = 0 },
            },
        },
        .{
            .name = "linux-aarch64",
            .query = .{
                .cpu_arch = .aarch64,
                .os_tag = .linux,
                .abi = .gnu,
                .glibc_version = .{ .major = 2, .minor = 17, .patch = 0 },
            },
        },
        .{
            .name = "windows-x86_64",
            .query = .{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            },
        },
    };

    for (dist_targets) |dt| {
        const resolved = b.resolveTargetQuery(dt.query);
        const exe = addServerExecutable(b, "sidecar-server", resolved, .ReleaseSmall);
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("dist/{s}", .{dt.name}) } },
        });
        dist_step.dependOn(&install.step);
    }
}

fn addServerExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const os_tag = target.result.os.tag;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Link libc on POSIX so dlopen/dlsym/dlclose use the system dynamic linker
        // (static musl does not support dlopen of external shared libraries).
        .link_libc = (os_tag != .windows),
    });
    if (os_tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("kernel32", .{});
    }
    return b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
}
