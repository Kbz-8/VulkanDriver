const std = @import("std");
const Step = std.Build.Step;
const builtin = @import("builtin");

const driver_version: std.SemanticVersion = .{ .major = 26, .minor = 0, .patch = 0 };

const InstallFn = *const fn (*std.Build, *const ImplementationDesc, *Step.Compile) *Step;

const TargetProfile = enum {
    native,
    vita,
};

const TargetContext = struct {
    target: std.Build.ResolvedTarget,
    ir_mod: *std.Build.Module,
    base_mod: *std.Build.Module,
    base_c_mod: *std.Build.Module,
    linkage: std.builtin.LinkMode = .dynamic,
    use_llvm: ?bool = null,
    link_libc: bool = false,
    pic: ?bool = null,
};

const TargetContextOptions = struct {
    target: std.Build.ResolvedTarget,
    linkage: std.builtin.LinkMode = .dynamic,
    use_llvm: ?bool = null,
    translate_c_link_libc: bool = false,
    link_libc: bool = false,
    pic: ?bool = null,
};

const SharedDependencies = struct {
    vulkan: *std.Build.Module,
    zmath: *std.Build.Module,
    vulkan_headers: *std.Build.Dependency,
    vulkan_utility_libraries: *std.Build.Dependency,
    options: *Step.Options,
};

const TargetContexts = struct {
    native: TargetContext,
    vita: TargetContext,

    fn get(self: *const TargetContexts, profile: TargetProfile) *const TargetContext {
        return switch (profile) {
            .native => &self.native,
            .vita => &self.vita,
        };
    }
};

const ImplementationDesc = struct {
    name: []const u8,
    root_source_file: []const u8,
    vulkan_version: std.SemanticVersion,
    target_profile: TargetProfile = .native,
    custom: ?*const fn (
        *std.Build,
        *Step.Options,
        *Step.Compile,
        *std.Build.Module,
        *std.Build.Module,
        *std.Build.Module,
        *std.Build.Module,
        *std.Build.Module,
        std.Build.ResolvedTarget,
        std.builtin.OptimizeMode,
        bool,
    ) anyerror!void,
    install: InstallFn = installSharedLibrary,
};

