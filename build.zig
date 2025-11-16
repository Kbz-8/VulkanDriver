const std = @import("std");
const Step = std.Build.Step;
const zcc = @import("compile_commands");

const ImplementationDesc = struct {
    name: []const u8,
    root_source_file: []const u8,
    custom: ?*const fn (*std.Build, *std.Build.Module) anyerror!void = null,
};

const implementations = [_]ImplementationDesc{
    .{
        .name = "soft",
        .root_source_file = "src/soft/lib.zig",
        .custom = customSoft,
    },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const base_mod = b.createModule(.{
        .root_source_file = b.path("src/vulkan/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const zdt = b.dependency("zdt", .{}).module("zdt");
    const vulkan_headers = b.dependency("vulkan_headers", .{});

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    }).module("vulkan-zig");

    base_mod.addImport("zdt", zdt);
    base_mod.addImport("vulkan", vulkan);
    base_mod.addSystemIncludePath(vulkan_headers.path("include"));

    for (implementations) |impl| {
        var targets = std.ArrayList(*std.Build.Step.Compile){};

        const lib_mod = b.createModule(.{
            .root_source_file = b.path(impl.root_source_file),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "base", .module = base_mod },
                .{ .name = "vulkan", .module = vulkan },
            },
        });

        lib_mod.addSystemIncludePath(vulkan_headers.path("include"));

        if (impl.custom) |custom| {
            custom(b, lib_mod) catch continue;
        }

        const lib = b.addLibrary(.{
            .name = b.fmt("vulkan_{s}", .{impl.name}),
            .root_module = lib_mod,
            .linkage = .dynamic,
            .use_llvm = true, // Fixes some random bugs happenning with custom backend. Investigations needed
        });
        const lib_install = b.addInstallArtifact(lib, .{});

        const lib_tests = b.addTest(.{ .root_module = lib_mod });

        const run_tests = b.addRunArtifact(lib_tests);
        const test_step = b.step(b.fmt("test-{s}", .{impl.name}), b.fmt("Run lib{s} tests", .{impl.name}));
        test_step.dependOn(&run_tests.step);

        const volk = b.lazyDependency("volk", .{}) orelse continue;
        const kvf = b.lazyDependency("kvf", .{}) orelse continue;

        const c_test_exe = b.addExecutable(.{
            .name = b.fmt("c_test_vulkan_{s}", .{impl.name}),
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        c_test_exe.root_module.addSystemIncludePath(volk.path(""));
        c_test_exe.root_module.addSystemIncludePath(kvf.path(""));
        c_test_exe.root_module.addSystemIncludePath(vulkan_headers.path("include"));

        c_test_exe.root_module.addCSourceFile(.{
            .file = b.path("test/c/main.c"),
            .flags = &.{b.fmt("-DLIBVK=\"{s}\"", .{lib.name})},
        });

        const c_test_exe_install = b.addInstallArtifact(c_test_exe, .{});
        c_test_exe_install.step.dependOn(&lib_install.step);

        try targets.append(b.allocator, lib);
        try targets.append(b.allocator, c_test_exe);

        _ = zcc.createStep(b, "cdb", try targets.toOwnedSlice(b.allocator));

        const run_c_test_exe = b.addRunArtifact(c_test_exe);
        run_c_test_exe.step.dependOn(&c_test_exe_install.step);

        const run_c_test_step = b.step(b.fmt("test-c-{s}", .{impl.name}), b.fmt("Run lib{s} C test", .{impl.name}));
        run_c_test_step.dependOn(&run_c_test_exe.step);

        const run_c_test_gdb_exe = b.addRunArtifact(c_test_exe);
        try run_c_test_gdb_exe.argv.insert(b.allocator, 0, .{ .bytes = b.fmt("gdb", .{}) }); // Hacky
        run_c_test_gdb_exe.step.dependOn(&c_test_exe_install.step);

        const run_c_test_gdb_step = b.step(b.fmt("test-c-{s}-gdb", .{impl.name}), b.fmt("Run lib{s} C test within gdb", .{impl.name}));
        run_c_test_gdb_step.dependOn(&run_c_test_gdb_exe.step);
    }

    const autodoc_test = b.addObject(.{
        .name = "lib",
        .root_module = base_mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = autodoc_test.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build and install the documentation");
    docs_step.dependOn(&install_docs.step);
}

fn customSoft(b: *std.Build, mod: *std.Build.Module) !void {
    const cpuinfo = b.lazyDependency("cpuinfo", .{}) orelse return error.UnresolvedDependency;
    mod.addImport("cpuinfo", cpuinfo.module("cpuinfo"));
}
