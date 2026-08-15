const std = @import("std");
const shader_ir = @import("shader_ir").ir;
const device = @import("../../device.zig");
const program_ir = @import("../../ir/program.zig");
const common_ir = @import("../../lower/common_ir.zig");
const parallel_copies = @import("../../lower/parallel_copies.zig");

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

pub fn lower(allocator: std.mem.Allocator, module: *shader_ir.module.Module, device_info: device.DeviceInfo, options: Options) Error!program_ir.Program {
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
    parallel_copies.run(allocator, &program) catch |err| return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.InvalidProgram => Error.InvalidLoweredProgram,
    };
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

test "[gen9] target: lower 256 KiB SSBO copy loop" {
    const source =
        \\shader compute @main
        \\{
        \\    @source: vec4[u32] = storage_buffer[set(0), binding(0)]
        \\    @destination: vec4[u32] = storage_buffer[set(0), binding(1)]
        \\    %zero: constant i32 = bits(0x0)
        \\    %one: constant i32 = bits(0x1)
        \\    %stride: constant i32 = bits(0x10)
        \\    %element_count: constant i32 = bits(0x4000)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            branch .header(%zero)
        \\        .header(%index: i32):
        \\            %in_bounds: bool = cmp_signed_less %index, %element_count
        \\            conditional_branch %in_bounds, .body(), .exit()
        \\        .body():
        \\            %signed_offset: i32 = integer_multiply %index, %stride
        \\            %offset: u32 = bitcast %signed_offset
        \\            %value: vec4[u32] = load_buffer @source, %offset
        \\            store_buffer @destination, %offset, %value
        \\            branch .continue()
        \\        .continue():
        \\            %next: i32 = integer_add %index, %one
        \\            branch .header(%next)
        \\        .exit():
        \\            return
        \\    }
        \\}
    ;

    var module = try shader_ir.parser.parseString(std.testing.allocator, source);
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    const gen9_device: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = try lower(std.testing.allocator, &module, gen9_device, .{});
    defer program.deinit();

    try std.testing.expect(program.properties.common_ir_lowered);
    try std.testing.expect(program.properties.block_parameters_lowered);
    try std.testing.expect(program.properties.parallel_copies_lowered);

    var resources = try compute.ResourceLayout.init(std.testing.allocator, &program);
    defer resources.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), resources.bindings.len);
    try std.testing.expectEqual(compute.resource_layout.Binding{
        .set = 0,
        .binding = 0,
        .binding_table_index = 0,
    }, resources.bindings[0]);
    try std.testing.expectEqual(compute.resource_layout.Binding{
        .set = 0,
        .binding = 1,
        .binding_table_index = 1,
    }, resources.bindings[1]);

    try lowerComputeResources(&program, &resources);
    try validator.validate(&program);

    var load_offsets: [4]bool = @splat(false);
    var store_offsets: [4]bool = @splat(false);
    var load_count: usize = 0;
    var store_count: usize = 0;
    for (program.instructions.entries.items) |instruction_entry| {
        const inst = instruction_entry orelse continue;
        switch (inst.operation) {
            .load_buffer => |operation| {
                try std.testing.expectEqual(@as(u8, 0), operation.buffer.binding_table);
                try std.testing.expect(operation.immediate_offset % @sizeOf(u32) == 0);
                const component = operation.immediate_offset / @sizeOf(u32);
                try std.testing.expect(component < load_offsets.len);
                load_offsets[component] = true;
                load_count += 1;
            },
            .store_buffer => |operation| {
                try std.testing.expectEqual(@as(u8, 1), operation.buffer.binding_table);
                try std.testing.expect(operation.immediate_offset % @sizeOf(u32) == 0);
                const component = operation.immediate_offset / @sizeOf(u32);
                try std.testing.expect(component < store_offsets.len);
                store_offsets[component] = true;
                store_count += 1;
            },
            .parallel_copy => return error.UnloweredParallelCopy,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), load_count);
    try std.testing.expectEqual(@as(usize, 4), store_count);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, load_offsets);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, store_offsets);
}
