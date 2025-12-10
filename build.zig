const std = @import("std");
const Step = std.Build.Step;
const zcc = @import("compile_commands");
const builtin = @import("builtin");

const ImplementationDesc = struct {
    name: []const u8,
    root_source_file: []const u8,
    vulkan_version: std.SemanticVersion,
    custom: ?*const fn (*std.Build, *std.Build.Step.Compile) anyerror!void = null,
};

const implementations = [_]ImplementationDesc{
    .{
        .name = "soft",
        .root_source_file = "src/soft/lib.zig",
        .vulkan_version = .{ .major = 1, .minor = 0, .patch = 0 },
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
    const vulkan_utility_libraries = b.dependency("vulkan_utility_libraries", .{});

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    }).module("vulkan-zig");

    base_mod.addImport("zdt", zdt);
    base_mod.addImport("vulkan", vulkan);
    base_mod.addSystemIncludePath(vulkan_headers.path("include"));
    base_mod.addSystemIncludePath(vulkan_utility_libraries.path("include"));

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

        const lib = b.addLibrary(.{
            .name = b.fmt("vulkan_{s}", .{impl.name}),
            .root_module = lib_mod,
            .linkage = .dynamic,
            .use_llvm = true, // Fixes some random bugs happenning with custom backend. Investigations needed
        });

        if (impl.custom) |custom| {
            custom(b, lib) catch continue;
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

        const lib_tests = b.addTest(.{ .root_module = lib_mod });

        const run_tests = b.addRunArtifact(lib_tests);
        const test_step = b.step(b.fmt("test-{s}", .{impl.name}), b.fmt("Run libvulkan_{s} tests", .{impl.name}));
        test_step.dependOn(&run_tests.step);

        const c_test = addCTest(b, target, optimize, vulkan_headers, &impl, lib) catch continue;

        try targets.append(b.allocator, c_test);
        try targets.append(b.allocator, lib);
        _ = zcc.createStep(b, "cdb", try targets.toOwnedSlice(b.allocator));

        (try addCTestRunner(b, &impl, c_test, false)).dependOn(&lib_install.step);
        (try addCTestRunner(b, &impl, c_test, true)).dependOn(&lib_install.step);

        (try addCTS(b, target, &impl, lib, false)).dependOn(&lib_install.step);
        (try addCTS(b, target, &impl, lib, true)).dependOn(&lib_install.step);

        (try addMultithreadedCTS(b, target, &impl, lib)).dependOn(&lib_install.step);
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

fn customSoft(b: *std.Build, lib: *std.Build.Step.Compile) !void {
    const cpuinfo = b.lazyDependency("cpuinfo", .{}) orelse return error.UnresolvedDependency;
    lib.addSystemIncludePath(cpuinfo.path("include"));
    lib.linkLibrary(cpuinfo.artifact("cpuinfo"));
}

fn addCTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, vulkan_headers: *std.Build.Dependency, impl: *const ImplementationDesc, impl_lib: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const volk = b.lazyDependency("volk", .{}) orelse return error.DepNotFound;
    const kvf = b.lazyDependency("kvf", .{}) orelse return error.DepNotFound;
    const stb = b.lazyDependency("stb", .{}) orelse return error.DepNotFound;

    const exe = b.addExecutable(.{
        .name = b.fmt("c_test_vulkan_{s}", .{impl.name}),
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addSystemIncludePath(volk.path(""));
    exe.root_module.addSystemIncludePath(kvf.path(""));
    exe.root_module.addSystemIncludePath(stb.path(""));
    exe.root_module.addSystemIncludePath(vulkan_headers.path("include"));

    exe.root_module.addCSourceFile(.{
        .file = b.path("test/c/main.c"),
        .flags = &.{b.fmt("-DLIBVK=\"{s}\"", .{impl_lib.name})},
    });

    const install = b.addInstallArtifact(exe, .{});
    install.step.dependOn(&impl_lib.step);

    return exe;
}

fn addCTestRunner(b: *std.Build, impl: *const ImplementationDesc, exe: *std.Build.Step.Compile, comptime gdb: bool) !*std.Build.Step {
    const run = b.addRunArtifact(exe);
    if (gdb) {
        try run.argv.insert(b.allocator, 0, .{ .bytes = b.fmt("gdb", .{}) }); // Hacky
    }
    run.step.dependOn(&exe.step);

    const run_step = b.step(b.fmt("test-c-{s}{s}", .{ impl.name, if (gdb) "-gdb" else "" }), b.fmt("Run libvulkan_{s} C test{s}", .{ impl.name, if (gdb) " within GDB" else "" }));
    run_step.dependOn(&run.step);

    return &run.step;
}

fn addCTS(b: *std.Build, target: std.Build.ResolvedTarget, impl: *const ImplementationDesc, impl_lib: *std.Build.Step.Compile, comptime gdb: bool) !*std.Build.Step {
    const cts = b.dependency("cts_bin", .{});

    const cts_exe_name = cts.path(b.fmt("deqp-vk-{s}", .{
        switch (if (target.query.os_tag) |tag| tag else builtin.target.os.tag) {
            .linux => "linux.x86_64",
            else => unreachable,
        },
    }));

    const mustpass = try cts.path(
        b.fmt("mustpass/{}.{}.0/vk-default.txt", .{
            impl.vulkan_version.major,
            impl.vulkan_version.minor,
        }),
    ).getPath3(b, null).toString(b.allocator);

    const cts_exe_path = try cts_exe_name.getPath3(b, null).toString(b.allocator);

    const run = b.addSystemCommand(&[_][]const u8{if (gdb) "gdb" else cts_exe_path});
    run.step.dependOn(&impl_lib.step);

    if (gdb) {
        run.addArg("--args");
        run.addArg(cts_exe_path);
    }

    run.addArg(b.fmt("--deqp-archive-dir={s}", .{try cts.path("").getPath3(b, null).toString(b.allocator)}));
    run.addArg(b.fmt("--deqp-vk-library-path={s}", .{b.getInstallPath(.lib, impl_lib.out_lib_filename)}));
    run.addArg("--deqp-log-filename=vk-cts-logs.qpa");
    run.addArg("--deqp-no-program-fail=enable"); // Option added by my fork, doubt it will be merge oneday

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

    const run_step = b.step(b.fmt("test-conformance-{s}{s}", .{ impl.name, if (gdb) "-gdb" else "" }), b.fmt("Run Vulkan conformance tests for libvulkan_{s}{s}", .{ impl.name, if (gdb) " within GDB" else "" }));
    run_step.dependOn(&run.step);

    if (!gdb) {
        const run_to_xml = b.addSystemCommand(&[_][]const u8{ "python", "./scripts/cts_logs_to_xml.py", "./vk-cts-logs.qpa", "./vk-cts-logs.xml" });

        const run_to_report = b.addSystemCommand(&[_][]const u8{ "python", "./scripts/cts_report_to_html.py", "./vk-cts-logs.xml", "vk-cts-report.html" });
        run_to_report.step.dependOn(&run_to_xml.step);

        const run_report_step = b.step(b.fmt("test-conformance-{s}-result-to-html", .{impl.name}), b.fmt("Run Vulkan conformance tests for libvulkan_{s} with a HTML report", .{impl.name}));
        run_report_step.dependOn(&run_to_report.step);
    }

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

    const mustpass_path = try cts.path("mustpass/master/vk-default.txt").getPath3(b, null).toString(b.allocator);
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
    run.addArg("--");
    run.addArg(b.fmt("--deqp-archive-dir={s}", .{try cts.path("").getPath3(b, null).toString(b.allocator)}));
    run.addArg(b.fmt("--deqp-vk-library-path={s}", .{b.getInstallPath(.lib, impl_lib.out_lib_filename)}));

    const run_step = b.step(b.fmt("test-conformance-multithreaded-{s}", .{impl.name}), b.fmt("Run Vulkan conformance tests in a multithreaded environment for libvulkan_{s}", .{impl.name}));
    run_step.dependOn(&run.step);

    return &run.step;
}
