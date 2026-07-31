const std = @import("std");
const Builder = @import("../ir/Builder.zig");
const ids = @import("../ir/id.zig");
const instruction = @import("../ir/instruction.zig");
const operand = @import("../ir/operand.zig");
const program_ir = @import("../ir/program.zig");
const pseudo = @import("../ir/pseudo.zig");
const validator = @import("../ir/validator.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidProgram,
};

pub fn run(allocator: std.mem.Allocator, program: *program_ir.Program) Error!void {
    validator.validate(program) catch return error.InvalidProgram;
    if (program.properties.block_parameters_lowered)
        return;

    var builder = Builder.init(program);
    var original_blocks: std.ArrayList(ids.BlockId) = .empty;
    defer original_blocks.deinit(allocator);

    for (program.blocks.entries.items, 0..) |entry, index| {
        _ = entry orelse continue;
        try original_blocks.append(allocator, ids.BlockId.fromIndex(index));
    }

    var emitted_parallel_copy = false;
    for (original_blocks.items) |block_id| {
        const block = program.blocks.get(block_id) orelse return error.InvalidProgram;
        const terminator = block.terminator orelse return error.InvalidProgram;
        const rewritten: instruction.Terminator = switch (terminator) {
            .jump => |edge| .{ .jump = try rewriteEdge(
                allocator,
                &builder,
                edge,
                &emitted_parallel_copy,
            ) },
            .conditional_branch => |branch| .{ .conditional_branch = .{
                .predicate = branch.predicate,
                .true_edge = try rewriteEdge(
                    allocator,
                    &builder,
                    branch.true_edge,
                    &emitted_parallel_copy,
                ),
                .false_edge = try rewriteEdge(
                    allocator,
                    &builder,
                    branch.false_edge,
                    &emitted_parallel_copy,
                ),
            } },
            else => terminator,
        };
        builder.replaceTerminator(block_id, rewritten) catch |err| return mapBuilderError(err);
    }

    for (original_blocks.items) |block_id|
        builder.clearBlockParameters(block_id) catch |err| return mapBuilderError(err);

    program.properties.block_parameters_lowered = true;
    if (emitted_parallel_copy)
        program.properties.parallel_copies_lowered = false;
}

fn rewriteEdge(
    allocator: std.mem.Allocator,
    builder: *Builder,
    edge: instruction.Edge,
    emitted_parallel_copy: *bool,
) Error!instruction.Edge {
    if (edge.arguments.len == 0)
        return .{ .target = edge.target, .arguments = &.{} };

    const target = builder.program.blocks.get(edge.target) orelse return error.InvalidProgram;
    if (target.parameters.items.len != edge.arguments.len)
        return error.InvalidProgram;

    var register_copies: std.ArrayList(pseudo.RegisterCopy) = .empty;
    defer register_copies.deinit(allocator);
    var flag_copies: std.ArrayList(pseudo.FlagCopy) = .empty;
    defer flag_copies.deinit(allocator);

    for (target.parameters.items, edge.arguments) |parameter, argument| {
        switch (parameter) {
            .register => |destination_id| {
                const source = switch (argument) {
                    .source => |value| value,
                    .predicate => return error.InvalidProgram,
                };
                const destination = builder.program.virtual_registers.get(destination_id) orelse
                    return error.InvalidProgram;
                try register_copies.append(allocator, .{
                    .destination = .{
                        .register = .{ .virtual = destination_id },
                        .type = destination.element_type,
                    },
                    .source = source,
                });
            },
            .flag => |destination_id| {
                const source = switch (argument) {
                    .source => return error.InvalidProgram,
                    .predicate => |value| value,
                };
                try flag_copies.append(allocator, .{
                    .destination = destination_id,
                    .source = source,
                });
            },
        }
    }

    const edge_block = builder.addBlock(null) catch |err| return mapBuilderError(err);
    _ = builder.appendInstruction(edge_block, executionSize(builder.program.dispatch_width), null, .{
        .parallel_copy = .{
            .register_copies = register_copies.items,
            .flag_copies = flag_copies.items,
        },
    }) catch |err| return mapBuilderError(err);
    builder.setTerminator(edge_block, .{ .jump = .{
        .target = edge.target,
        .arguments = &.{},
    } }) catch |err| return mapBuilderError(err);

    emitted_parallel_copy.* = true;
    return .{ .target = edge_block, .arguments = &.{} };
}

fn executionSize(dispatch_width: @import("../device.zig").DispatchWidth) @import("../device.zig").ExecutionSize {
    return @enumFromInt(@intFromEnum(dispatch_width));
}

fn mapBuilderError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidProgram,
    };
}

