const std = @import("std");
const cfg = @import("../cfg.zig");
const ids = @import("../id.zig");
const module_ir = @import("../module.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidBlock,
    DefinitionDoesNotDominateUse,
};

const DominanceUseContext = struct {
    module: *const module_ir.Module,
    analysis: *const cfg,
    function_id: ids.FunctionId,
    use_block: ids.BlockId,
    use_index: usize,
    valid: bool = true,
};

pub fn validate(module: *const module_ir.Module, function_id: ids.FunctionId) Error!void {
    var analysis = cfg.init(module.backingAllocator(), module, function_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidBlock,
    };
    defer analysis.deinit();

    const function = module.functions.get(function_id).?;
    for (function.blocks.items) |block_id| {
        const block = module.blocks.get(block_id).?;

        for (block.instructions.items, 0..) |instruction_id, instruction_index| {
            const instruction = module.instructions.get(instruction_id).?;
            var context: DominanceUseContext = .{
                .module = module,
                .analysis = &analysis,
                .function_id = function_id,
                .use_block = block_id,
                .use_index = instruction_index,
            };

            instruction.operation.visitValueUses(&context, checkDominanceUse);

            if (!context.valid)
                return error.DefinitionDoesNotDominateUse;
        }

        var context: DominanceUseContext = .{
            .module = module,
            .analysis = &analysis,
            .function_id = function_id,
            .use_block = block_id,
            .use_index = block.instructions.items.len,
        };

        module_ir.visitTerminatorValueUses(block.terminator.?, &context, checkDominanceUse);

        if (!context.valid)
            return error.DefinitionDoesNotDominateUse;
    }
}

fn checkDominanceUse(context: *DominanceUseContext, value_id: ids.ValueId) void {
    if (!context.valid)
        return;

    const value = context.module.values.get(value_id) orelse {
        context.valid = false;
        return;
    };

    context.valid = switch (value.definition) {
        .constant, .undef => true,
        .function_parameter => |definition| definition.function == context.function_id,
        .block_parameter => |definition| context.analysis.dominates(definition.block, context.use_block),
        .instruction => |instruction_id| blk: {
            const definition = context.module.instructions.get(instruction_id) orelse break :blk false;

            if (!context.analysis.dominates(definition.parent_block, context.use_block))
                break :blk false;

            if (definition.parent_block != context.use_block)
                break :blk true;

            const block = context.module.blocks.get(context.use_block) orelse break :blk false;
            for (block.instructions.items, 0..) |candidate, definition_index| {
                if (candidate == instruction_id)
                    break :blk definition_index < context.use_index;
            }

            break :blk false;
        },
    };
}