const implementations = [_]ImplementationDesc{
    .{
        .name = "soft",
        .root_source_file = "src/software/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .custom = customSoft,
    },
    .{
        .name = "flint",
        .root_source_file = "src/intel/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .custom = customFlint,
    },
    .{
        .name = "phi",
        .root_source_file = "src/phi/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .custom = customPhi,
    },
    .{
        .name = "psvk",
        .root_source_file = "src/vita/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .target_profile = .vita,
        .custom = null,
        .install = installPsvk,
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

    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_utility_libraries = b.dependency("vulkan_utility_libraries", .{});
    const vulkan = b.dependency("vulkan_zig", .{ .registry = vulkan_headers.path("registry/vk.xml") }).module("vulkan-zig");

    const zmath = b.dependency("zmath", .{}).module("root");

    const logs_option: LogType = b.option(LogType, "logs", "Driver logs") orelse .none;
    const debug_allocator_option = b.option(bool, "device-debug-allocator", "Debug device allocator") orelse false;

    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "driver_version", driver_version);
    options.addOption(LogType, "logs", logs_option);
    options.addOption(bool, "device_debug_allocator", debug_allocator_option);

    const shared_dependencies = SharedDependencies{
        .vulkan = vulkan,
        .zmath = zmath,
        .vulkan_headers = vulkan_headers,
        .vulkan_utility_libraries = vulkan_utility_libraries,
        .options = options,
    };

    const use_llvm = b.option(bool, "use-llvm", "LLVM build") orelse false;

    const target_contexts = TargetContexts{
        .native = createTargetContext(b, optimize, shared_dependencies, .{
            .target = target,
            .translate_c_link_libc = target.result.os.tag == .linux,
        }),
        .vita = createTargetContext(b, optimize, shared_dependencies, .{
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .arm,
                .os_tag = .vita,
                .abi = .eabihf,
            }),
            .linkage = .static,
            .use_llvm = true,
            .translate_c_link_libc = true,
            .link_libc = true,
            .pic = false,
        }),
    };
    const native_context = target_contexts.get(.native);

    const ir_tests = b.addTest(.{
        .root_module = native_context.ir_mod,
        .test_runner = .{
            .path = b.path("test/test_runner.zig"),
            .mode = .simple,
        },
    });
    const run_ir_tests = b.addRunArtifact(ir_tests);
    const ir_test_step = b.step("test-ir", "Run shared shader ir tests");
    ir_test_step.dependOn(&run_ir_tests.step);

    const ir_autodoc_test = b.addObject(.{
        .name = "lib",
        .root_module = native_context.ir_mod,
    });

    const ir_install_docs = b.addInstallDirectory(.{
        .source_dir = ir_autodoc_test.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs-ir",
    });

    const ir_docs_step = b.step("docs-ir", "Build and install the documentation or shader IR");
    ir_docs_step.dependOn(&ir_install_docs.step);

    const caselist = b.option([]const u8, "deqp-case", "Caselist for deqp");
    const caselist_file = b.option([]const u8, "deqp-caselist-file", "Caselist file relative to cwd for deqp");
    const cts_jobs = b.option(u32, "deqp-jobs", "Job count for deqp-runner");

    var implementation_modules: [implementations.len]*std.Build.Module = undefined;
    for (implementations, 0..) |impl, impl_index| {
        const context = target_contexts.get(impl.target_profile);
        const impl_use_llvm = context.use_llvm orelse use_llvm;
        const lib_mod = b.createModule(.{
            .root_source_file = b.path(impl.root_source_file),
            .target = context.target,
            .optimize = optimize,
            //.error_tracing = true,
            .imports = &.{
                .{ .name = "base", .module = context.base_mod },
                .{ .name = "vulkan", .module = vulkan },
            },
        });

        implementation_modules[impl_index] = lib_mod;
        lib_mod.addSystemIncludePath(vulkan_headers.path("include"));
        lib_mod.link_libc = context.link_libc;
        lib_mod.pic = context.pic;

        const lib = b.addLibrary(.{
            .name = b.fmt("vulkan_{s}", .{impl.name}),
            .root_module = lib_mod,
            .linkage = context.linkage,
            .use_llvm = impl_use_llvm,
        });

        options.addOption(std.SemanticVersion, b.fmt("{s}_vulkan_version", .{impl.name}), impl.vulkan_version);

        if (impl.custom) |func|
            func(b, options, lib, lib_mod, context.base_mod, vulkan, context.base_c_mod, context.ir_mod, context.target, optimize, impl_use_llvm) catch continue;

        const implementation_install_step = impl.install(b, &impl, lib);
        const install_step = b.step(impl.name, b.fmt("Build libvulkan_{s}", .{impl.name}));
        install_step.dependOn(implementation_install_step);

        const test_step = b.step(b.fmt("test-{s}", .{impl.name}), b.fmt("Run libvulkan_{s} tests", .{impl.name}));
        if (impl.target_profile == .vita) {
            // Vita is an unhosted target, so Zig cannot link or run a test executable for it.
            // The library build still compiles the complete backend for the target toolchain.
            test_step.dependOn(&lib.step);
        } else {
            const test_mod = b.allocator.create(std.Build.Module) catch @panic("OOM");
            test_mod.init(b, .{ .existing = lib_mod });
            if (std.mem.eql(u8, impl.name, "phi")) {
                // miclib resolves the C ABI dynamically. Debug metadata for its translated C
                // declarations otherwise creates spurious link-time references to libmicmgmt.
                test_mod.strip = true;
            }

            const lib_tests = b.addTest(.{
                .root_module = test_mod,
                .test_runner = .{
                    .path = b.path("test/test_runner.zig"),
                    .mode = .simple,
                },
            });

            const run_tests = b.addRunArtifact(lib_tests);
            test_step.dependOn(&run_tests.step);
        }

        inline for (std.enums.values(RunningMode)) |mode| {
            if (addCTS(b, context.target, &impl, lib, mode, caselist, caselist_file) catch null) |step|
                step.dependOn(implementation_install_step);
        }

        if (addMultithreadedCTS(b, context.target, &impl, lib, caselist_file, cts_jobs) catch null) |step|
            step.dependOn(implementation_install_step);

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

    const autodoc_test = b.addObject(.{
        .name = "lib",
        .root_module = native_context.base_mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = autodoc_test.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build and install the documentation");
    docs_step.dependOn(&install_docs.step);
}

fn createTargetContext(b: *std.Build, optimize: std.builtin.OptimizeMode, deps: SharedDependencies, config: TargetContextOptions) TargetContext {
    const ir_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/root.zig"),
        .target = config.target,
        .optimize = optimize,
    });

    const drm = b.dependency("drm", .{
        .target = config.target,
        .optimize = optimize,
    }).module("drm");

    const base_mod = b.createModule(.{
        .root_source_file = b.path("src/vulkan/lib.zig"),
        .target = config.target,
        .optimize = optimize,
    });
    base_mod.addImport("vulkan", deps.vulkan);
    base_mod.addImport("zmath", deps.zmath);
    base_mod.addImport("drm", drm);
    base_mod.addImport("shader_ir", ir_mod);
    base_mod.addOptions("config", deps.options);

    const base_c_includes = b.addTranslateC(.{
        .root_source_file = b.path("src/vulkan/c_includes.h"),
        .target = config.target,
        .optimize = optimize,
        .link_libc = config.translate_c_link_libc,
    });
    base_c_includes.addIncludePath(deps.vulkan_headers.path("include"));
    base_c_includes.addIncludePath(deps.vulkan_utility_libraries.path("include"));

    const base_c_mod = base_c_includes.createModule();
    base_mod.addImport("base_c", base_c_mod);

    return .{
        .target = config.target,
        .ir_mod = ir_mod,
        .base_mod = base_mod,
        .base_c_mod = base_c_mod,
        .linkage = config.linkage,
        .use_llvm = config.use_llvm,
        .link_libc = config.link_libc,
        .pic = config.pic,
    };
}

