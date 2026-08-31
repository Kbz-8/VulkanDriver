const std = @import("std");
const shader_ir = @import("shader_ir").ir;
const device = @import("../../device.zig");
const common_ir = @import("../../lower/common_ir.zig");

pub const compute = @import("compute/compute.zig");
pub const compute_pipeline = @import("compute/pipeline.zig");
pub const flag_allocation = @import("flag_allocation.zig");
pub const register_allocation = @import("register_allocation.zig");
pub const validator = @import("validator.zig");

pub const Options = common_ir.Options;
pub const ComputeArtifact = compute_pipeline.Artifact;
pub const Error = compute_pipeline.Error;

pub fn compileCompute(allocator: std.mem.Allocator, module: *shader_ir.module.Module, device_info: device.DeviceInfo, options: Options) Error!ComputeArtifact {
    return compute_pipeline.compile(allocator, module, device_info, options);
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
    try std.testing.expectError(Error.UnsupportedGeneration, compileCompute(std.testing.allocator, &module, other_generation, .{}));

    module.stage = .fragment;
    try std.testing.expectError(Error.UnsupportedStage, compileCompute(std.testing.allocator, &module, gen9_device, .{}));
    module.stage = .compute;

    try std.testing.expectError(Error.UnsupportedDispatchWidth, compileCompute(std.testing.allocator, &module, gen9_device, .{ .dispatch_width = .simd16 }));

    var wide_grf = gen9_device;
    wide_grf.grf_size_bytes = 64;
    try std.testing.expectError(Error.UnsupportedGrfSize, compileCompute(std.testing.allocator, &module, wide_grf, .{}));
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
    var artifact = try compileCompute(std.testing.allocator, &module, gen9_device, .{});
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(artifact.kernel != null);
    const program = &artifact.program;
    const resources = &artifact.resources;

    try std.testing.expect(program.properties.common_ir_lowered);
    try std.testing.expect(program.properties.compute_abi_lowered);
    try std.testing.expectEqual(@as(u16, 1), program.program_data.payload_grf_count);
    try std.testing.expectEqual(@as(u16, 0), program.payload.header_grf.?.number);
    try std.testing.expect(program.properties.block_parameters_lowered);
    try std.testing.expect(program.properties.parallel_copies_lowered);
    try std.testing.expect(program.properties.flags_allocated);
    try std.testing.expect(program.properties.registers_allocated);

    try std.testing.expect(program.properties.resources_lowered);
    try std.testing.expect(program.properties.messages_lowered);
    try std.testing.expect(program.properties.message_addresses_lowered);
    try std.testing.expect(program.properties.message_payloads_lowered);
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

    var load_count: usize = 0;
    var store_count: usize = 0;
    for (program.instructions.entries.items) |instruction_entry| {
        const inst = instruction_entry orelse continue;
        switch (inst.operation) {
            .surface_message => |operation| switch (operation.kind) {
                .read => {
                    try std.testing.expectEqual(@as(u8, 0), operation.binding_table);
                    try std.testing.expectEqual(@as(u8, 1), operation.payload.register_count);
                    try std.testing.expect(operation.response != null);
                    load_count += 1;
                },
                .write => {
                    try std.testing.expectEqual(@as(u8, 1), operation.binding_table);
                    try std.testing.expectEqual(@as(u8, 2), operation.payload.register_count);
                    try std.testing.expect(operation.response == null);
                    store_count += 1;
                },
            },
            .parallel_copy => return error.UnloweredParallelCopy,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), load_count);
    try std.testing.expectEqual(@as(usize, 4), store_count);
}

test "[gen9] target: encode runtime array length" {
    var module = try shader_ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @storage: runtime_array[u32] = storage_buffer[set(0), binding(0)]
        \\    %offset: constant u32 = 16
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %length: u32 = array_length @storage, %offset, stride 4
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    const gen9_device: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var artifact = try compileCompute(std.testing.allocator, &module, gen9_device, .{});
    defer artifact.deinit(std.testing.allocator);

    if (artifact.kernel == null) {
        const encoded = try compute.kernel_encoder.encode(std.testing.allocator, &artifact.program);
        std.testing.allocator.free(encoded);
        return error.TestExpectedEncodedKernel;
    }
    for (artifact.program.instructions.entries.items) |entry| {
        const inst = entry orelse continue;
        try std.testing.expect(inst.operation != .array_length);
    }
}
