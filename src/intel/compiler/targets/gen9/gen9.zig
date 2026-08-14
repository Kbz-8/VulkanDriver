const std = @import("std");
const shader_ir = @import("shader_ir").ir;
const device = @import("../../device.zig");
const program_ir = @import("../../ir/program.zig");
const common_ir = @import("../../lower/common_ir.zig");

pub const compute = @import("compute/compute.zig");
pub const validator = @import("validator.zig");

pub const Options = common_ir.Options;
pub const ResourceLoweringError = compute.resource_lowering.Error;

pub const Error = common_ir.Error || compute.Error || error{
    UnsupportedGeneration,
    UnsupportedStage,
    UnsupportedDispatchWidth,
    UnsupportedGrfSize,
};

pub fn lower(
    allocator: std.mem.Allocator,
    module: *shader_ir.module.Module,
    device_info: device.DeviceInfo,
    options: Options,
) Error!program_ir.Program {
    if (device_info.generation != .gen9)
        return Error.UnsupportedGeneration;
    if (module.stage != .compute)
        return Error.UnsupportedStage;
    if (options.dispatch_width != .simd8 or !device_info.supportsDispatch(.simd8))
        return Error.UnsupportedDispatchWidth;
    if (device_info.grf_size_bytes != 32)
        return Error.UnsupportedGrfSize;
    if (module.execution_modes.workgroup_size) |workgroup_size|
        try compute.validateWorkgroupSize(workgroup_size);

    var program = try common_ir.lower(allocator, module, device_info, options);
    errdefer program.deinit();
    validator.validate(&program) catch return Error.InvalidLoweredProgram;
    return program;
}

pub fn lowerComputeResources(program: *program_ir.Program, layout: *const compute.ResourceLayout) ResourceLoweringError!void {
    try compute.resource_lowering.run(program, layout);
    validator.validate(program) catch return ResourceLoweringError.InvalidProgram;
}

test "[gen9] target: reject unsupported target configurations" {
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

    const gen9_device: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var other_generation = gen9_device;
    other_generation.generation = .gen11;
    try std.testing.expectError(Error.UnsupportedGeneration, lower(std.testing.allocator, &module, other_generation, .{}));

    module.stage = .fragment;
    try std.testing.expectError(Error.UnsupportedStage, lower(std.testing.allocator, &module, gen9_device, .{}));
    module.stage = .compute;

    try std.testing.expectError(Error.UnsupportedDispatchWidth, lower(std.testing.allocator, &module, gen9_device, .{ .dispatch_width = .simd16 }));

    var wide_grf = gen9_device;
    wide_grf.grf_size_bytes = 64;
    try std.testing.expectError(Error.UnsupportedGrfSize, lower(std.testing.allocator, &module, wide_grf, .{}));
}
