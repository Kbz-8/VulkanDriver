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

test "[gen9] target: reuse registers across conditional blocks and a carrying loop" {
    var module = try shader_ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @storage: u32 = storage_buffer[set(0), binding(0)]
        \\    %offset: constant u32 = bits(0x0)
        \\    %zero: constant i32 = bits(0x0)
        \\    %one: constant i32 = bits(0x1)
        \\    %limit: constant i32 = bits(0x8)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %input: u32 = load_buffer @storage, %offset
        \\            %seed: i32 = bitcast %input
        \\            %retained: i32 = integer_add %seed, %one
        \\            branch .test1(%seed)
        \\        .test1(%a: i32):
        \\            %c1: bool = cmp_signed_less %a, %limit
        \\            conditional_branch %c1, .add1(), .test2(%a)
        \\        .add1():
        \\            %b: i32 = integer_add %a, %one
        \\            branch .test2(%b)
        \\        .test2(%c: i32):
        \\            %c2: bool = cmp_signed_less %c, %limit
        \\            conditional_branch %c2, .add2(), .test3(%c)
        \\        .add2():
        \\            %d: i32 = integer_add %c, %one
        \\            branch .test3(%d)
        \\        .test3(%e: i32):
        \\            %c3: bool = cmp_signed_less %e, %limit
        \\            conditional_branch %c3, .add3(), .test4(%e)
        \\        .add3():
        \\            %f: i32 = integer_add %e, %one
        \\            branch .test4(%f)
        \\        .test4(%g: i32):
        \\            %c4: bool = cmp_signed_less %g, %limit
        \\            conditional_branch %c4, .add4(), .test5(%g)
        \\        .add4():
        \\            %h: i32 = integer_add %g, %one
        \\            branch .test5(%h)
        \\        .test5(%j: i32):
        \\            %c5: bool = cmp_signed_less %j, %limit
        \\            conditional_branch %c5, .add5(), .header(%zero, %j)
        \\        .add5():
        \\            %k: i32 = integer_add %j, %one
        \\            branch .header(%zero, %k)
        \\        .header(%index: i32, %sum: i32):
        \\            %in_bounds: bool = cmp_signed_less %index, %limit
        \\            conditional_branch %in_bounds, .body(), .exit()
        \\        .body():
        \\            %next_sum: i32 = integer_add %sum, %index
        \\            %next_index: i32 = integer_add %index, %one
        \\            branch .header(%next_index, %next_sum)
        \\        .exit():
        \\            %result: i32 = integer_add %sum, %retained
        \\            %output: u32 = bitcast %result
        \\            store_buffer @storage, %offset, %output
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    var artifact = try compileCompute(std.testing.allocator, &module, .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    }, .{});
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(artifact.kernel != null);
    const program = &artifact.program;
    try std.testing.expect(program.properties.registers_allocated);
    try std.testing.expect(program.properties.flags_allocated);

    const PhysicalGrf = @import("../../ir/operand.zig").PhysicalGrf;
    var retained: ?PhysicalGrf = null;
    var last_rhs: ?PhysicalGrf = null;
    var destinations = std.StaticBitSet(128).initEmpty();
    var binary_count: usize = 0;
    var compare_count: usize = 0;
    var store_count: usize = 0;
    for (program.instructions.entries.items) |entry| {
        const inst = entry orelse continue;
        switch (inst.operation) {
            .binary => |op| {
                const destination = op.destination.register.physical_grf;
                if (retained) |live| {
                    // The entry value survives every conditional and the loop until the final add.
                    try std.testing.expect(destination.number != live.number);
                } else {
                    retained = destination;
                }
                destinations.set(destination.number);
                binary_count += 1;
                last_rhs = if (op.rhs.register == .physical_grf) op.rhs.register.physical_grf else null;
            },
            .compare => compare_count += 1,
            .surface_message => |op| {
                if (op.kind == .write) store_count += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 6), compare_count);
    try std.testing.expectEqual(@as(usize, 9), binary_count);
    try std.testing.expectEqual(@as(usize, 1), store_count);
    try std.testing.expect(retained != null and last_rhs != null);
    try std.testing.expectEqual(retained.?, last_rhs.?);
    // Count arithmetic GRFs before the encoder's EOT header copy, not the total
    // high-water mark: EOT reserves r112 even when shader temporaries reuse GRFs.
    try std.testing.expect(destinations.count() < binary_count);
    try std.testing.expect(program.program_data.total_grf_count >= 113);
}

