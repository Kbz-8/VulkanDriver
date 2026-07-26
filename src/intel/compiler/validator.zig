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
    MissingEntryFunction,
    InvalidFunction,
    MissingEntryBlock,
    InvalidBlock,
    WrongParentFunction,
    CrossFunctionBranch,
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
    WrongArgumentCount,
    WrongArgumentType,
    WrongReturnType,
    InvalidEntryTerminator,
};

pub fn validate(program: *const program_ir.Program) Error!void {
    if (program.device_info.generation != .gen9)
        return error.UnsupportedGeneration;
    if (program.stage != .vertex)
        return error.UnsupportedStage;
    if (program.dispatch_width != .simd8 or !program.device_info.supportsDispatch(.simd8))
        return error.UnsupportedDispatchWidth;

    const entry_function_id = program.entry_function orelse return error.MissingEntryFunction;
    const entry_function = program.functions.get(entry_function_id) orelse return error.InvalidFunction;
    const entry_block = entry_function.entry_block orelse return error.MissingEntryBlock;
    const entry_block_data = program.blocks.get(entry_block) orelse return error.InvalidBlock;
    if (entry_block_data.parent_function != entry_function_id)
        return error.WrongParentFunction;

    for (program.functions.entries.items, 0..) |entry, function_index| {
        const function = entry orelse continue;
        const function_id = ids.FunctionId.fromIndex(function_index);

        if (function.return_type) |return_type|
            try validateType(return_type);
        const function_entry = function.entry_block orelse return error.MissingEntryBlock;
        const function_entry_data = program.blocks.get(function_entry) orelse return error.InvalidBlock;
        if (function_entry_data.parent_function != function_id)
            return error.WrongParentFunction;

        for (function.parameters.items) |parameter| {
            if (!program.virtual_registers.isLive(parameter))
                return error.InvalidVirtualRegister;
        }

        for (function.blocks.items) |block_id| {
            const block = program.blocks.get(block_id) orelse return error.InvalidBlock;
            if (block.parent_function != function_id)
                return error.WrongParentFunction;
        }
    }

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
        if (!program.functions.isLive(block.parent_function) or !functionContainsBlock(program, block.parent_function, ids.BlockId.fromIndex(block_index)))
            return error.WrongParentFunction;
        if (block.terminator == null)
            return error.MissingTerminator;

        const block_id = ids.BlockId.fromIndex(block_index);
        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.get(instruction_id) orelse return error.InvalidInstruction;
            if (inst.parent_block != block_id)
                return error.InvalidInstruction;
            try validateInstruction(program, inst.*);
        }

        try validateStructuredControl(program, block.parent_function, block.structured_control);
        try validateTerminator(program, block.parent_function, block.terminator.?);
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
        .call => |op| try validateCall(program, op),
        .send => |op| {
            try validateSpan(program, op.payload);
            if (op.response) |response|
                try validateSpan(program, response);
        },
    }
}

fn validateCall(program: *const program_ir.Program, call: instruction.Call) Error!void {
    const function = program.functions.get(call.function) orelse return error.InvalidFunction;
    if (call.arguments.len != function.parameters.items.len)
        return error.WrongArgumentCount;

    for (call.arguments, function.parameters.items) |argument, parameter_id| {
        try validateSource(program, argument);
        const parameter = program.virtual_registers.get(parameter_id) orelse return error.InvalidVirtualRegister;
        if (argument.type != parameter.element_type)
            return error.WrongArgumentType;
    }

    if (function.return_type) |return_type| {
        const destination = call.destination orelse return error.WrongReturnType;
        try validateDestination(program, destination);
        if (destination.type != return_type)
            return error.WrongReturnType;
    } else if (call.destination != null) {
        return error.WrongReturnType;
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

fn validateTerminator(
    program: *const program_ir.Program,
    function_id: ids.FunctionId,
    terminator: instruction.Terminator,
) Error!void {
    const function = program.functions.get(function_id) orelse return error.InvalidFunction;
    switch (terminator) {
        .jump => |target| try validateBlockTarget(program, function_id, target),
        .conditional_branch => |branch| {
            try validateFlag(program, branch.predicate.flag);
            try validateBlockTarget(program, function_id, branch.true_block);
            try validateBlockTarget(program, function_id, branch.false_block);
        },
        .return_void => if (function.return_type != null)
            return error.WrongReturnType,
        .return_value => |value| {
            const return_type = function.return_type orelse return error.WrongReturnType;
            try validateSource(program, value);
            if (value.type != return_type)
                return error.WrongReturnType;
        },
        .end_thread => if (program.entry_function != function_id)
            return error.InvalidEntryTerminator,
        .@"unreachable" => {},
    }
}

fn validateStructuredControl(
    program: *const program_ir.Program,
    function_id: ids.FunctionId,
    control: instruction.StructuredControl,
) Error!void {
    switch (control) {
        .none => {},
        .selection => |selection| try validateBlockTarget(program, function_id, selection.merge_block),
        .loop => |loop| {
            try validateBlockTarget(program, function_id, loop.merge_block);
            try validateBlockTarget(program, function_id, loop.continue_block);
        },
    }
}

fn validateBlockTarget(program: *const program_ir.Program, function_id: ids.FunctionId, block_id: ids.BlockId) Error!void {
    const block = program.blocks.get(block_id) orelse return error.InvalidBlock;
    if (block.parent_function != function_id)
        return error.CrossFunctionBranch;
}

fn functionContainsBlock(program: *const program_ir.Program, function_id: ids.FunctionId, block_id: ids.BlockId) bool {
    const function = program.functions.get(function_id) orelse return false;
    for (function.blocks.items) |candidate| {
        if (candidate == block_id)
            return true;
    }
    return false;
}
