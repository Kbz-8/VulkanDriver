const ids = @import("id.zig");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const program_ir = @import("program.zig");
const pseudo = @import("pseudo.zig");

pub const Error = error{
    DuplicateBlockParameter,
    DuplicateParallelCopyDestination,
    EdgeArgumentCountMismatch,
    EdgeArgumentKindMismatch,
    EdgeArgumentTypeMismatch,
    EmptyParallelCopy,
    EntryBlockHasParameters,
    InvalidBlock,
    InvalidBufferAccess,
    InvalidBufferReference,
    InvalidDestination,
    InvalidGlobalInvocationId,
    InvalidImmediateType,
    InvalidInstruction,
    InvalidLaneCount,
    InvalidMath,
    InvalidMessage,
    InvalidNumWorkgroups,
    InvalidParallelCopyDestination,
    InvalidPayloadLayout,
    InvalidPhysicalRegister,
    InvalidRegion,
    InvalidRegisterAlignment,
    InvalidRegisterSize,
    InvalidStorageBuffer,
    InvalidVirtualFlag,
    InvalidVirtualRegister,
    InvalidWorkgroupSize,
    MissingEntryBlock,
    MissingTerminator,
    ParallelCopyTypeMismatch,
    PredicatedParallelCopy,
    UnallocatedVirtualFlag,
    UnloweredBlockParameter,
    UnloweredMessage,
    UnloweredParallelCopy,
    UnloweredResource,
    UnloweredSystemValue,
};

pub fn validate(program: *const program_ir.Program) Error!void {
    if (program.workgroup_size[0] == 0 or program.workgroup_size[1] == 0 or program.workgroup_size[2] == 0)
        return Error.InvalidWorkgroupSize;

    const entry_block = program.entry_block orelse return Error.MissingEntryBlock;
    if (!program.blocks.isLive(entry_block))
        return Error.InvalidBlock;

    try validatePayload(program);

    for (program.virtual_registers.entries.items) |entry| {
        const register = entry orelse continue;
        if (register.size_bytes == 0)
            return Error.InvalidRegisterSize;
        if (register.alignment_bytes == 0 or
            (register.alignment_bytes & (register.alignment_bytes - 1)) != 0)
            return Error.InvalidRegisterAlignment;
        if (register.lane_count == 0)
            return Error.InvalidLaneCount;
    }

    for (program.blocks.entries.items, 0..) |entry, block_index| {
        const block = entry orelse continue;
        if (block.terminator == null)
            return Error.MissingTerminator;

        const block_id = ids.BlockId.fromIndex(block_index);
        if (block_id == entry_block and block.parameters.items.len != 0)
            return Error.EntryBlockHasParameters;
        if (program.properties.block_parameters_lowered and block.parameters.items.len != 0)
            return Error.UnloweredBlockParameter;
        for (block.parameters.items, 0..) |parameter, parameter_index|
            try validateBlockParameter(program, block_index, parameter_index, parameter);

        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.get(instruction_id) orelse return Error.InvalidInstruction;
            if (inst.parent_block != block_id)
                return Error.InvalidInstruction;
            try validateInstruction(program, inst.*);
        }

        try validateStructuredControl(program, block.structured_control);
        try validateTerminator(program, block.terminator.?);
    }
}

fn validatePayload(program: *const program_ir.Program) Error!void {
    if (program.program_data.payload_grf_count > program.device_info.grf_count)
        return Error.InvalidPayloadLayout;

    if (program.payload.header_grf) |header| {
        try validateRegisterRef(program, .{ .physical_grf = header });
        if (header.byte_offset != 0)
            return Error.InvalidPayloadLayout;
    }
}

