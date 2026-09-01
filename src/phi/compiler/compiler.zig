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

pub fn compileCompute(allocator: std.mem.Allocator, module: *shader_ir.module.Module, options: Options) Error!Artifact {
    _ = allocator;

    if (module.stage != .compute)
        return error.UnsupportedStage;
    if (module.entry_point == null)
        return error.MissingEntryPoint;
    if (module.execution_modes.workgroup_size == null)
        return error.MissingWorkgroupSize;
    if (!module.properties.structured_control_flow)
        return error.UnstructuredControlFlow;
    if (options.dispatch_width != 16)
        return error.UnsupportedType;

    return error.CodeGenerationNotImplemented;
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

test "[compiler] rejects non-compute modules before code generation" {
    var module = shader_ir.module.Module.init(std.testing.allocator, .vertex);
    defer module.deinit();

    try std.testing.expectError(error.UnsupportedStage, compileCompute(std.testing.allocator, &module, .{}));
}
