const std = @import("std");
const shader_ir = @import("shader_ir").ir;
const device = @import("../device.zig");
const program_ir = @import("../ir/program.zig");
const common_ir = @import("../lower/common_ir.zig");

pub const gen9 = @import("gen9/gen9.zig");

pub const ComputeResourceLayout = gen9.compute.ResourceLayout;
pub const ResourceLayoutError = gen9.compute.resource_layout.Error || error{UnsupportedGeneration};
pub const ResourceLoweringError = gen9.ResourceLoweringError || error{UnsupportedGeneration};

pub const Error = gen9.Error || error{UnsupportedGeneration};
pub const ValidationError = gen9.validator.Error || error{UnsupportedGeneration};

pub fn lower(
    allocator: std.mem.Allocator,
    module: *shader_ir.module.Module,
    device_info: device.DeviceInfo,
    options: common_ir.Options,
) Error!program_ir.Program {
    return switch (device_info.generation) {
        .gen9 => gen9.lower(allocator, module, device_info, options),
        .gen10, .gen11 => Error.UnsupportedGeneration,
    };
}

pub fn layoutComputeResources(allocator: std.mem.Allocator, program: *const program_ir.Program) ResourceLayoutError!ComputeResourceLayout {
    return switch (program.device_info.generation) {
        .gen9 => ComputeResourceLayout.init(allocator, program),
        .gen10, .gen11 => ResourceLayoutError.UnsupportedGeneration,
    };
}

pub fn lowerComputeResources(program: *program_ir.Program, layout: *const ComputeResourceLayout) ResourceLoweringError!void {
    return switch (program.device_info.generation) {
        .gen9 => gen9.lowerComputeResources(program, layout),
        .gen10, .gen11 => ResourceLoweringError.UnsupportedGeneration,
    };
}

pub fn validate(program: *const program_ir.Program) ValidationError!void {
    return switch (program.device_info.generation) {
        .gen9 => gen9.validator.validate(program),
        .gen10, .gen11 => ValidationError.UnsupportedGeneration,
    };
}
