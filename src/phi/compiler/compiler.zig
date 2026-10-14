const std = @import("std");
const shader_ir = @import("shader_ir").ir;

pub const abi = @import("abi.zig");
pub const analysis = @import("analysis.zig");
pub const artifact = @import("artifact.zig");
pub const block_layout = @import("block_layout.zig");
pub const code_buffer = @import("code_buffer.zig");
pub const codegen = @import("codegen.zig");
pub const control_flow = @import("control_flow.zig");
pub const edge_copies = @import("edge_copies.zig");
pub const errors = @import("errors.zig");
pub const imci = @import("imci/imci.zig");
pub const liveness = @import("liveness.zig");
pub const register_allocator = @import("register_allocator.zig");

pub const Artifact = artifact.Artifact;
pub const Error = errors.Error;

pub const Options = struct {
    dispatch_width: u8 = 16,
};

pub fn compile(_: std.mem.Allocator, module: *shader_ir.module.Module, options: Options) Error!Artifact {
    switch (module.stage) {
        .compute => {},
        .vertex, .fragment => return Error.UnsupportedStage,
    }

    if (options.dispatch_width != 16)
        return Error.UnsupportedDispatchWidth;

    if (module.entry_point == null)
        return Error.MissingEntryPoint;

    const workgroup_size = module.execution_modes.workgroup_size orelse return Error.MissingWorkgroupSize;

    var invocation_count: u64 = 1;
    for (workgroup_size) |size| {
        if (size == 0) return Error.UnsupportedWorkgroupSize;
        invocation_count = std.math.mul(u64, invocation_count, size) catch return Error.UnsupportedWorkgroupSize;
    }

    shader_ir.validator.validate(module) catch |err| return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.InvalidModule,
    };

    // Opcode and type support belong to code generation, not an input whitelist.
    return Error.CodeGenerationNotImplemented;
}

test "[compiler] foundation declarations compile" {
    std.testing.refAllDecls(abi);
    std.testing.refAllDecls(analysis);
    std.testing.refAllDecls(artifact);
    std.testing.refAllDecls(block_layout);
    std.testing.refAllDecls(code_buffer);
    std.testing.refAllDecls(codegen);
    std.testing.refAllDecls(control_flow);
    std.testing.refAllDecls(edge_copies);
    std.testing.refAllDecls(imci);
    std.testing.refAllDecls(liveness);
    std.testing.refAllDecls(register_allocator);
}

test "[compiler] validate compute configuration before code generation" {
    var module = try shader_ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    try std.testing.expectError(Error.UnsupportedDispatchWidth, compile(std.testing.allocator, &module, .{ .dispatch_width = 8 }));
    try std.testing.expectError(Error.MissingWorkgroupSize, compile(std.testing.allocator, &module, .{}));

    module.execution_modes.workgroup_size = .{ 1, 0, 1 };
    try std.testing.expectError(Error.UnsupportedWorkgroupSize, compile(std.testing.allocator, &module, .{}));
    module.execution_modes.workgroup_size = @splat(std.math.maxInt(u32));
    try std.testing.expectError(Error.UnsupportedWorkgroupSize, compile(std.testing.allocator, &module, .{}));
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    const entry_point = module.entry_point.?;
    module.entry_point = null;
    try std.testing.expectError(Error.MissingEntryPoint, compile(std.testing.allocator, &module, .{}));
    module.entry_point = entry_point;

    const block = module.blocks.getMut(module.functions.get(entry_point).?.entry_block.?).?;
    block.terminator = null;
    try std.testing.expectError(Error.InvalidModule, compile(std.testing.allocator, &module, .{}));
}