fn validateBlockParameter(program: *const program_ir.Program, block_index: usize, parameter_index: usize, parameter: pseudo.BlockParameter) Error!void {
    switch (parameter) {
        .register => |register_id| if (!program.virtual_registers.isLive(register_id))
            return Error.InvalidVirtualRegister,
        .flag => |flag_id| if (!program.virtual_flags.isLive(flag_id))
            return Error.InvalidVirtualFlag,
    }

    for (program.blocks.entries.items, 0..) |entry, candidate_block_index| {
        const block = entry orelse continue;
        if (candidate_block_index > block_index)
            break;
        const limit = if (candidate_block_index == block_index) parameter_index else block.parameters.items.len;
        for (block.parameters.items[0..limit]) |candidate| {
            if (blockParametersEqual(parameter, candidate))
                return Error.DuplicateBlockParameter;
        }
    }
}

fn blockParametersEqual(a: pseudo.BlockParameter, b: pseudo.BlockParameter) bool {
    return switch (a) {
        .register => |register_id| b == .register and b.register == register_id,
        .flag => |flag_id| b == .flag and b.flag == flag_id,
    };
}

fn validateInstruction(program: *const program_ir.Program, inst: instruction.Instruction) Error!void {
    if (inst.predicate) |predicate|
        try validateFlag(program, predicate.flag);

    switch (inst.operation) {
        .load_global_invocation_id => |op| {
            if (program.properties.system_values_lowered)
                return Error.UnloweredSystemValue;
            try validateDestination(program, op.destination);
            if (op.component >= 3 or op.destination.type != .u32)
                return Error.InvalidGlobalInvocationId;
        },
        .load_num_workgroups => |op| {
            if (program.properties.system_values_lowered)
                return Error.UnloweredSystemValue;
            try validateDestination(program, op.destination);
            if (op.component >= 3 or op.destination.type != .u32)
                return Error.InvalidNumWorkgroups;
        },
        .load_buffer => |op| {
            if (program.properties.messages_lowered)
                return Error.UnloweredMessage;
            try validateBufferReference(program, op.buffer);
            try validateDestination(program, op.destination);
            try validateBufferOffset(program, op.byte_offset);
            if (!op.destination.type.isInitialTargetType())
                return Error.InvalidBufferAccess;
        },
        .store_buffer => |op| {
            if (program.properties.messages_lowered)
                return Error.UnloweredMessage;
            try validateBufferReference(program, op.buffer);
            try validateBufferOffset(program, op.byte_offset);
            try validateSource(program, op.source);
            if (!op.source.type.isInitialTargetType())
                return Error.InvalidBufferAccess;
        },
        .array_length => |op| {
            try validateBufferReference(program, op.buffer);
            try validateDestination(program, op.destination);
            try validateBufferOffset(program, op.byte_offset);
            if (op.destination.type != .u32 or op.stride == 0)
                return Error.InvalidBufferAccess;
        },
        .surface_read => |op| {
            try validateDestination(program, op.destination);
            try validateBufferOffset(program, op.address);
            if (!op.destination.type.isInitialTargetType())
                return Error.InvalidBufferAccess;
        },
        .surface_write => |op| {
            try validateBufferOffset(program, op.address);
            try validateSource(program, op.data);
            if (!op.data.type.isInitialTargetType())
                return Error.InvalidBufferAccess;
        },
        .surface_message => |op| {
            try validateRegisterSpan(program, op.payload);
            if (!op.data_type.isInitialTargetType())
                return Error.InvalidMessage;
            switch (op.kind) {
                .read => {
                    if (op.payload.register_count != 1 or op.response == null)
                        return Error.InvalidMessage;
                    try validateRegisterSpan(program, op.response.?);
                    if (op.response.?.register_count != 1)
                        return Error.InvalidMessage;
                },
                .write => if (op.payload.register_count != 2 or op.response != null)
                    return Error.InvalidMessage,
            }
        },
        .move => |op| {
            try validateDestination(program, op.destination);
            try validateSource(program, op.source);
        },
        .binary => |op| {
            try validateDestination(program, op.destination);
            try validateSource(program, op.lhs);
            try validateSource(program, op.rhs);
        },
        .compare => |op| {
            try validateFlag(program, op.destination);
            try validateSource(program, op.lhs);
            try validateSource(program, op.rhs);
        },
        .math => |op| {
            try validateDestination(program, op.destination);
            try validateSource(program, op.lhs);
            try validateSource(program, op.rhs);

            switch (op.opcode) {
                .integer_quotient => {
                    if (inst.execution_size != .simd8)
                        return Error.InvalidMath;
                    if (op.destination.type != .u32 and op.destination.type != .i32)
                        return Error.InvalidMath;
                    if (op.lhs.type != op.destination.type or op.rhs.type != op.destination.type)
                        return Error.InvalidMath;
                },
            }
        },

        .parallel_copy => |op| {
            if (program.properties.parallel_copies_lowered)
                return Error.UnloweredParallelCopy;
            if (inst.predicate != null)
                return Error.PredicatedParallelCopy;
            try validateParallelCopy(program, op);
        },
    }
}

