const std = @import("std");
const Step = std.Build.Step;
const builtin = @import("builtin");

const ImplementationDesc = struct {
    name: []const u8,
    root_source_file: []const u8,
    vulkan_version: std.SemanticVersion,
    custom: ?*const fn (*std.Build, *std.Build.Step.Compile, *std.Build.Step.Options, bool) anyerror!void = null,
};

const implementations = [_]ImplementationDesc{
    .{
        .name = "soft",
        .root_source_file = "src/soft/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .custom = customSoft,
    },
};

const RunningMode = enum {
    normal,
    gdb,
    valgrind,
};

const LogType = enum {
    none,
    standard,
    verbose,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const base_mod = b.createModule(.{
        .root_source_file = b.path("src/vulkan/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_utility_libraries = b.dependency("vulkan_utility_libraries", .{});

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    }).module("vulkan-zig");

    const zmath = b.dependency("zmath", .{}).module("root");

    const logs_option: LogType = b.option(LogType, "logs", "Driver logs") orelse .none;

    const options = b.addOptions();
    options.addOption(LogType, "logs", logs_option);

    base_mod.addImport("zmath", zmath);
    base_mod.addImport("vulkan", vulkan);
    base_mod.addSystemIncludePath(vulkan_headers.path("include"));
    base_mod.addSystemIncludePath(vulkan_utility_libraries.path("include"));

    const use_llvm = b.option(bool, "use-llvm", "LLVM build") orelse (b.release_mode != .off);

    for (implementations) |impl| {
        const lib_mod = b.createModule(.{
            .root_source_file = b.path(impl.root_source_file),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "base", .module = base_mod },
                .{ .name = "vulkan", .module = vulkan },
            },
        });

        lib_mod.addSystemIncludePath(vulkan_headers.path("include"));

        const lib = b.addLibrary(.{
            .name = b.fmt("vulkan_{s}", .{impl.name}),
            .root_module = lib_mod,
            .linkage = .dynamic,
            .use_llvm = use_llvm,
        });

        if (impl.custom) |custom| {
            custom(b, lib, options, use_llvm) catch continue;
        }

        const icd_file = b.addWriteFile(
            b.getInstallPath(.lib, b.fmt("vk_stroll_{s}.json", .{impl.name})),
            b.fmt(
                \\{{
                \\    "file_format_version": "1.0.1",
                \\    "ICD": {{
                \\        "library_path": "{s}",
                \\        "api_version": "{}.{}.{}",
                \\        "library_arch": "64",
                \\        "is_portability_driver": false
                \\    }}
                \\}}
            , .{ lib.out_lib_filename, impl.vulkan_version.major, impl.vulkan_version.minor, impl.vulkan_version.patch }),
        );

        lib.step.dependOn(&icd_file.step);
        const lib_install = b.addInstallArtifact(lib, .{});
        const install_step = b.step(impl.name, b.fmt("Build libvulkan_{s}", .{impl.name}));
        install_step.dependOn(&lib_install.step);

        const lib_tests = b.addTest(.{ .root_module = lib_mod });

        const run_tests = b.addRunArtifact(lib_tests);
        const test_step = b.step(b.fmt("test-{s}", .{impl.name}), b.fmt("Run libvulkan_{s} tests", .{impl.name}));
        test_step.dependOn(&run_tests.step);

        (try addCTS(b, target, &impl, lib, .normal)).dependOn(&lib_install.step);
        (try addCTS(b, target, &impl, lib, .gdb)).dependOn(&lib_install.step);
        (try addCTS(b, target, &impl, lib, .valgrind)).dependOn(&lib_install.step);

        (try addMultithreadedCTS(b, target, &impl, lib)).dependOn(&lib_install.step);

        const impl_autodoc_test = b.addObject(.{
            .name = "lib",
            .root_module = lib_mod,
        });

        const impl_install_docs = b.addInstallDirectory(.{
            .source_dir = impl_autodoc_test.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = b.fmt("docs-{s}", .{impl.name}),
        });

        const impl_docs_step = b.step(b.fmt("docs-{s}", .{impl.name}), b.fmt("Build and install the documentation for lib_vulkan_{s}", .{impl.name}));
        impl_docs_step.dependOn(&impl_install_docs.step);
    }

    base_mod.addOptions("config", options);

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

fn customSoft(b: *std.Build, lib: *std.Build.Step.Compile, options: *std.Build.Step.Options, use_llvm: bool) !void {
    const cpuinfo = b.lazyDependency("cpuinfo", .{}) orelse return error.UnresolvedDependency;
    lib.root_module.addSystemIncludePath(cpuinfo.path("include"));
    lib.root_module.linkLibrary(cpuinfo.artifact("cpuinfo"));

    const spv = b.lazyDependency("SPIRV_Interpreter", .{
        .@"no-example" = true,
        .@"no-test" = true,
        .@"use-llvm" = use_llvm,
    }) orelse return error.UnresolvedDependency;
    lib.root_module.addImport("spv", spv.module("spv"));

    const single_threaded_option = b.option(bool, "single-threaded", "Single threaded runtime mode") orelse false;
    const debug_allocator_option = b.option(bool, "debug-allocator", "Debug device allocator") orelse false;
    const shaders_simd_option = b.option(bool, "shader-simd", "Shaders SIMD acceleration") orelse true;
    const single_threaded_compute_option = b.option(bool, "single-threaded-compute", "Single threaded compute shaders execution") orelse true;
    const compute_dump_early_results_table_option = b.option(u32, "compute-dump-early-results-table", "Dump compute shaders results table before invocation");
    const compute_dump_final_results_table_option = b.option(u32, "compute-dump-final-results-table", "Dump compute shaders results table after invocation");

    options.addOption(bool, "single_threaded", single_threaded_option);
    options.addOption(bool, "debug_allocator", debug_allocator_option);
    options.addOption(bool, "shaders_simd", shaders_simd_option);
    options.addOption(bool, "single_threaded_compute", single_threaded_compute_option);
    options.addOption(?u32, "compute_dump_early_results_table", compute_dump_early_results_table_option);
    options.addOption(?u32, "compute_dump_final_results_table", compute_dump_final_results_table_option);
}

