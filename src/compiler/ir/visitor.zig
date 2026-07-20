const ids = @import("id.zig");
const instruction_ir = @import("instruction.zig");
const module_ir = @import("module.zig");

pub const Visitor = struct {
    context: ?*anyopaque = null,
    visitInterfaceVariable: ?*const fn (?*anyopaque, ids.InterfaceVariableId, *const module_ir.InterfaceVariable) anyerror!void = null,
    visitResource: ?*const fn (?*anyopaque, ids.ResourceId, *const module_ir.Resource) anyerror!void = null,
    visitFunction: ?*const fn (?*anyopaque, ids.FunctionId, *const module_ir.Function) anyerror!void = null,
    visitBlock: ?*const fn (?*anyopaque, ids.BlockId, *const module_ir.Block) anyerror!void = null,
    visitInstruction: ?*const fn (?*anyopaque, ids.InstructionId, *const instruction_ir.Instruction) anyerror!void = null,
    visitTerminator: ?*const fn (?*anyopaque, ids.BlockId, module_ir.Terminator) anyerror!void = null,
    visitValueUse: ?*const fn (?*anyopaque, ids.BlockId, ?ids.InstructionId, ids.ValueId) anyerror!void = null,
};

const UseContext = struct {
    visitor_context: ?*anyopaque,
    callback: *const fn (?*anyopaque, ids.BlockId, ?ids.InstructionId, ids.ValueId) anyerror!void,
    block: ids.BlockId,
    instruction: ?ids.InstructionId,
    failure: ?anyerror = null,
};

pub fn walk(module: *const module_ir.Module, visitor: Visitor) !void {
    for (module.interface_variables.entries.items, 0..) |entry, index| {
        const variable = entry orelse continue;
        if (visitor.visitInterfaceVariable) |callback|
            try callback(visitor.context, ids.InterfaceVariableId.fromIndex(index), &variable);
    }

    for (module.resources.entries.items, 0..) |entry, index| {
        const resource = entry orelse continue;
        if (visitor.visitResource) |callback|
            try callback(visitor.context, ids.ResourceId.fromIndex(index), &resource);
    }

    for (module.functions.entries.items, 0..) |entry, function_index| {
        const function = entry orelse continue;
        const function_id = ids.FunctionId.fromIndex(function_index);

        if (visitor.visitFunction) |callback|
            try callback(visitor.context, function_id, &function);

        for (function.blocks.items) |block_id| {
            const block = module.blocks.get(block_id) orelse continue;

            if (visitor.visitBlock) |callback|
                try callback(visitor.context, block_id, block);

            for (block.instructions.items) |instruction_id| {
                const instruction = module.instructions.get(instruction_id) orelse continue;

                if (visitor.visitInstruction) |callback|
                    try callback(visitor.context, instruction_id, instruction);

                if (visitor.visitValueUse) |callback| {
                    var context: UseContext = .{
                        .visitor_context = visitor.context,
                        .callback = callback,
                        .block = block_id,
                        .instruction = instruction_id,
                    };
                    instruction.operation.visitValueUses(&context, visitUse);

                    if (context.failure) |failure|
                        return failure;
                }
            }

            if (block.terminator) |terminator| {
                if (visitor.visitTerminator) |callback|
                    try callback(visitor.context, block_id, terminator);

                if (visitor.visitValueUse) |callback| {
                    var context: UseContext = .{
                        .visitor_context = visitor.context,
                        .callback = callback,
                        .block = block_id,
                        .instruction = null,
                    };
                    module_ir.visitTerminatorValueUses(terminator, &context, visitUse);

                    if (context.failure) |failure|
                        return failure;
                }
            }
        }
    }
}

fn visitUse(context: *UseContext, value: ids.ValueId) void {
    if (context.failure != null)
        return;

    context.callback(context.visitor_context, context.block, context.instruction, value) catch |err| {
        context.failure = err;
    };
}