fn installSharedLibrary(b: *std.Build, impl: *const ImplementationDesc, lib: *Step.Compile) *Step {
    const icd_name = b.fmt("vk_ape_{s}.json", .{impl.name});
    const write_files = b.addWriteFiles();
    const icd_file = write_files.add(
        icd_name,
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
        , .{
            lib.out_filename,
            impl.vulkan_version.major,
            impl.vulkan_version.minor,
            impl.vulkan_version.patch,
        }),
    );

    const install_lib = b.addInstallArtifact(lib, .{});
    const install_icd = b.addInstallFileWithDir(icd_file, .lib, icd_name);

    install_icd.step.dependOn(&install_lib.step);

    return &install_icd.step;
}

fn addCTS(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    impl: *const ImplementationDesc,
    impl_lib: *Step.Compile,
    comptime mode: RunningMode,
    caselist: ?[]const u8,
    caselist_file: ?[]const u8,
) !*Step {
    const arch = if (target.query.cpu_arch) |arch| arch else builtin.cpu.arch;
    if (!arch.isX86())
        return error.NoCTSForPlatform;

    const cts = b.dependency("cts_bin", .{});

    const cts_exe_path = cts.path(b.fmt("deqp-vk-{s}", .{
        switch (if (target.query.os_tag) |tag| tag else builtin.target.os.tag) {
            .linux => "linux.x86_64",
            .windows => "windows.exe",
            .macos => "macos.x86_64",
            else => return error.NoCTSForPlatform,
        },
    }));

    const mustpass = cts.path("vk-default.txt");

    const run = switch (mode) {
        .normal => blk: {
            const run = Step.Run.create(b, "run CTS");
            run.addFileArg(cts_exe_path);
            break :blk run;
        },
        .gdb => blk: {
            const run = b.addSystemCommand(&.{ "gdb", "--args" });
            run.addFileArg(cts_exe_path);
            break :blk run;
        },
        .valgrind => blk: {
            const run = b.addSystemCommand(&.{
                "valgrind",
                "-s",
                "--leak-check=full",
                "--show-leak-kinds=all",
                "--track-origins=no",
            });
            run.addFileArg(cts_exe_path);
            break :blk run;
        },
    };
    run.step.dependOn(&impl_lib.step);

    run.addDirectoryArg2(cts.path(""), .{ .prefix = "--deqp-archive-dir=", .make_absolute = true });
    run.addFileArg2(b.graph.path(.install_lib, impl_lib.out_filename), .{ .prefix = "--deqp-vk-library-path=", .make_absolute = true });
    run.addArg("--deqp-log-filename=vk-cts-logs.qpa");
    run.addArg("--deqp-test-oom=disable");

    if (caselist) |list| {
        run.addArg(b.fmt("--deqp-case={s}", .{list}));
    } else if (caselist_file) |file| {
        run.addArg(b.fmt("--deqp-caselist-file={s}", .{file}));
    } else {
        run.addFileArg2(mustpass, .{ .prefix = "--deqp-caselist-file=", .make_absolute = true });
    }

    run.addPassthruArgs();

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

fn addMultithreadedCTS(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    impl: *const ImplementationDesc,
    impl_lib: *Step.Compile,
    caselist_file: ?[]const u8,
    jobs: ?u32,
) !*Step {
    const arch = if (target.query.cpu_arch) |arch| arch else builtin.cpu.arch;
    if (!arch.isX86())
        return error.NoCTSForPlatform;

    const cts = b.dependency("cts_bin", .{});

    const cts_exe_path = cts.path(b.fmt("deqp-vk-{s}", .{
        switch (if (target.query.os_tag) |tag| tag else builtin.target.os.tag) {
            .linux => "linux.x86_64",
            .windows => "windows.exe",
            .macos => "macos.x86_64",
            else => return error.NoCTSForPlatform,
        },
    }));

    const mustpass = cts.path("vk-default.txt");

    const run = b.addSystemCommand(&.{
        "deqp-runner",
        "run",
        "--timeout",
        "60",
        "--output",
        "./cts",
    });

    run.addArg("--deqp");
    run.addFileArg2(cts_exe_path, .{ .make_absolute = true });

    run.addArg("--caselist");
    if (caselist_file) |file| {
        run.addArg(file);
    } else {
        run.addFileArg2(mustpass, .{ .make_absolute = true });
    }

    if (jobs) |j| {
        run.addArg("-j");
        run.addArg(b.fmt("{d}", .{j}));
    }

    run.addArg("--");

    run.addDirectoryArg2(cts.path(""), .{ .prefix = "--deqp-archive-dir=", .make_absolute = true });
    run.addFileArg2(b.graph.path(.install_lib, impl_lib.out_filename), .{ .prefix = "--deqp-vk-library-path=", .make_absolute = true });
    run.addArg("--deqp-test-oom=disable");

    run.addPassthruArgs();

    run.step.dependOn(&impl_lib.step);

    const run_step = b.step(b.fmt("cts-{s}", .{impl.name}), b.fmt("Run Vulkan conformance tests for libvulkan_{s} in a multithreaded environment", .{impl.name}));
    run_step.dependOn(&run.step);

    return &run.step;
}

// Soft specialized functions

fn customSoft(
    b: *std.Build,
    options: *Step.Options,
    _: *Step.Compile,
    lib_mod: *std.Build.Module,
    _: *std.Build.Module,
    _: *std.Build.Module,
    base_c_mod: *std.Build.Module,
    shader_ir_mod: *std.Build.Module,
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
    lib_mod.addImport("shader_ir", shader_ir_mod);

    const single_threaded_option = b.option(bool, "soft-single-threaded", "Single threaded runtime mode") orelse false;
    const ir_interpreter_option = b.option(bool, "soft-ir-interpreter", "Enable the experimental backend-agnostic IR interpreter") orelse false;
    const shaders_simd_option = b.option(bool, "soft-shader-simd", "Shaders SIMD acceleration") orelse true;
    const compute_dump_early_results_table_option = b.option(u32, "soft-compute-dump-early-results-table", "Dump compute shaders results table before invocation");
    const compute_dump_final_results_table_option = b.option(u32, "soft-compute-dump-final-results-table", "Dump compute shaders results table after invocation");
    const approxiamte_rgb_option = b.option(bool, "soft-approximates-rgb", "Approximate sRGB <-> RGB conversions") orelse true;

    options.addOption(bool, "soft_single_threaded", single_threaded_option);
    options.addOption(bool, "soft_ir_interpreter", ir_interpreter_option);
    options.addOption(bool, "soft_shaders_simd", shaders_simd_option);
    options.addOption(?u32, "soft_compute_dump_early_results_table", compute_dump_early_results_table_option);
    options.addOption(?u32, "soft_compute_dump_final_results_table", compute_dump_final_results_table_option);
    options.addOption(bool, "soft_approximates_rgb", approxiamte_rgb_option);
}

// Flint specialized functions

fn customFlint(
    b: *std.Build,
    options: *Step.Options,
    _: *Step.Compile,
    lib_mod: *std.Build.Module,
    _: *std.Build.Module,
    _: *std.Build.Module,
    base_c_mod: *std.Build.Module,
    shader_ir_mod: *std.Build.Module,
    _: std.Build.ResolvedTarget,
    _: std.builtin.OptimizeMode,
    _: bool,
) !void {
    lib_mod.addImport("intel_c", base_c_mod);
    lib_mod.addImport("shader_ir", shader_ir_mod);

    const dump_common_ir = b.option(bool, "flint-dump-common-ir", "Print backend-agnostic shader IR after translation") orelse false;
    const dump_ir = b.option(bool, "flint-dump-ir", "Print final Flint IR after backend lowering") orelse false;

    options.addOption(bool, "flint_dump_common_ir", dump_common_ir);
    options.addOption(bool, "flint_dump_ir", dump_ir);
}

// Phi specialized functions

fn customPhi(
    b: *std.Build,
    options: *Step.Options,
    lib: *Step.Compile,
    lib_mod: *std.Build.Module,
    _: *std.Build.Module,
    _: *std.Build.Module,
    base_c_mod: *std.Build.Module,
    shader_ir_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
) !void {
    const daemon_remote_path = b.option(
        []const u8,
        "phi-daemon-remote-path",
        "Path where the Xeon Phi daemon is copied on the card",
    ) orelse "/tmp/phi_device.mic";

    const daemon_host_prefix = b.option(
        []const u8,
        "phi-daemon-host-prefix",
        "Host prefix used to reach cards over ssh/scp; card N uses <prefix>N",
    ) orelse "mic";

    options.addOption([]const u8, "phi_daemon_remote_path", daemon_remote_path);
    options.addOption([]const u8, "phi_daemon_host_prefix", daemon_host_prefix);

    lib_mod.addImport("phi_c", base_c_mod);
    lib_mod.addImport("shader_ir", shader_ir_mod);

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

    const build_card = b.option(
        bool,
        "phi-build-daemon",
        "Build the Phi device daemon",
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

    const daemon = try addPhiDaemon(b, optimize, cc, sysroot);
    const install_daemon = b.addInstallFile(daemon, "lib/phi_device.mic");
    lib.step.dependOn(&install_daemon.step);

    const embedded_daemon = addEmbeddedPhiDaemon(b, daemon);
    lib_mod.addAnonymousImport("phi_daemon", .{
        .root_source_file = embedded_daemon,
    });
}

fn addPhiDaemonCompilerArgs(cmd: *Step.Run, b: *std.Build, optimize: std.builtin.OptimizeMode, sysroot: ?[]const u8) void {
    cmd.addArgs(&.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wno-unused-parameter",
        "-Wno-unused-variable",
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
        .ReleaseFast => cmd.addArgs(&.{ "-O3", "-DNDEBUG", "-DNOLOGS" }),
        .ReleaseSmall => cmd.addArgs(&.{ "-Os", "-DNDEBUG" }),
    }
}

fn addPhiDaemon(b: *std.Build, optimize: std.builtin.OptimizeMode, cc: []const u8, sysroot: ?[]const u8) !std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{cc});
    addPhiDaemonCompilerArgs(cmd, b, optimize, sysroot);

    const sources = [_][]const u8{
        "src/phi/mic/main.c",
        "src/phi/mic/Blitter.c",
        "src/phi/mic/BlitFormats.c",
        "src/phi/mic/Buffer.c",
        "src/phi/mic/CommandBuffer.c",
        "src/phi/mic/Daemon.c",
        "src/phi/mic/Image.c",
        "src/phi/mic/Logger.c",
        "src/phi/mic/Memory.c",
        "src/phi/mic/Queue.c",
        "src/phi/mic/Transport.c",
        "src/phi/mic/WorkerPool.c",
        // Add non-AVX files here
    };

    for (sources) |source| {
        cmd.addFileArg(b.path(source));
    }

    // Keep KNC AVX-512/IMCI code in separate translation units. The GCC port
    // in use must not compile the daemon's scalar/control code with -mavx512f
    const avx_sources = [_][]const u8{
        "src/phi/mic/avx/Blit.c",
        "src/phi/mic/avx/Copy.c",
        "src/phi/mic/avx/Fill.c",
        // Add AVX files here
    };

    for (avx_sources, 0..) |source, index| {
        const avx_cmd = b.addSystemCommand(&.{cc});
        addPhiDaemonCompilerArgs(avx_cmd, b, optimize, sysroot);

        avx_cmd.addArg("-mavx512f");
        avx_cmd.addArg("-c");
        avx_cmd.addFileArg(b.path(source));
        avx_cmd.addArg("-o");

        const avx_object = avx_cmd.addOutputFileArg(
            b.fmt("phi_avx_{d}.o", .{index}),
        );

        cmd.addFileArg(avx_object);
    }

    cmd.addArgs(&.{ "-lscif", "-lm", "-o" });
    return cmd.addOutputFileArg("phi_device.mic");
}

