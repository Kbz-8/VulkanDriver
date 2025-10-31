const std = @import("std");
const Step = std.Build.Step;

const ImplementationDesc = struct {
    name: []const u8,
    root_source_file: []const u8,
};

const implementations = [_]ImplementationDesc{
    .{
        .name = "soft",
        .root_source_file = "src/soft/lib.zig",
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_mod = b.createModule(.{
        .root_source_file = b.path("src/vulkan/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vulkan_headers = b.dependency("vulkan_headers", .{});

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    }).module("vulkan-zig");

    common_mod.addImport("vulkan", vulkan);
    common_mod.addSystemIncludePath(vulkan_headers.path("include"));

    for (implementations) |impl| {
        const lib_mod = b.createModule(.{
            .root_source_file = b.path(impl.root_source_file),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
                .{ .name = "vulkan", .module = vulkan },
            },
        });

        lib_mod.addSystemIncludePath(vulkan_headers.path("include"));

        const lib = b.addLibrary(.{
            .name = b.fmt("vulkan_{s}", .{impl.name}),
            .root_module = lib_mod,
            .linkage = .dynamic,
        });
        b.installArtifact(lib);

        const lib_tests = b.addTest(.{ .root_module = lib_mod });

        const run_tests = b.addRunArtifact(lib_tests);
        const test_step = b.step(b.fmt("test-{s}", .{impl.name}), b.fmt("Run lib{s} tests", .{impl.name}));
        test_step.dependOn(&run_tests.step);

        const c_test_exe = b.addExecutable(.{
            .name = b.fmt("c_test_vulkan_{s}", .{impl.name}),
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        c_test_exe.root_module.addCSourceFile(.{
            .file = b.path("test/c/main.c"),
            .flags = &.{b.fmt("-DLIBVK=\"{s}\"", .{lib.name})},
        });

        const run_c_test = b.addRunArtifact(c_test_exe);
        const test_c_step = b.step(b.fmt("test-c-{s}", .{impl.name}), b.fmt("Run lib{s} C test", .{impl.name}));
        test_c_step.dependOn(b.getInstallStep());
        test_c_step.dependOn(&run_c_test.step);
    }
}