fn validateBufferReference(program: *const program_ir.Program, reference: instruction.BufferReference) Error!void {
    switch (reference) {
        .logical => |buffer| {
            if (program.properties.resources_lowered)
                return Error.UnloweredResource;
            if (!program.storage_buffers.isLive(buffer))
                return Error.InvalidStorageBuffer;
        },
        .binding_table => if (!program.properties.resources_lowered)
            return Error.InvalidBufferReference,
    }
}

fn validateBufferOffset(program: *const program_ir.Program, source: operand.Source) Error!void {
    try validateSource(program, source);
    if (source.type != .u32)
        return Error.InvalidBufferAccess;
}

fn validateParallelCopy(program: *const program_ir.Program, copy: pseudo.ParallelCopy) Error!void {
    if (copy.register_copies.len == 0 and copy.flag_copies.len == 0)
        return Error.EmptyParallelCopy;

    for (copy.register_copies, 0..) |item, index| {
        try validateDestination(program, item.destination);
        try validateSource(program, item.source);

        if (item.destination.type != item.source.type)
            return Error.ParallelCopyTypeMismatch;
        if (item.destination.region.byte_offset != 0 or item.destination.region.horizontal_stride != 1)
            return Error.InvalidParallelCopyDestination;

        const destination_id = switch (item.destination.register) {
            .virtual => |register_id| register_id,
            else => return Error.InvalidParallelCopyDestination,
        };
        const destination_register = program.virtual_registers.get(destination_id) orelse
            return Error.InvalidVirtualRegister;
        if (destination_register.element_type != item.destination.type)
            return Error.ParallelCopyTypeMismatch;

        switch (item.source.register) {
            .virtual => |source_id| {
                const source_register = program.virtual_registers.get(source_id) orelse
                    return Error.InvalidVirtualRegister;
                if (source_register.element_type != item.source.type)
                    return Error.ParallelCopyTypeMismatch;
                if (!isBroadcast(item.source.region) and
                    (source_register.size_bytes != destination_register.size_bytes or
                        source_register.lane_count != destination_register.lane_count))
                    return Error.ParallelCopyTypeMismatch;
            },
            .null => return Error.ParallelCopyTypeMismatch,
            else => {},
        }

        for (copy.register_copies[0..index]) |previous| {
            const previous_id = switch (previous.destination.register) {
                .virtual => |register_id| register_id,
                else => unreachable,
            };
            if (previous_id == destination_id)
                return Error.DuplicateParallelCopyDestination;
        }
    }

    for (copy.flag_copies, 0..) |item, index| {
        if (!program.virtual_flags.isLive(item.destination))
            return Error.InvalidVirtualFlag;
        switch (item.source) {
            .constant => {},
            .dynamic => |predicate| try validateFlag(program, predicate.flag),
        }

        for (copy.flag_copies[0..index]) |previous| {
            if (previous.destination == item.destination)
                return Error.DuplicateParallelCopyDestination;
        }
    }
}

fn isBroadcast(region: operand.Region) bool {
    return region.vertical_stride == 0 and region.width == 1 and region.horizontal_stride == 0;
}