test "[gen9] target: CTS multiple invocations invert copy" {
    var module = try shader_ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @source: runtime_array[u32] = storage_buffer[set(0), binding(0)]
        \\    @destination: runtime_array[u32] = storage_buffer[set(0), binding(1)]
        \\    @global_id: vec3[u32] = input[builtin(global_invocation_id)]
        \\    @group_count: vec3[u32] = input[builtin(num_workgroups)]
        \\    %zero: constant u32 = 0
        \\    %one: constant u32 = 1
        \\    %stride: constant u32 = 4
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %id: vec3[u32] = load_interface @global_id
        \\            %x: u32 = composite_extract %id[0]
        \\            %y: u32 = composite_extract %id[1]
        \\            %z: u32 = composite_extract %id[2]
        \\            %count: vec3[u32] = load_interface @group_count
        \\            %nx: u32 = composite_extract %count[0]
        \\            %ny: u32 = composite_extract %count[1]
        \\            %nz: u32 = composite_extract %count[2]
        \\            %zy: u32 = integer_multiply %z, %ny
        \\            %row: u32 = integer_add %zy, %y
        \\            %row_start: u32 = integer_multiply %row, %nx
        \\            %linear_id: u32 = integer_add %row_start, %x
        \\            %nxy: u32 = integer_multiply %nx, %ny
        \\            %invocations: u32 = integer_multiply %nxy, %nz
        \\            %length: u32 = array_length @source, %zero, stride 4
        \\            %per_invocation: u32 = unsigned_divide %length, %invocations
        \\            %begin: u32 = integer_multiply %linear_id, %per_invocation
        \\            %end: u32 = integer_add %begin, %per_invocation
        \\            branch .header(%begin)
        \\        .header(%index: u32):
        \\            %in_bounds: bool = cmp_unsigned_less %index, %end
        \\            conditional_branch %in_bounds, .body(), .exit()
        \\        .body():
        \\            %offset: u32 = integer_multiply %index, %stride
        \\            %value: u32 = load_buffer @source, %offset
        \\            %inverted: u32 = bitwise_not %value
        \\            store_buffer @destination, %offset, %inverted
        \\            branch .continue()
        \\        .continue():
        \\            %next: u32 = integer_add %index, %one
        \\            branch .header(%next)
        \\        .exit():
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    var artifact = try compileCompute(std.testing.allocator, &module, .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    }, .{});
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expect(artifact.kernel != null);
    const program = &artifact.program;
    try std.testing.expect(program.properties.system_values_lowered);
    try std.testing.expect(program.properties.resources_lowered);
    try std.testing.expect(program.properties.registers_allocated);
    try std.testing.expectEqual(@as(usize, 2), artifact.resources.bindings.len);

    const header_offsets = [_]u8{ 4, 24, 28 };
    var header_components: usize = 0;
    var internal_reads: usize = 0;
    var source_reads: usize = 0;
    var destination_writes: usize = 0;
    // Inspect block order: message payload moves are inserted before their sends.
    for (program.blocks.entries.items) |block_entry| {
        const block = block_entry orelse continue;
        for (block.instructions.items, 0..) |instruction_id, index| {
            const inst = program.instructions.get(instruction_id).?;
            switch (inst.operation) {
                .load_global_invocation_id, .load_num_workgroups => return error.UnloweredSystemValue,
                .array_length => return error.UnloweredArrayLength,
                .move => |op| {
                    if (op.source.register == .physical_grf and op.source.register.physical_grf.number == 0) {
                        // Ignore the whole-header EOT copy, if present.
                        if (op.source.register.physical_grf.byte_offset == 0) continue;
                        try std.testing.expect(header_components < header_offsets.len);
                        try std.testing.expectEqual(header_offsets[header_components], op.source.register.physical_grf.byte_offset);

                        header_components += 1;
                    }
                },
                .surface_message => |op| {
                    if (op.binding_table == artifact.resources.bindings.len) {
                        try std.testing.expectEqual(.read, op.kind);
                        try std.testing.expect(index > 0);
                        const payload = program.instructions.get(block.instructions.items[index - 1]).?.operation.move;
                        try std.testing.expectEqual(op.payload.base, payload.destination.register);
                        // Three NumWorkgroups loads, then source buffer byte size.
                        const offsets = [_]u32{ 16, 20, 24, 0 };
                        try std.testing.expect(internal_reads < offsets.len);
                        try std.testing.expectEqual(offsets[internal_reads], payload.source.register.immediate.u32);
                        internal_reads += 1;
                    } else if (op.kind == .read) {
                        try std.testing.expectEqual(@as(u8, 0), op.binding_table);
                        source_reads += 1;
                    } else {
                        try std.testing.expectEqual(@as(u8, 1), op.binding_table);
                        destination_writes += 1;
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3), header_components);
    try std.testing.expectEqual(@as(usize, 4), internal_reads);
    try std.testing.expectEqual(@as(usize, 1), source_reads);
    try std.testing.expectEqual(@as(usize, 1), destination_writes);
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
