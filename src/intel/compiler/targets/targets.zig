const std = @import("std");
const shader_ir = @import("shader_ir").ir;
const device = @import("../device.zig");
const program_ir = @import("../ir/program.zig");
const common_ir = @import("../lower/common_ir.zig");

pub const gen9 = @import("gen9/gen9.zig");

pub const ComputeArtifact = gen9.ComputeArtifact;
pub const ComputeResourceLayout = gen9.compute.ResourceLayout;
pub const Error = gen9.Error || error{UnsupportedGeneration};
pub const ValidationError = gen9.validator.Error || error{UnsupportedGeneration};

pub fn compileCompute(
    allocator: std.mem.Allocator,
    module: *shader_ir.module.Module,
    device_info: device.DeviceInfo,
    options: common_ir.Options,
) Error!ComputeArtifact {
    return switch (device_info.generation) {
        .gen9 => gen9.compileCompute(allocator, module, device_info, options),
        .gen10, .gen11 => Error.UnsupportedGeneration,
    };
}

pub fn validate(program: *const program_ir.Program) ValidationError!void {
    return switch (program.device_info.generation) {
        .gen9 => gen9.validator.validate(program),
        .gen10, .gen11 => ValidationError.UnsupportedGeneration,
    };
}