fn validateSource(program: *const program_ir.Program, source: operand.Source) Error!void {
    if (source.region.width == 0)
        return Error.InvalidRegion;
    try validateRegisterRef(program, source.register);

    if (source.register == .immediate) {
        const matches = switch (source.register.immediate) {
            .u32 => source.type == .u32,
            .i32 => source.type == .i32,
            .f32 => source.type == .f32,
        };
        if (!matches)
            return Error.InvalidImmediateType;
    }
}

fn validateDestination(program: *const program_ir.Program, destination: operand.Destination) Error!void {
    if (destination.region.horizontal_stride == 0)
        return Error.InvalidRegion;
    switch (destination.register) {
        .immediate, .null => return Error.InvalidDestination,
        else => try validateRegisterRef(program, destination.register),
    }
}

fn validateRegisterSpan(program: *const program_ir.Program, span: operand.RegisterSpan) Error!void {
    if (span.register_count == 0)
        return Error.InvalidMessage;
    switch (span.base) {
        .virtual, .physical_grf => try validateRegisterRef(program, span.base),
        else => return Error.InvalidMessage,
    }
}

fn validateRegisterRef(program: *const program_ir.Program, register: operand.RegisterRef) Error!void {
    switch (register) {
        .virtual => |id| if (!program.virtual_registers.isLive(id))
            return Error.InvalidVirtualRegister,
        .physical_grf => |physical| {
            if (physical.number >= program.device_info.grf_count or
                physical.byte_offset >= program.device_info.grf_size_bytes)
                return Error.InvalidPhysicalRegister;
        },
        .architecture, .immediate, .null => {},
    }
}

fn validateFlag(program: *const program_ir.Program, flag: operand.FlagRef) Error!void {
    switch (flag) {
        .virtual => |id| {
            if (program.properties.flags_allocated)
                return Error.UnallocatedVirtualFlag;
            if (!program.virtual_flags.isLive(id))
                return Error.InvalidVirtualFlag;
        },
        .physical => {},
    }
}

fn validateTerminator(program: *const program_ir.Program, terminator: instruction.Terminator) Error!void {
    switch (terminator) {
        .jump => |edge| try validateEdge(program, edge),
        .conditional_branch => |branch| {
            try validateFlag(program, branch.predicate.flag);
            try validateEdge(program, branch.true_edge);
            try validateEdge(program, branch.false_edge);
        },
        .end_thread, .@"unreachable" => {},
    }
}

fn validateEdge(program: *const program_ir.Program, edge: instruction.Edge) Error!void {
    try validateBlockTarget(program, edge.target);
    const target = program.blocks.get(edge.target).?;

    if (program.properties.block_parameters_lowered and edge.arguments.len != 0)
        return Error.UnloweredBlockParameter;
    if (edge.arguments.len != target.parameters.items.len)
        return Error.EdgeArgumentCountMismatch;

    for (target.parameters.items, edge.arguments) |parameter, argument| {
        switch (parameter) {
            .register => |destination_id| switch (argument) {
                .source => |source| try validateRegisterEdgeArgument(program, destination_id, source),
                .predicate => return Error.EdgeArgumentKindMismatch,
            },
            .flag => switch (argument) {
                .source => return Error.EdgeArgumentKindMismatch,
                .predicate => |predicate_value| switch (predicate_value) {
                    .constant => {},
                    .dynamic => |predicate| try validateFlag(program, predicate.flag),
                },
            },
        }
    }
}

fn validateRegisterEdgeArgument(program: *const program_ir.Program, destination_id: ids.VirtualRegisterId, source: operand.Source) Error!void {
    const destination = program.virtual_registers.get(destination_id) orelse
        return Error.InvalidVirtualRegister;
    try validateSource(program, source);
    if (source.type != destination.element_type)
        return Error.EdgeArgumentTypeMismatch;

    switch (source.register) {
        .virtual => |source_id| {
            const source_register = program.virtual_registers.get(source_id) orelse
                return Error.InvalidVirtualRegister;
            if (source_register.element_type != source.type)
                return Error.EdgeArgumentTypeMismatch;
            if (!isBroadcast(source.region) and
                (source_register.size_bytes != destination.size_bytes or
                    source_register.lane_count != destination.lane_count))
                return Error.EdgeArgumentTypeMismatch;
        },
        .null => return Error.EdgeArgumentTypeMismatch,
        else => {},
    }
}