fn addCTS(b: *std.Build, target: std.Build.ResolvedTarget, impl: *const ImplementationDesc, impl_lib: *std.Build.Step.Compile, comptime mode: RunningMode) !*std.Build.Step {
    const cts = b.dependency("cts_bin", .{});

    const cts_exe_name = cts.path(b.fmt("deqp-vk-{s}", .{
        switch (if (target.query.os_tag) |tag| tag else builtin.target.os.tag) {
            .linux => "linux.x86_64",
            else => unreachable,
        },
    }));

    const mustpass = try cts.path(
        b.fmt("mustpass/{}.{}.2/vk-default.txt", .{
            impl.vulkan_version.major,
            impl.vulkan_version.minor,
        }),
    ).getPath3(b, null).toString(b.allocator);

    const cts_exe_path = try cts_exe_name.getPath3(b, null).toString(b.allocator);

    const run = b.addSystemCommand(&[_][]const u8{switch (mode) {
        .normal => cts_exe_path,
        .gdb => "gdb",
        .valgrind => "valgrind",
    }});
    run.step.dependOn(&impl_lib.step);

    switch (mode) {
        .gdb => {
            run.addArg("--args");
            run.addArg(cts_exe_path);
        },
        .valgrind => {
            run.addArg("--track-origins=yes");
            run.addArg(cts_exe_path);
        },
        else => {},
    }

    run.addArg(b.fmt("--deqp-archive-dir={s}", .{try cts.path("").getPath3(b, null).toString(b.allocator)}));
    run.addArg(b.fmt("--deqp-vk-library-path={s}", .{b.getInstallPath(.lib, impl_lib.out_lib_filename)}));
    run.addArg("--deqp-log-filename=vk-cts-logs.qpa");

    var requires_explicit_tests = false;
    if (b.args) |args| {
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "--deqp-case")) {
                requires_explicit_tests = true;
            }
            run.addArg(arg);
        }
    }
    if (!requires_explicit_tests) {
        run.addArg(b.fmt("--deqp-caselist-file={s}", .{mustpass}));
    }

    const run_step = b.step(
        b.fmt("raw-cts-{s}{s}", .{
            impl.name,
            switch (mode) {
                .normal => "",
                .gdb => "-gdb",
                .valgrind => "-valgrind",
            },
        }),
        b.fmt("Run Vulkan conformance tests for libvulkan_{s}{s}", .{
            impl.name,
            switch (mode) {
                .normal => "",
                .gdb => " within GDB",
                .valgrind => " within Valgrind",
            },
        }),
    );
    run_step.dependOn(&run.step);

    return &run.step;
}

fn addMultithreadedCTS(b: *std.Build, target: std.Build.ResolvedTarget, impl: *const ImplementationDesc, impl_lib: *std.Build.Step.Compile) !*std.Build.Step {
    const cts = b.dependency("cts_bin", .{});

    const cts_exe_name = cts.path(b.fmt("deqp-vk-{s}", .{
        switch (if (target.query.os_tag) |tag| tag else builtin.target.os.tag) {
            .linux => "linux.x86_64",
            else => unreachable,
        },
    }));

    var mustpass_override: ?[]const u8 = null;
    var jobs_count: ?usize = null;

    if (b.args) |args| {
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "--mustpass-list")) {
                mustpass_override = arg["--mustpass-list=".len..];
            } else if (std.mem.startsWith(u8, arg, "-j")) {
                jobs_count = try std.fmt.parseInt(usize, arg["-j".len..], 10);
            }
        }
    }

    const mustpass_path = try cts.path(
        if (mustpass_override) |override|
            b.fmt("mustpass/{s}/vk-default.txt", .{override})
        else
            b.fmt("mustpass/{}.{}.2/vk-default.txt", .{
                impl.vulkan_version.major,
                impl.vulkan_version.minor,
            }),
    ).getPath3(b, null).toString(b.allocator);
    const cts_exe_path = try cts_exe_name.getPath3(b, null).toString(b.allocator);

    const run = b.addSystemCommand(&[_][]const u8{"deqp-runner"});
    run.step.dependOn(&impl_lib.step);

    run.addArg("run");
    run.addArg("--deqp");
    run.addArg(cts_exe_path);
    run.addArg("--caselist");
    run.addArg(mustpass_path);
    run.addArg("--output");
    run.addArg("./cts");
    if (jobs_count) |count| {
        run.addArg(b.fmt("-j{d}", .{count}));
    }
    run.addArg("--");
    run.addArg(b.fmt("--deqp-archive-dir={s}", .{try cts.path("").getPath3(b, null).toString(b.allocator)}));
    run.addArg(b.fmt("--deqp-vk-library-path={s}", .{b.getInstallPath(.lib, impl_lib.out_lib_filename)}));

    const run_step = b.step(b.fmt("cts-{s}", .{impl.name}), b.fmt("Run Vulkan conformance tests for libvulkan_{s} in a multithreaded environment", .{impl.name}));
    run_step.dependOn(&run.step);

    return &run.step;
}
