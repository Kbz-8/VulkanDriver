const ids = @import("id.zig");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const program_ir = @import("program.zig");
const pseudo = @import("pseudo.zig");

pub const Error = error{
    UnsupportedGeneration,
    UnsupportedStage,
    UnsupportedDispatchWidth,
    UnsupportedExecutionSize,
    UnsupportedDataType,
    MissingEntryBlock,
    InvalidBlock,
    MissingTerminator,
    InvalidInstruction,
    InvalidVirtualRegister,
    InvalidVirtualFlag,
    InvalidPhysicalRegister,
    InvalidPhysicalFlag,
    InvalidRegisterSize,
    InvalidRegisterAlignment,
    InvalidLaneCount,
    InvalidRegion,
    InvalidDestination,
    InvalidImmediateType,
    InvalidRegisterSpan,
    EmptyParallelCopy,
    InvalidParallelCopyDestination,
    ParallelCopyTypeMismatch,
    DuplicateParallelCopyDestination,
    PredicatedParallelCopy,
    UnloweredParallelCopy,
    EntryBlockHasParameters,
    DuplicateBlockParameter,
    EdgeArgumentCountMismatch,
    EdgeArgumentKindMismatch,
    EdgeArgumentTypeMismatch,
    UnloweredBlockParameter,
};

pub fn validate(program: *const program_ir.Program) Error!void {
    if (program.device_info.generation != .gen9)
        return Error.UnsupportedGeneration;
    if (program.stage != .vertex)
        return Error.UnsupportedStage;
    if (program.dispatch_width != .simd8 or !program.device_info.supportsDispatch(.simd8))
        return Error.UnsupportedDispatchWidth;

    const entry_block = program.entry_block orelse return Error.MissingEntryBlock;
    if (!program.blocks.isLive(entry_block))
        return Error.InvalidBlock;

    for (program.virtual_registers.entries.items) |entry| {
        const register = entry orelse continue;
        if (register.size_bytes == 0)
            return Error.InvalidRegisterSize;
        if (register.alignment_bytes == 0 or
            (register.alignment_bytes & (register.alignment_bytes - 1)) != 0)
            return Error.InvalidRegisterAlignment;
        if (register.lane_count == 0)
            return Error.InvalidLaneCount;
        try validateType(register.element_type);
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
    switch (inst.execution_size) {
        .simd1, .simd8 => {},
        else => return Error.UnsupportedExecutionSize,
    }

    if (inst.predicate) |predicate|
        try validateFlag(program, predicate.flag);

    switch (inst.operation) {
        .load_input => |op| try validateDestination(program, op.destination),
        .store_output => |op| try validateSource(program, op.source),
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
        .send => |op| {
            try validateSpan(program, op.payload);
            if (op.response) |response|
                try validateSpan(program, response);
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

fn validateType(data_type: operand.DataType) Error!void {
    if (!data_type.isInitialTargetType())
        return Error.UnsupportedDataType;
}

fn validateSource(program: *const program_ir.Program, source: operand.Source) Error!void {
    try validateType(source.type);
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
    try validateType(destination.type);
    if (destination.region.horizontal_stride == 0)
        return Error.InvalidRegion;
    switch (destination.register) {
        .immediate, .null => return Error.InvalidDestination,
        else => try validateRegisterRef(program, destination.register),
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
        .virtual => |id| if (!program.virtual_flags.isLive(id))
            return Error.InvalidVirtualFlag,
        .physical => |physical| if (physical.register != 0 or physical.subregister > 1)
            return Error.InvalidPhysicalFlag,
    }
}

fn validateSpan(program: *const program_ir.Program, span: operand.RegisterSpan) Error!void {
    if (span.register_count == 0)
        return Error.InvalidRegisterSpan;
    switch (span.base) {
        .virtual, .physical_grf => try validateRegisterRef(program, span.base),
        else => return Error.InvalidRegisterSpan,
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
