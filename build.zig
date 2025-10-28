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

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libvulkan_mod = b.createModule(.{
        .root_source_file = b.path("src/vulkan/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    libvulkan_mod.addImport("vulkan", vulkan);

    const libvulkan = b.addLibrary(.{
        .name = "vulkan",
        .root_module = libvulkan_mod,
        .linkage = .dynamic,
    });

    b.installArtifact(libvulkan);

    for (implementations) |impl| {
        b.installArtifact(try buildImplementation(b, target, optimize, &impl, vulkan));
    }

    const libvulkan_tests = b.addTest(.{
        .root_module = libvulkan_mod,
    });

    const run_libvulkan_tests = b.addRunArtifact(libvulkan_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_libvulkan_tests.step);
}

fn buildImplementation(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    desc: *const ImplementationDesc,
    vulkan_bindings: *std.Build.Module,
) !*Step.Compile {
    const lib_mod = b.createModule(.{
        .root_source_file = b.path(desc.root_source_file),
        .target = target,
        .optimize = optimize,
    });

    lib_mod.addImport("vulkan", vulkan_bindings);

    return b.addLibrary(.{
        .name = try std.fmt.allocPrint(b.allocator, "vulkan_{s}", .{desc.name}),
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
}