fn addEmbeddedPhiDaemon(b: *std.Build, daemon: std.Build.LazyPath) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(daemon, "phi_device.mic");
    return wf.add("phi_daemon.zig",
        \\pub const data = @embedFile("phi_device.mic");
    );
}

// Psvk specialized functions

fn installPsvk(b: *std.Build, _: *const ImplementationDesc, lib: *Step.Compile) *Step {
    const vitasdk = b.graph.environ_map.get("VITASDK");
    const tool = struct {
        fn path(bld: *std.Build, sdk: ?[]const u8, name: []const u8) []const u8 {
            return if (sdk) |root| bld.pathJoin(&.{ root, "bin", name }) else name;
        }
    }.path;

    const link_elf = b.addSystemCommand(&.{tool(b, vitasdk, "arm-vita-eabi-gcc")});
    link_elf.addArgs(&.{
        "-O2",
        "-ffunction-sections",
        "-fdata-sections",
        "-fno-builtin",
        "-nostdlib",
        "-Wl,-q",
        "-Wl,-z,nocopyreloc",
        "-Wl,--gc-sections",

        // vita-elf-create appends import/export and relocation metadata to the
        // RX segment. Reserve one Vita page before the RW segment so Debug
        // builds cannot collide with it when the RX segment nearly fills its
        // default 64 KiB alignment gap
        "-Wl,--defsym=__sce_headroom=0x10000",
        "-Wl,-e,module_start",

        // vita-elf-create resolves these names after the ELF link. Make them
        // linker roots so --gc-sections does not discard the uncalled hooks
        "-Wl,-u,module_stop",
        "-Wl,-u,module_exit",
    });
    link_elf.addFileArg(b.path("src/vita/module_bootstrap.c"));
    link_elf.addArg("-o");

    const elf = link_elf.addOutputFileArg("vulkan_psvk.elf");
    link_elf.addArg("-Wl,--whole-archive");
    link_elf.addFileArg(lib.getEmittedBin());
    link_elf.addArgs(&.{
        "-Wl,--no-whole-archive",
        // Allocation is supplied by the host through module_bootstrap.c.
        // Resolve compiler runtime and unwind helpers from libgcc before the
        // Vita import stubs. Thread lifecycle cleanup, timing, and signaling
        // are exported by SceKernelThreadMgr rather than SceLibKernel.
        "-Wl,--start-group",
        "-lgcc",
        "-lSceLibKernel_stub",
        "-lSceKernelThreadMgr_stub",
        "-Wl,--end-group",
    });

    // vita-elf-create's internal `-s` path can fail with "overlapping
    // sections" on Zig's compact ReleaseSmall ELF layout. Normalize section
    // offsets with GNU strip first, as used by VitaSDK's sample pipeline, and
    // leave the original ELF available in Zig's cache for debugging
    const strip_elf = b.addSystemCommand(&.{tool(b, vitasdk, "arm-vita-eabi-strip")});
    strip_elf.addArgs(&.{ "-g", "-o" });

    const stripped_elf = strip_elf.addOutputFileArg("vulkan_psvk.stripped.elf");
    strip_elf.addFileArg(elf);

    const create_velf = b.addSystemCommand(&.{tool(b, vitasdk, "vita-elf-create")});
    if (b.option(bool, "psvk-vita-tools-verbose", "Enable verbose VitaSDK conversion diagnostics") orelse false)
        create_velf.addArg("-v");
    create_velf.addArg("-e");
    create_velf.addFileArg(b.path("src/vita/module.yml"));
    create_velf.addFileArg(stripped_elf);

    const velf = create_velf.addOutputFileArg("vulkan_psvk.velf");

    const create_suprx = b.addSystemCommand(&.{tool(b, vitasdk, "vita-make-fself")});
    create_suprx.addArg("-c");
    create_suprx.addFileArg(velf);

    const suprx = create_suprx.addOutputFileArg("vulkan_psvk.suprx");

    return &b.addInstallLibFile(suprx, "vulkan_psvk.suprx").step;
}