test "[ir] block arguments: lower register and flag parameters" {
    const device = @import("../device.zig");
    const printer = @import("../ir/printer.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const source_register = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const destination_register = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const source_flag = try builder.addVirtualFlag(.{});
    const destination_flag = try builder.addVirtualFlag(.{});
    const entry = try builder.addBlock("entry");
    const merge = try builder.addBlock("merge");

    try builder.addBlockParameter(merge, .{ .register = destination_register });
    try builder.addBlockParameter(merge, .{ .flag = destination_flag });
    try builder.setTerminator(entry, .{ .jump = try builder.edge(merge, &.{
        .{ .source = .{
            .register = .{ .virtual = source_register },
            .type = .u32,
            .region = operand.Region.contiguous(.simd8),
        } },
        .{ .predicate = .{ .dynamic = .{ .flag = .{ .virtual = source_flag } } } },
    }) });
    try builder.setTerminator(merge, .end_thread);

    try validator.validate(&program);
    const before = try printer.allocPrint(std.testing.allocator, &program);
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, ".merge(%v1, %f1):") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "jump .merge(%v0:u32, (+%f0))") != null);

    try run(std.testing.allocator, &program);
    try validator.validate(&program);

    try std.testing.expect(program.properties.block_parameters_lowered);
    try std.testing.expect(!program.properties.parallel_copies_lowered);
    try std.testing.expectEqual(@as(usize, 0), program.blocks.get(merge).?.parameters.items.len);

    const edge_block_id = program.blocks.get(entry).?.terminator.?.jump.target;
    try std.testing.expect(edge_block_id != merge);
    try std.testing.expectEqual(@as(usize, 0), program.blocks.get(entry).?.terminator.?.jump.arguments.len);

    const edge_block = program.blocks.get(edge_block_id).?;
    try std.testing.expectEqual(@as(usize, 1), edge_block.instructions.items.len);
    const copy = program.instructions.get(edge_block.instructions.items[0]).?.operation.parallel_copy;
    try std.testing.expectEqual(@as(usize, 1), copy.register_copies.len);
    try std.testing.expectEqual(destination_register, copy.register_copies[0].destination.register.virtual);
    try std.testing.expectEqual(source_register, copy.register_copies[0].source.register.virtual);
    try std.testing.expectEqual(@as(usize, 1), copy.flag_copies.len);
    try std.testing.expectEqual(destination_flag, copy.flag_copies[0].destination);
    try std.testing.expectEqual(source_flag, copy.flag_copies[0].source.dynamic.flag.virtual);
    try std.testing.expectEqual(merge, edge_block.terminator.?.jump.target);
}

test "[ir] block arguments: split same-target conditional edges" {
    const device = @import("../device.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const destination = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const condition = try builder.addVirtualFlag(.{});
    const entry = try builder.addBlock("entry");
    const merge = try builder.addBlock("merge");
    try builder.addBlockParameter(merge, .{ .register = destination });

    const one: pseudo.EdgeArgument = .{ .source = .{
        .register = .{ .immediate = .{ .u32 = 1 } },
        .type = .u32,
        .region = operand.Region.broadcast(),
    } };
    const two: pseudo.EdgeArgument = .{ .source = .{
        .register = .{ .immediate = .{ .u32 = 2 } },
        .type = .u32,
        .region = operand.Region.broadcast(),
    } };
    try builder.setTerminator(entry, .{ .conditional_branch = .{
        .predicate = .{ .flag = .{ .virtual = condition } },
        .true_edge = try builder.edge(merge, &.{one}),
        .false_edge = try builder.edge(merge, &.{two}),
    } });
    try builder.setTerminator(merge, .end_thread);

    try run(std.testing.allocator, &program);
    try validator.validate(&program);

    const branch = program.blocks.get(entry).?.terminator.?.conditional_branch;
    try std.testing.expect(branch.true_edge.target != branch.false_edge.target);
    try std.testing.expect(branch.true_edge.target != merge);
    try std.testing.expect(branch.false_edge.target != merge);

    const true_block = program.blocks.get(branch.true_edge.target).?;
    const false_block = program.blocks.get(branch.false_edge.target).?;
    const true_copy = program.instructions.get(true_block.instructions.items[0]).?.operation.parallel_copy;
    const false_copy = program.instructions.get(false_block.instructions.items[0]).?.operation.parallel_copy;
    try std.testing.expectEqual(@as(u32, 1), true_copy.register_copies[0].source.register.immediate.u32);
    try std.testing.expectEqual(@as(u32, 2), false_copy.register_copies[0].source.register.immediate.u32);
}
