const std = @import("std");

const operand = @import("../../../ir/operand.zig");
const program_ir = @import("../../../ir/program.zig");
const validator = @import("../../../ir/validator.zig");
const dispatch = @import("dispatch.zig");

pub const Error = error{InvalidProgram};

pub fn run(program: *program_ir.Program, storage_surface_count: usize) Error!void {
    validator.validate(program) catch return Error.InvalidProgram;
    if (program.properties.system_values_lowered)
        return;

    if (storage_surface_count > dispatch.max_storage_surfaces)
        return Error.InvalidProgram;

    // Dispatch currently supports one invocation per workgroup. Its global ID
    // equals the group ID delivered in the hardware thread header
    if (!std.mem.eql(u32, &program.workgroup_size, &.{ 1, 1, 1 }))
        return;

    for (program.instructions.entries.items) |*entry| {
        const inst = if (entry.*) |*value| value else continue;
        inst.operation = switch (inst.operation) {
            .load_global_invocation_id => |op| .{ .move = .{
                .destination = op.destination,
                .source = groupId(op.component),
            } },
            .load_num_workgroups => |op| .{ .load_buffer = .{
                .destination = op.destination,
                .buffer = .{ .binding_table = @intCast(storage_surface_count) },
                .byte_offset = .{
                    .register = .{ .immediate = .{ .u32 = dispatch.num_workgroups_offset + @as(u32, op.component) * @sizeOf(u32) } },
                    .type = .u32,
                    .region = operand.Region.broadcast(),
                },
            } },
            else => inst.operation,
        };
    }

    program.properties.system_values_lowered = true;
    validator.validate(program) catch return Error.InvalidProgram;
}

fn groupId(component: u8) operand.Source {
    // Gen9 GPGPU thread payload: group X in r0.1, Y in r0.6, Z in r0.7
    const dwords = [_]u8{ 1, 6, 7 };
    return .{
        .register = .{ .physical_grf = .{ .number = 0, .byte_offset = dwords[component] * @sizeOf(u32) } },
        .type = .u32,
        .region = operand.Region.broadcast(),
    };
}

test "[gen9] system values: lower global invocation ID for single invocation" {
    const Builder = @import("../../../ir/Builder.zig");
    const device = @import("../../../device.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const destination = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const entry = try builder.addBlock("entry");
    const load = try builder.appendInstruction(entry, .simd8, null, .{ .load_global_invocation_id = .{
        .destination = .{ .register = .{ .virtual = destination }, .type = .u32 },
        .component = 2,
    } });
    try builder.setTerminator(entry, .end_thread);
    try builder.setEntryBlock(entry);

    try run(&program, 0);

    try std.testing.expect(program.properties.system_values_lowered);
    const move = program.instructions.get(load).?.operation.move;
    try std.testing.expectEqual(operand.PhysicalGrf{ .number = 0, .byte_offset = 28 }, move.source.register.physical_grf);
}

test "[gen9] system values: preserve IDs for unsupported workgroup sizes" {
    const device = @import("../../../device.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 2, 1, 1 }, device_info, .simd8);
    defer program.deinit();
    const entry = try program.addBlock("entry");
    try program.setTerminator(entry, .end_thread);
    try program.setEntryBlock(entry);

    try run(&program, 0);
    try std.testing.expect(!program.properties.system_values_lowered);
}
