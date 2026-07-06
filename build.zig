const std = @import("std");
const Step = std.Build.Step;
const builtin = @import("builtin");

const driver_version: std.SemanticVersion = .{ .major = 26, .minor = 0, .patch = 0 };

const ImplementationDesc = struct {
    name: []const u8,
    icd_name: ?[]const u8 = null,
    root_source_file: []const u8,
    vulkan_version: std.SemanticVersion,
    custom: ?*const fn (
        *std.Build,
        *Step.Compile,
        *std.Build.Module,
        *std.Build.Module,
        *std.Build.Module,
        *std.Build.Module,
        std.Build.ResolvedTarget,
        std.builtin.OptimizeMode,
        bool,
    ) anyerror!void = null,
    options: ?*const fn (*std.Build, *Step.Options) anyerror!void = null,
};

const implementations = [_]ImplementationDesc{
    .{
        .name = "ape",
        .icd_name = "ape",
        .root_source_file = "src/ape/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .custom = customApe,
    },
    .{
        .name = "soft",
        .root_source_file = "src/software/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .custom = customSoft,
        .options = optionsSoft,
    },
    .{
        .name = "flint",
        .root_source_file = "src/intel/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .custom = customFlint,
        .options = optionsFlint,
    },
    .{
        .name = "phi",
        .root_source_file = "src/phi/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .custom = customPhi,
        .options = optionsPhi,
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
    debug,
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
    const drm = b.dependency("drm", .{}).module("drm");

    const logs_option: LogType = b.option(LogType, "logs", "Driver logs") orelse .none;
    const debug_allocator_option = b.option(bool, "device-debug-allocator", "Debug device allocator") orelse false;

    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "driver_version", driver_version);
    options.addOption(LogType, "logs", logs_option);
    options.addOption(bool, "device_debug_allocator", debug_allocator_option);

    base_mod.addImport("vulkan", vulkan);
    base_mod.addImport("zmath", zmath);
    base_mod.addImport("drm", drm);

    const base_c_includes = b.addTranslateC(.{
        .root_source_file = b.path("src/vulkan/c_includes.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    base_c_includes.addIncludePath(vulkan_headers.path("include"));
    base_c_includes.addIncludePath(vulkan_utility_libraries.path("include"));

    if (builtin.target.os.tag == .linux) {
        base_c_includes.link_libc = true;
    }

    const base_c_mod = base_c_includes.createModule();
    base_mod.addImport("base_c", base_c_mod);

    const use_llvm = b.option(bool, "use-llvm", "LLVM build") orelse (b.release_mode != .off);

    for (implementations) |impl| {
        const lib_mod = b.createModule(.{
            .root_source_file = b.path(impl.root_source_file),
            .target = target,
            .optimize = optimize,
            //.error_tracing = true,
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

        options.addOption(std.SemanticVersion, b.fmt("{s}_vulkan_version", .{impl.name}), impl.vulkan_version);

        if (impl.custom) |func| {
            func(b, lib, lib_mod, base_mod, vulkan, base_c_mod, target, optimize, use_llvm) catch continue;
        }

        if (impl.options) |func| {
            func(b, options) catch continue;
        }

        const icd_file = b.addWriteFile(
            b.getInstallPath(
                .lib,
                if (impl.icd_name) |icd_name|
                    b.fmt("vk_{s}.json", .{icd_name})
                else
                    b.fmt("vk_ape_{s}.json", .{impl.name}),
            ),
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

        inline for (std.enums.values(RunningMode)) |mode| {
            (try addCTS(b, target, &impl, lib, mode)).dependOn(&lib_install.step);
            (try addMultithreadedCTS(b, target, &impl, lib, mode)).dependOn(&lib_install.step);
        }

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

fn addCTS(b: *std.Build, target: std.Build.ResolvedTarget, impl: *const ImplementationDesc, impl_lib: *Step.Compile, comptime mode: RunningMode) !*Step {
    const cts = b.dependency("cts_bin", .{});

    const cts_exe_name = cts.path(b.fmt("deqp-vk-{s}", .{
        switch (if (target.query.os_tag) |tag| tag else builtin.target.os.tag) {
            .linux => "linux.x86_64",
            .windows => "windows.exe",
            else => return error.NoCTSForPlatform,
        },
    }));

    const mustpass = try cts.path("vk-default.txt").getPath3(b, null).toString(b.allocator);

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
            run.addArg("-s");
            run.addArg("--leak-check=full");
            run.addArg("--show-leak-kinds=all");
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

fn addMultithreadedCTS(b: *std.Build, target: std.Build.ResolvedTarget, impl: *const ImplementationDesc, impl_lib: *Step.Compile, comptime mode: RunningMode) !*Step {
    const cts = b.dependency("cts_bin", .{});

    const cts_exe_name = cts.path(b.fmt("deqp-vk-{s}", .{
        switch (if (target.query.os_tag) |tag| tag else builtin.target.os.tag) {
            .linux => "linux.x86_64",
            .windows => "windows.exe",
            else => return error.NoCTSForPlatform,
        },
    }));

    var jobs_count: ?usize = null;

    if (b.args) |args| {
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-j")) {
                jobs_count = try std.fmt.parseInt(usize, arg["-j".len..], 10);
            }
        }
    }

    var caselist_file_path: []const u8 = try cts.path("vk-default.txt").getPath3(b, null).toString(b.allocator);
    if (b.args) |args| {
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "--deqp-caselist-file")) {
                caselist_file_path = arg["--deqp-caselist-file=".len..];
            }
        }
    }

    const cts_exe_path = try cts_exe_name.getPath3(b, null).toString(b.allocator);

    const run = b.addSystemCommand(&[_][]const u8{switch (mode) {
        .normal => "deqp-runner",
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
            run.addArg("-s");
            run.addArg("--leak-check=full");
            run.addArg("--show-leak-kinds=all");
            run.addArg("--track-origins=yes");
            run.addArg(cts_exe_path);
        },
        else => {},
    }

    run.addArg("run");
    run.addArg("--timeout");
    run.addArg("300");
    run.addArg("--deqp");
    run.addArg(cts_exe_path);
    run.addArg("--caselist");
    run.addArg(caselist_file_path);
    run.addArg("--output");
    run.addArg("./cts");
    if (jobs_count) |count| {
        run.addArg(b.fmt("-j{d}", .{count}));
    }
    run.addArg("--");
    run.addArg(b.fmt("--deqp-archive-dir={s}", .{try cts.path("").getPath3(b, null).toString(b.allocator)}));
    run.addArg(b.fmt("--deqp-vk-library-path={s}", .{b.getInstallPath(.lib, impl_lib.out_lib_filename)}));
    run.addArg("--deqp-test-oom=disable");

    const run_step = b.step(
        b.fmt("cts-{s}{s}", .{
            impl.name,
            switch (mode) {
                .normal => "",
                .gdb => "-gdb",
                .valgrind => "-valgrind",
            },
        }),
        b.fmt("Run Vulkan conformance tests for libvulkan_{s}{s} in a multithreaded environment", .{
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

// Ape specialized functions

fn customApe(
    b: *std.Build,
    lib: *Step.Compile,
    lib_mod: *std.Build.Module,
    base_mod: *std.Build.Module,
    vulkan: *std.Build.Module,
    base_c_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
) !void {
    for (implementations) |impl| {
        if (std.mem.eql(u8, impl.name, "ape"))
            continue;

        const mod = b.createModule(.{
            .root_source_file = b.path(impl.root_source_file),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "base", .module = base_mod },
                .{ .name = "vulkan", .module = vulkan },
            },
        });

        if (impl.custom) |func| {
            func(b, lib, mod, base_mod, vulkan, base_c_mod, target, optimize, use_llvm) catch continue;
        }

        lib_mod.addImport(impl.name, mod);
    }
}

// Soft specialized functions

fn customSoft(
    b: *std.Build,
    _: *Step.Compile,
    lib_mod: *std.Build.Module,
    _: *std.Build.Module,
    _: *std.Build.Module,
    base_c_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
) !void {
    const spv = b.lazyDependency("SPIRV_Interpreter", .{
        .target = target,
        .optimize = optimize,
        .@"use-llvm" = use_llvm,
    }) orelse return error.UnresolvedDependency;

    lib_mod.addImport("soft_c", base_c_mod);
    lib_mod.addImport("spv", spv.module("spv"));
}

fn optionsSoft(b: *std.Build, options: *Step.Options) !void {
    const single_threaded_option = b.option(bool, "soft-single-threaded", "Single threaded runtime mode") orelse false;
    const shaders_simd_option = b.option(bool, "soft-shader-simd", "Shaders SIMD acceleration") orelse true;
    const compute_dump_early_results_table_option = b.option(u32, "soft-compute-dump-early-results-table", "Dump compute shaders results table before invocation");
    const compute_dump_final_results_table_option = b.option(u32, "soft-compute-dump-final-results-table", "Dump compute shaders results table after invocation");
    const approxiamte_rgb_option = b.option(bool, "soft-approximates-rgb", "Approximate sRGB <-> RGB conversions") orelse true;

    options.addOption(bool, "soft_single_threaded", single_threaded_option);
    options.addOption(bool, "soft_shaders_simd", shaders_simd_option);
    options.addOption(?u32, "soft_compute_dump_early_results_table", compute_dump_early_results_table_option);
    options.addOption(?u32, "soft_compute_dump_final_results_table", compute_dump_final_results_table_option);
    options.addOption(bool, "soft_approximates_rgb", approxiamte_rgb_option);
}

// Flint specialized functions

fn customFlint(
    _: *std.Build,
    _: *Step.Compile,
    lib_mod: *std.Build.Module,
    _: *std.Build.Module,
    _: *std.Build.Module,
    base_c_mod: *std.Build.Module,
    _: std.Build.ResolvedTarget,
    _: std.builtin.OptimizeMode,
    _: bool,
) !void {
    lib_mod.addImport("intel_c", base_c_mod);
}

fn optionsFlint(b: *std.Build, options: *Step.Options) !void {
    _ = b;
    _ = options;
}

// Phi specialized functions

fn customPhi(
    b: *std.Build,
    lib: *Step.Compile,
    lib_mod: *std.Build.Module,
    _: *std.Build.Module,
    _: *std.Build.Module,
    base_c_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
) !void {
    lib_mod.addImport("phi_c", base_c_mod);

    const miclib = b.lazyDependency("miclib", .{
        .target = target,
        .optimize = optimize,
        .@"use-llvm" = use_llvm,
    }) orelse return error.UnresolvedDependency;

    lib_mod.addImport("miclib", miclib.module("miclib"));

    const phi_protocol_c = b.addTranslateC(.{
        .root_source_file = b.path("src/phi/shared/Protocol.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    lib_mod.addImport("phi_protocol_c", phi_protocol_c.createModule());

    // To avoid duplicated options due to Ape's custom function
    if (!std.mem.eql(u8, lib.name, "vulkan_phi"))
        return;

    const build_card = b.option(
        bool,
        "phi-build-card",
        "Build Xeon Phi card daemon",
    ) orelse true;

    if (!build_card)
        return;

    const cc = b.option(
        []const u8,
        "phi-card-cc",
        "Path to k1om-mpss-linux-gcc",
    ) orelse "k1om-mpss-linux-gcc";

    const sysroot = b.option(
        []const u8,
        "phi-card-sysroot",
        "MPSS sysroot path",
    );

    const daemon = try addPhiCardDaemon(b, optimize, cc, sysroot);
    const install_daemon = b.addInstallFile(daemon, "lib/phi_device.mic");
    lib.step.dependOn(&install_daemon.step);
}

fn optionsPhi(b: *std.Build, options: *Step.Options) !void {
    _ = b;
    _ = options;
}

fn addPhiCardDaemon(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    cc: []const u8,
    sysroot: ?[]const u8,
) !std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{cc});

    cmd.addArgs(&.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Wno-unused-parameter",
        "-pthread",
    });

    cmd.addArg("-I");
    cmd.addDirectoryArg(b.path("src/phi/mic"));
    cmd.addArg("-I");
    cmd.addDirectoryArg(b.path("src/phi/shared"));

    if (sysroot) |path| {
        cmd.addArg("--sysroot");
        cmd.addArg(path);
    }

    switch (optimize) {
        .Debug => cmd.addArgs(&.{ "-O0", "-g3" }),
        .ReleaseSafe => cmd.addArgs(&.{ "-O2", "-g", "-DNDEBUG" }),
        .ReleaseFast => cmd.addArgs(&.{ "-O3", "-DNDEBUG" }),
        .ReleaseSmall => cmd.addArgs(&.{ "-Os", "-DNDEBUG" }),
    }

    const sources = [_][]const u8{
        "src/phi/mic/main.c",
        "src/phi/mic/Daemon.c",
        "src/phi/mic/Logger.c",
        "src/phi/mic/Memory.c",
        // Add new files here
    };

    for (sources) |source| {
        cmd.addFileArg(b.path(source));
    }

    cmd.addArgs(&.{
        "-lscif",
        "-o",
    });

    return cmd.addOutputFileArg("phi_device.mic");
}
