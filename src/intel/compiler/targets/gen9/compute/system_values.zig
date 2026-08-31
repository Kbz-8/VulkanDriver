const std = @import("std");

const operand = @import("../../../ir/operand.zig");
const program_ir = @import("../../../ir/program.zig");
const validator = @import("../../../ir/validator.zig");

pub const Error = error{InvalidProgram};

pub fn run(program: *program_ir.Program) Error!void {
    validator.validate(program) catch return Error.InvalidProgram;
    if (program.properties.system_values_lowered)
        return;

    // Flint dispatch currently accepts only one invocation in one workgroup at
    // base group zero, so every component of GlobalInvocationId is zero.
    if (!std.mem.eql(u32, &program.workgroup_size, &.{ 1, 1, 1 }))
        return;

    for (program.instructions.entries.items) |*entry| {
        const inst = if (entry.*) |*value| value else continue;
        inst.operation = switch (inst.operation) {
            .load_global_invocation_id => |op| .{ .move = .{
                .destination = op.destination,
                .source = zero(),
            } },
            else => inst.operation,
        };
    }

    program.properties.system_values_lowered = true;
    validator.validate(program) catch return Error.InvalidProgram;
}

fn zero() operand.Source {
    return .{
        .register = .{ .immediate = .{ .u32 = 0 } },
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

    try run(&program);

    try std.testing.expect(program.properties.system_values_lowered);
    const move = program.instructions.get(load).?.operation.move;
    try std.testing.expectEqual(@as(u32, 0), move.source.register.immediate.u32);
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

    try run(&program);
    try std.testing.expect(!program.properties.system_values_lowered);
}
