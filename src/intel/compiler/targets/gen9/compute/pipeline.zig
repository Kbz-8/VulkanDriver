const std = @import("std");
const shader_ir = @import("shader_ir").ir;

const device = @import("../../../device.zig");
const program_ir = @import("../../../ir/program.zig");
const common_ir = @import("../../../lower/common_ir.zig");
const block_arguments = @import("../../../lower/block_arguments.zig");
const parallel_copies = @import("../../../lower/parallel_copies.zig");
const flag_allocation = @import("../flag_allocation.zig");
const register_allocation = @import("../register_allocation.zig");

const compute = @import("compute.zig");
const abi = @import("abi.zig");
const array_length_lowering = @import("array_length_lowering.zig");
const kernel_encoder = @import("kernel_encoder.zig");
const message_addresses = @import("message_addresses.zig");
const message_lowering = @import("message_lowering.zig");
const message_payloads = @import("message_payloads.zig");
const resource_layout = @import("resource_layout.zig");
const resource_lowering = @import("resource_lowering.zig");
const regions = @import("regions.zig");
const system_values = @import("system_values.zig");

pub const Error = common_ir.Error ||
    block_arguments.Error ||
    parallel_copies.Error ||
    abi.Error ||
    array_length_lowering.Error ||
    kernel_encoder.Error ||
    message_addresses.Error ||
    message_lowering.Error ||
    message_payloads.Error ||
    resource_layout.Error ||
    resource_lowering.Error ||
    system_values.Error ||
    flag_allocation.Error ||
    register_allocation.Error ||
    compute.Error ||
    error{
        UnsupportedGeneration,
        UnsupportedStage,
        UnsupportedDispatchWidth,
        UnsupportedGrfSize,
    };

pub const Artifact = struct {
    program: program_ir.Program,
    resources: resource_layout.Layout,
    kernel: ?[]u8,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        if (self.kernel) |kernel|
            allocator.free(kernel);
        self.resources.deinit(allocator);
        self.program.deinit();
        self.* = undefined;
    }
};

pub fn compile(allocator: std.mem.Allocator, module: *shader_ir.module.Module, device_info: device.DeviceInfo, options: common_ir.Options) Error!Artifact {
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

    var program = try common_ir.lower(
        allocator,
        module,
        device_info,
        options,
    );
    errdefer program.deinit();

    try abi.run(&program);
    try system_values.run(&program);
    try block_arguments.run(allocator, &program);
    try parallel_copies.run(allocator, &program);

    var resources = try resource_layout.Layout.init(allocator, &program);
    errdefer resources.deinit(allocator);

    try resource_lowering.run(&program, &resources);
    try array_length_lowering.run(&program, &resources);
    try message_lowering.run(&program);
    try message_addresses.run(&program);
    try message_payloads.run(&program);
    regions.run(&program);
    try flag_allocation.run(allocator, &program);
    try register_allocation.run(allocator, &program);

    const kernel = kernel_encoder.encode(allocator, &program) catch |err| encoding_error: {
        std.log.scoped(.FlintCompiler).err("Gen9 EU kernel encoding failed: {s}", .{@errorName(err)});
        break :encoding_error switch (err) {
            error.UnsupportedControlFlow,
            error.UnsupportedOperation,
            error.UnsupportedPredication,
            error.UnsupportedExecutionSize,
            error.UnsupportedDataType,
            error.UnsupportedOperand,
            error.InvalidRegister,
            error.InvalidRegion,
            error.EotRegisterUnavailable,
            => null,
            else => return err,
        };
    };
    errdefer if (kernel) |bytes| allocator.free(bytes);

    return .{
        .program = program,
        .resources = resources,
        .kernel = kernel,
    };
}