fn validateStructuredControl(program: *const program_ir.Program, control: instruction.StructuredControl) Error!void {
    switch (control) {
        .none => {},
        .selection => |selection| try validateBlockTarget(program, selection.merge_block),
        .loop => |loop| {
            try validateBlockTarget(program, loop.merge_block);
            try validateBlockTarget(program, loop.continue_block);
        },
    }
}

fn validateBlockTarget(program: *const program_ir.Program, block_id: ids.BlockId) Error!void {
    if (!program.blocks.isLive(block_id))
        return Error.InvalidBlock;
}

test "[ir] validator checks compute system values and resources" {
    const std = @import("std");
    const Builder = @import("Builder.zig");
    const device = @import("../device.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const register = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const buffer = try builder.addStorageBuffer(.{ .set = 0, .binding = 0 });
    const entry = try builder.addBlock("entry");
    const system_value_id = try builder.appendInstruction(entry, .simd8, null, .{
        .load_global_invocation_id = .{
            .destination = .{ .register = .{ .virtual = register }, .type = .u32 },
            .component = 0,
        },
    });
    const buffer_load_id = try builder.appendInstruction(entry, .simd8, null, .{
        .load_buffer = .{
            .destination = .{ .register = .{ .virtual = register }, .type = .u32 },
            .buffer = .{ .logical = buffer },
            .byte_offset = .{
                .register = .{ .immediate = .{ .u32 = 0 } },
                .type = .u32,
                .region = operand.Region.broadcast(),
            },
        },
    });
    try builder.setTerminator(entry, .end_thread);
    try validate(&program);

    program.instructions.getMut(system_value_id).?.operation.load_global_invocation_id.component = 3;
    try std.testing.expectError(Error.InvalidGlobalInvocationId, validate(&program));
    program.instructions.getMut(system_value_id).?.operation.load_global_invocation_id.component = 0;

    program.properties.system_values_lowered = true;
    try std.testing.expectError(Error.UnloweredSystemValue, validate(&program));
    program.properties.system_values_lowered = false;

    program.instructions.getMut(system_value_id).?.operation = .{ .load_num_workgroups = .{
        .destination = .{ .register = .{ .virtual = register }, .type = .u32 },
        .component = 2,
    } };
    try validate(&program);
    program.instructions.getMut(system_value_id).?.operation.load_num_workgroups.component = 3;
    try std.testing.expectError(Error.InvalidNumWorkgroups, validate(&program));
    program.instructions.getMut(system_value_id).?.operation.load_num_workgroups.component = 0;
    program.instructions.getMut(system_value_id).?.operation.load_num_workgroups.destination.type = .i32;
    try std.testing.expectError(Error.InvalidNumWorkgroups, validate(&program));
    program.instructions.getMut(system_value_id).?.operation.load_num_workgroups.destination.type = .u32;
    program.properties.system_values_lowered = true;
    try std.testing.expectError(Error.UnloweredSystemValue, validate(&program));
    program.properties.system_values_lowered = false;

    program.instructions.getMut(buffer_load_id).?.operation.load_buffer.buffer = .{ .logical = ids.StorageBufferId.fromIndex(99) };
    try std.testing.expectError(Error.InvalidStorageBuffer, validate(&program));
    program.instructions.getMut(buffer_load_id).?.operation.load_buffer.buffer = .{ .logical = buffer };

    program.properties.resources_lowered = true;
    try std.testing.expectError(Error.UnloweredResource, validate(&program));
    program.instructions.getMut(buffer_load_id).?.operation.load_buffer.buffer = .{ .binding_table = 0 };
    try validate(&program);
}
