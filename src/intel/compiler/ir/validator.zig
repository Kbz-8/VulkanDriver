const ids = @import("id.zig");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const program_ir = @import("program.zig");

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
};

pub fn validate(program: *const program_ir.Program) Error!void {
    if (program.device_info.generation != .gen9)
        return error.UnsupportedGeneration;
    if (program.stage != .vertex)
        return error.UnsupportedStage;
    if (program.dispatch_width != .simd8 or !program.device_info.supportsDispatch(.simd8))
        return error.UnsupportedDispatchWidth;

    const entry_block = program.entry_block orelse return error.MissingEntryBlock;
    if (!program.blocks.isLive(entry_block))
        return error.InvalidBlock;

    for (program.virtual_registers.entries.items) |entry| {
        const register = entry orelse continue;
        if (register.size_bytes == 0)
            return error.InvalidRegisterSize;
        if (register.alignment_bytes == 0 or
            (register.alignment_bytes & (register.alignment_bytes - 1)) != 0)
            return error.InvalidRegisterAlignment;
        if (register.lane_count == 0)
            return error.InvalidLaneCount;
        try validateType(register.element_type);
    }

    for (program.blocks.entries.items, 0..) |entry, block_index| {
        const block = entry orelse continue;
        if (block.terminator == null)
            return error.MissingTerminator;

        const block_id = ids.BlockId.fromIndex(block_index);
        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.get(instruction_id) orelse return error.InvalidInstruction;
            if (inst.parent_block != block_id)
                return error.InvalidInstruction;
            try validateInstruction(program, inst.*);
        }

        try validateStructuredControl(program, block.structured_control);
        try validateTerminator(program, block.terminator.?);
    }
}

fn validateInstruction(program: *const program_ir.Program, inst: instruction.Instruction) Error!void {
    switch (inst.execution_size) {
        .simd1, .simd8 => {},
        else => return error.UnsupportedExecutionSize,
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
    }
}

fn validateType(data_type: operand.DataType) Error!void {
    if (!data_type.isInitialTargetType())
        return error.UnsupportedDataType;
}

fn validateSource(program: *const program_ir.Program, source: operand.Source) Error!void {
    try validateType(source.type);
    if (source.region.width == 0)
        return error.InvalidRegion;
    try validateRegisterRef(program, source.register);

    if (source.register == .immediate) {
        const matches = switch (source.register.immediate) {
            .u32 => source.type == .u32,
            .i32 => source.type == .i32,
            .f32 => source.type == .f32,
        };
        if (!matches)
            return error.InvalidImmediateType;
    }
}

fn validateDestination(program: *const program_ir.Program, destination: operand.Destination) Error!void {
    try validateType(destination.type);
    if (destination.region.horizontal_stride == 0)
        return error.InvalidRegion;
    switch (destination.register) {
        .immediate, .null => return error.InvalidDestination,
        else => try validateRegisterRef(program, destination.register),
    }
}

fn validateRegisterRef(program: *const program_ir.Program, register: operand.RegisterRef) Error!void {
    switch (register) {
        .virtual => |id| if (!program.virtual_registers.isLive(id))
            return error.InvalidVirtualRegister,
        .physical_grf => |physical| {
            if (physical.number >= program.device_info.grf_count or
                physical.byte_offset >= program.device_info.grf_size_bytes)
                return error.InvalidPhysicalRegister;
        },
        .architecture, .immediate, .null => {},
    }
}

fn validateFlag(program: *const program_ir.Program, flag: operand.FlagRef) Error!void {
    switch (flag) {
        .virtual => |id| if (!program.virtual_flags.isLive(id))
            return error.InvalidVirtualFlag,
        .physical => |physical| if (physical.register != 0 or physical.subregister > 1)
            return error.InvalidPhysicalFlag,
    }
}

fn validateSpan(program: *const program_ir.Program, span: operand.RegisterSpan) Error!void {
    if (span.register_count == 0)
        return error.InvalidRegisterSpan;
    switch (span.base) {
        .virtual, .physical_grf => try validateRegisterRef(program, span.base),
        else => return error.InvalidRegisterSpan,
    }
}

fn validateTerminator(program: *const program_ir.Program, terminator: instruction.Terminator) Error!void {
    switch (terminator) {
        .jump => |target| try validateBlockTarget(program, target),
        .conditional_branch => |branch| {
            try validateFlag(program, branch.predicate.flag);
            try validateBlockTarget(program, branch.true_block);
            try validateBlockTarget(program, branch.false_block);
        },
        .end_thread, .@"unreachable" => {},
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
        return error.InvalidBlock;
}
