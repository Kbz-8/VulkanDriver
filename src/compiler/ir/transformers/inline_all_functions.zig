const std = @import("std");
const Builder = @import("../Builder.zig");
const Rewriter = @import("../Rewriter.zig");
const ids = @import("../id.zig");
const instruction_ir = @import("../instruction.zig");
const module_ir = @import("../module.zig");
const transformer_manager = @import("../transformer_manager.zig");

pub const Error = Rewriter.Error || error{
    InvalidModule,
    RecursiveCall,
    UnsupportedEntryBlockParameters,
};

const VisitState = enum {
    unvisited,
    visiting,
    complete,
};

const CallGraph = struct {
    module: *const module_ir.Module,
    states: []VisitState,
    postorder: *std.ArrayList(ids.FunctionId),
    allocator: std.mem.Allocator,

    fn visit(self: *CallGraph, function_id: ids.FunctionId) Error!void {
        if (function_id.index() >= self.states.len)
            return Error.InvalidModule;

        switch (self.states[function_id.index()]) {
            .visiting => return Error.RecursiveCall,
            .complete => return,
            .unvisited => {},
        }
        self.states[function_id.index()] = .visiting;

        const function = self.module.functions.get(function_id) orelse return Error.InvalidModule;
        for (function.blocks.items) |block_id| {
            const block = self.module.blocks.get(block_id) orelse return Error.InvalidModule;
            for (block.instructions.items) |instruction_id| {
                const inst = self.module.instructions.get(instruction_id) orelse return Error.InvalidModule;
                switch (inst.operation) {
                    .call => |call| try self.visit(call.function),
                    else => {},
                }
            }
        }

        self.states[function_id.index()] = .complete;
        try self.postorder.append(self.allocator, function_id);
    }
};

pub const transformer: transformer_manager.Transformer = .{
    .name = "inline-all-functions",
    .produced = .{ .no_function_calls = true },
    .invalidated = .{ .structured_control_flow = true },
    .run = transform,
};

fn transform(module: *module_ir.Module, context: *transformer_manager.Context) !bool {
    const scratch_allocator = context.allocator;
    const entry_point = module.entry_point orelse return Error.InvalidModule;
    if (!module.functions.isLive(entry_point))
        return Error.InvalidModule;

    var changed = try removeUnreachableBlocks(module, scratch_allocator);

    const states = try scratch_allocator.alloc(VisitState, module.functions.entries.items.len);
    defer scratch_allocator.free(states);
    @memset(states, .unvisited);

    var postorder: std.ArrayList(ids.FunctionId) = .empty;
    defer postorder.deinit(scratch_allocator);

    var call_graph: CallGraph = .{
        .module = module,
        .states = states,
        .postorder = &postorder,
        .allocator = scratch_allocator,
    };
    try call_graph.visit(entry_point);

    for (postorder.items) |function_id|
        changed = (try inlineCallsInFunction(module, scratch_allocator, function_id)) or changed;

    changed = removeNonEntryFunctions(module, entry_point) or changed;

    for (module.instructions.entries.items) |entry| {
        const inst = entry orelse continue;
        if (inst.operation == .call)
            return Error.InvalidModule;
    }

    return changed;
}

fn inlineCallsInFunction(module: *module_ir.Module, scratch_allocator: std.mem.Allocator, function_id: ids.FunctionId) Error!bool {
    const function = module.functions.get(function_id) orelse return Error.InvalidModule;
    var calls: std.ArrayList(ids.InstructionId) = .empty;
    defer calls.deinit(scratch_allocator);

    for (function.blocks.items) |block_id| {
        const block = module.blocks.get(block_id) orelse return Error.InvalidModule;
        for (block.instructions.items) |instruction_id| {
            const inst = module.instructions.get(instruction_id) orelse return Error.InvalidModule;
            if (inst.operation == .call)
                try calls.append(scratch_allocator, instruction_id);
        }
    }

    for (calls.items) |call_id|
        try inlineCall(module, scratch_allocator, function_id, call_id);

    return calls.items.len != 0;
}

fn inlineCall(module: *module_ir.Module, scratch_allocator: std.mem.Allocator, caller_id: ids.FunctionId, call_id: ids.InstructionId) Error!void {
    const call_inst = module.instructions.get(call_id) orelse return Error.InvalidModule;
    if (call_inst.operation != .call)
        return Error.InvalidModule;

    const call = call_inst.operation.call;
    if (call.function == caller_id)
        return Error.RecursiveCall;

    const callee = module.functions.get(call.function) orelse return Error.InvalidModule;
    const callee_entry = module.blocks.get(callee.entry_block orelse return Error.InvalidModule) orelse return Error.InvalidModule;
    if (callee_entry.parameters.items.len != 0)
        return Error.UnsupportedEntryBlockParameters;

    const caller_block_id = call_inst.parent_block;
    const caller_block = module.blocks.get(caller_block_id) orelse return Error.InvalidModule;
    if (caller_block.parent_function != caller_id)
        return Error.InvalidModule;

    var call_index: ?usize = null;
    for (caller_block.instructions.items, 0..) |instruction_id, index| {
        if (instruction_id == call_id) {
            call_index = index;
            break;
        }
    }
    const index = call_index orelse return Error.InvalidModule;

    const arguments = try scratch_allocator.dupe(ids.ValueId, call.arguments);
    defer scratch_allocator.free(arguments);

    const suffix = try scratch_allocator.dupe(ids.InstructionId, caller_block.instructions.items[index + 1 ..]);
    defer scratch_allocator.free(suffix);

    const old_terminator = caller_block.terminator orelse return Error.InvalidModule;
    const old_structured_control = caller_block.structured_control;
    const call_result = call_inst.result;
    const result_type = if (call_result) |result_id|
        (module.values.get(result_id) orelse return Error.InvalidModule).type
    else
        null;
    const result_name = if (call_result) |result_id|
        (module.values.get(result_id) orelse return Error.InvalidModule).name
    else
        null;

    var builder = Builder.init(module);
    const continuation_id = try builder.addBlock(caller_id, null);
    const continuation_result = if (result_type) |ty|
        try builder.addBlockParameter(continuation_id, ty, result_name)
    else
        null;

    {
        const continuation = module.blocks.getMut(continuation_id) orelse return Error.InvalidModule;
        try continuation.instructions.appendSlice(module.allocator(), suffix);
        continuation.terminator = old_terminator;
        continuation.structured_control = switch (old_structured_control) {
            .loop => .none,
            else => old_structured_control,
        };
    }
    for (suffix) |instruction_id| {
        const moved = module.instructions.getMut(instruction_id) orelse return Error.InvalidModule;
        moved.parent_block = continuation_id;
    }

    {
        const mutable_caller_block = module.blocks.getMut(caller_block_id) orelse return Error.InvalidModule;
        mutable_caller_block.instructions.shrinkRetainingCapacity(index);
        mutable_caller_block.terminator = null;
        mutable_caller_block.structured_control = switch (old_structured_control) {
            .loop => old_structured_control,
            else => .none,
        };
    }

    if (call_result) |old_result| {
        const replacement = continuation_result orelse return Error.InvalidModule;
        var rewriter = Rewriter.init(module);
        _ = try rewriter.replaceAllUses(old_result, replacement);
    }

    const cloned_entry = try cloneCallee(
        module,
        scratch_allocator,
        caller_id,
        call.function,
        arguments,
        continuation_id,
        continuation_result != null,
    );

    const cloned_entry_block = module.blocks.get(cloned_entry) orelse return Error.InvalidModule;
    if (cloned_entry_block.parameters.items.len != 0)
        return Error.UnsupportedEntryBlockParameters;

    const branch_arguments = try module.allocator().alloc(ids.ValueId, 0);
    const mutable_caller_block = module.blocks.getMut(caller_block_id) orelse return Error.InvalidModule;
    mutable_caller_block.terminator = .{ .branch = .{
        .target = cloned_entry,
        .arguments = branch_arguments,
    } };

    if (call_result) |result_id|
        _ = module.values.remove(result_id);
    _ = module.instructions.remove(call_id);
}

fn cloneCallee(
    module: *module_ir.Module,
    scratch_allocator: std.mem.Allocator,
    caller_id: ids.FunctionId,
    callee_id: ids.FunctionId,
    arguments: []const ids.ValueId,
    continuation_id: ids.BlockId,
    returns_value: bool,
) Error!ids.BlockId {
    const callee = module.functions.get(callee_id) orelse return Error.InvalidModule;
    if (callee.parameters.items.len != arguments.len)
        return Error.InvalidModule;

    const callee_blocks = try scratch_allocator.dupe(ids.BlockId, callee.blocks.items);
    defer scratch_allocator.free(callee_blocks);
    const callee_entry = callee.entry_block orelse return Error.InvalidModule;

    const block_map = try scratch_allocator.alloc(?ids.BlockId, module.blocks.entries.items.len);
    defer scratch_allocator.free(block_map);
    @memset(block_map, null);

    const value_map = try scratch_allocator.alloc(?ids.ValueId, module.values.entries.items.len);
    defer scratch_allocator.free(value_map);
    @memset(value_map, null);

    const instruction_map = try scratch_allocator.alloc(?ids.InstructionId, module.instructions.entries.items.len);
    defer scratch_allocator.free(instruction_map);
    @memset(instruction_map, null);

    for (callee.parameters.items, arguments) |parameter, argument| {
        if (parameter.index() >= value_map.len)
            return Error.InvalidModule;
        value_map[parameter.index()] = argument;
    }

    var builder = Builder.init(module);
    for (callee_blocks) |old_block_id| {
        const new_block_id = try builder.addBlock(caller_id, null);
        if (old_block_id.index() >= block_map.len)
            return Error.InvalidModule;
        block_map[old_block_id.index()] = new_block_id;
    }

    for (callee_blocks) |old_block_id| {
        const old_block = module.blocks.get(old_block_id) orelse return Error.InvalidModule;
        const new_block_id = mappedBlock(block_map, old_block_id) orelse return Error.InvalidModule;
        for (old_block.parameters.items) |old_parameter| {
            const old_value = module.values.get(old_parameter) orelse return Error.InvalidModule;
            const new_parameter = try builder.addBlockParameter(new_block_id, old_value.type, null);
            if (old_parameter.index() >= value_map.len)
                return Error.InvalidModule;
            value_map[old_parameter.index()] = new_parameter;
        }
    }

    for (callee_blocks) |old_block_id| {
        const old_block = module.blocks.get(old_block_id) orelse return Error.InvalidModule;
        const new_block_id = mappedBlock(block_map, old_block_id) orelse return Error.InvalidModule;

        for (old_block.instructions.items) |old_instruction_id| {
            const old_instruction = (module.instructions.get(old_instruction_id) orelse return Error.InvalidModule).*;
            const new_instruction_id = try module.instructions.add(module.allocator(), .{
                .parent_block = new_block_id,
                .result = null,
                .operation = old_instruction.operation,
                .source = old_instruction.source,
            });
            if (old_instruction_id.index() >= instruction_map.len)
                return Error.InvalidModule;
            instruction_map[old_instruction_id.index()] = new_instruction_id;

            if (old_instruction.result) |old_result| {
                const old_value = module.values.get(old_result) orelse return Error.InvalidModule;
                const new_result = try module.values.add(module.allocator(), .{
                    .type = old_value.type,
                    .definition = .{ .instruction = new_instruction_id },
                    .name = null,
                });
                module.instructions.getMut(new_instruction_id).?.result = new_result;
                if (old_result.index() >= value_map.len)
                    return Error.InvalidModule;
                value_map[old_result.index()] = new_result;
            }

            const new_block = module.blocks.getMut(new_block_id) orelse return Error.InvalidModule;
            try new_block.instructions.append(module.allocator(), new_instruction_id);
        }
    }

    for (callee_blocks) |old_block_id| {
        const old_block = module.blocks.get(old_block_id) orelse return Error.InvalidModule;
        const new_block_id = mappedBlock(block_map, old_block_id) orelse return Error.InvalidModule;

        for (old_block.instructions.items) |old_instruction_id| {
            const new_instruction_id = mappedInstruction(instruction_map, old_instruction_id) orelse return Error.InvalidModule;
            const new_instruction = module.instructions.getMut(new_instruction_id) orelse return Error.InvalidModule;
            new_instruction.operation = try remapOperation(module, value_map, new_instruction.operation);
        }

        const new_block = module.blocks.getMut(new_block_id) orelse return Error.InvalidModule;
        new_block.structured_control = try remapStructuredControl(block_map, old_block.structured_control);
        new_block.terminator = try remapTerminator(
            module,
            value_map,
            block_map,
            old_block.terminator orelse return Error.InvalidModule,
            continuation_id,
            returns_value,
        );
    }

    return mappedBlock(block_map, callee_entry) orelse return Error.InvalidModule;
}

fn remapOperation(
    module: *module_ir.Module,
    value_map: []const ?ids.ValueId,
    operation: instruction_ir.Operation,
) Error!instruction_ir.Operation {
    return switch (operation) {
        .unary => |op| .{ .unary = .{
            .opcode = op.opcode,
            .operand = try mappedValue(module, value_map, op.operand),
        } },
        .binary => |op| .{ .binary = .{
            .opcode = op.opcode,
            .lhs = try mappedValue(module, value_map, op.lhs),
            .rhs = try mappedValue(module, value_map, op.rhs),
        } },
        .compare => |op| .{ .compare = .{
            .opcode = op.opcode,
            .lhs = try mappedValue(module, value_map, op.lhs),
            .rhs = try mappedValue(module, value_map, op.rhs),
        } },
        .select => |op| .{ .select = .{
            .condition = try mappedValue(module, value_map, op.condition),
            .true_value = try mappedValue(module, value_map, op.true_value),
            .false_value = try mappedValue(module, value_map, op.false_value),
        } },
        .bitcast => |operand| .{ .bitcast = try mappedValue(module, value_map, operand) },
        .composite_construct => |op| .{ .composite_construct = .{
            .elements = try remapValues(module, value_map, op.elements),
        } },
        .composite_extract => |op| .{ .composite_extract = .{
            .composite = try mappedValue(module, value_map, op.composite),
            .indices = op.indices,
        } },
        .load_interface => |op| .{ .load_interface = .{
            .variable = op.variable,
            .element_index = if (op.element_index) |index| try mappedValue(module, value_map, index) else null,
        } },
        .store_interface => |op| .{ .store_interface = .{
            .variable = op.variable,
            .value = try mappedValue(module, value_map, op.value),
            .element_index = if (op.element_index) |index| try mappedValue(module, value_map, index) else null,
        } },
        .call => Error.InvalidModule,
    };
}

fn remapTerminator(
    module: *module_ir.Module,
    value_map: []const ?ids.ValueId,
    block_map: []const ?ids.BlockId,
    terminator: module_ir.Terminator,
    continuation_id: ids.BlockId,
    returns_value: bool,
) Error!module_ir.Terminator {
    return switch (terminator) {
        .branch => |edge| .{ .branch = try remapEdge(module, value_map, block_map, edge) },
        .conditional_branch => |branch| .{ .conditional_branch = .{
            .condition = try mappedValue(module, value_map, branch.condition),
            .true_edge = try remapEdge(module, value_map, block_map, branch.true_edge),
            .false_edge = try remapEdge(module, value_map, block_map, branch.false_edge),
        } },
        .return_void => if (returns_value)
            Error.InvalidModule
        else
            .{ .branch = .{
                .target = continuation_id,
                .arguments = try module.allocator().alloc(ids.ValueId, 0),
            } },
        .return_value => |value| if (!returns_value)
            Error.InvalidModule
        else
            .{ .branch = .{
                .target = continuation_id,
                .arguments = try remapValues(module, value_map, &.{value}),
            } },
        .discard => .discard,
        .@"unreachable" => .@"unreachable",
    };
}

fn remapEdge(module: *module_ir.Module, value_map: []const ?ids.ValueId, block_map: []const ?ids.BlockId, edge: module_ir.Edge) Error!module_ir.Edge {
    return .{
        .target = mappedBlock(block_map, edge.target) orelse return Error.InvalidModule,
        .arguments = try remapValues(module, value_map, edge.arguments),
    };
}

fn remapStructuredControl(block_map: []const ?ids.BlockId, control: module_ir.StructuredControl) Error!module_ir.StructuredControl {
    return switch (control) {
        .none => .none,
        .selection => |selection| .{ .selection = .{
            .merge_block = mappedBlock(block_map, selection.merge_block) orelse return Error.InvalidModule,
        } },
        .loop => |loop| .{ .loop = .{
            .merge_block = mappedBlock(block_map, loop.merge_block) orelse return Error.InvalidModule,
            .continue_block = mappedBlock(block_map, loop.continue_block) orelse return Error.InvalidModule,
        } },
    };
}

fn remapValues(module: *module_ir.Module, value_map: []const ?ids.ValueId, values: []const ids.ValueId) Error![]const ids.ValueId {
    const result = try module.allocator().alloc(ids.ValueId, values.len);
    for (values, result) |value, *mapped|
        mapped.* = try mappedValue(module, value_map, value);
    return result;
}

fn mappedValue(module: *const module_ir.Module, value_map: []const ?ids.ValueId, value_id: ids.ValueId) Error!ids.ValueId {
    if (value_id.index() < value_map.len) {
        if (value_map[value_id.index()]) |mapped|
            return mapped;
    }

    const value = module.values.get(value_id) orelse return Error.InvalidModule;
    return switch (value.definition) {
        .constant, .undef => value_id,
        else => Error.InvalidModule,
    };
}

fn removeUnreachableBlocks(module: *module_ir.Module, scratch_allocator: std.mem.Allocator) Error!bool {
    const reachable = try scratch_allocator.alloc(bool, module.blocks.entries.items.len);
    defer scratch_allocator.free(reachable);

    var queue: std.ArrayList(ids.BlockId) = .empty;
    defer queue.deinit(scratch_allocator);

    var changed = false;
    for (module.functions.entries.items, 0..) |entry, function_index| {
        const function = entry orelse continue;
        const function_id = ids.FunctionId.fromIndex(function_index);
        const entry_block = function.entry_block orelse return Error.InvalidModule;

        @memset(reachable, false);
        queue.clearRetainingCapacity();
        try enqueueReachable(module, scratch_allocator, function_id, reachable, &queue, entry_block);

        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const block = module.blocks.get(queue.items[cursor]) orelse return Error.InvalidModule;
            switch (block.terminator orelse return Error.InvalidModule) {
                .branch => |edge| try enqueueReachable(module, scratch_allocator, function_id, reachable, &queue, edge.target),
                .conditional_branch => |branch| {
                    try enqueueReachable(module, scratch_allocator, function_id, reachable, &queue, branch.true_edge.target);
                    try enqueueReachable(module, scratch_allocator, function_id, reachable, &queue, branch.false_edge.target);
                },
                else => {},
            }
        }

        for (queue.items) |block_id| {
            const block = module.blocks.get(block_id) orelse return Error.InvalidModule;
            switch (block.structured_control) {
                .none => {},
                .selection => |selection| if (!isReachable(reachable, selection.merge_block))
                    return Error.InvalidModule,
                .loop => |loop| if (!isReachable(reachable, loop.merge_block) or !isReachable(reachable, loop.continue_block))
                    return Error.InvalidModule,
            }
        }

        const mutable_function = module.functions.getMut(function_id) orelse return Error.InvalidModule;
        var block_index: usize = 0;
        while (block_index < mutable_function.blocks.items.len) {
            const block_id = mutable_function.blocks.items[block_index];
            if (isReachable(reachable, block_id)) {
                block_index += 1;
                continue;
            }

            removeBlock(module, block_id);
            _ = mutable_function.blocks.orderedRemove(block_index);
            changed = true;
        }
    }

    return changed;
}

fn enqueueReachable(
    module: *const module_ir.Module,
    scratch_allocator: std.mem.Allocator,
    function_id: ids.FunctionId,
    reachable: []bool,
    queue: *std.ArrayList(ids.BlockId),
    block_id: ids.BlockId,
) Error!void {
    if (block_id.index() >= reachable.len)
        return Error.InvalidModule;
    if (reachable[block_id.index()])
        return;

    const block = module.blocks.get(block_id) orelse return Error.InvalidModule;
    if (block.parent_function != function_id)
        return Error.InvalidModule;

    reachable[block_id.index()] = true;
    try queue.append(scratch_allocator, block_id);
}

fn isReachable(reachable: []const bool, block_id: ids.BlockId) bool {
    return block_id.index() < reachable.len and reachable[block_id.index()];
}

fn removeBlock(module: *module_ir.Module, block_id: ids.BlockId) void {
    const block = module.blocks.get(block_id) orelse return;
    for (block.parameters.items) |parameter_id|
        _ = module.values.remove(parameter_id);
    for (block.instructions.items) |instruction_id| {
        const inst = module.instructions.get(instruction_id) orelse continue;
        if (inst.result) |result_id|
            _ = module.values.remove(result_id);
        _ = module.instructions.remove(instruction_id);
    }
    _ = module.blocks.remove(block_id);
}

fn mappedBlock(block_map: []const ?ids.BlockId, block_id: ids.BlockId) ?ids.BlockId {
    if (block_id.index() >= block_map.len)
        return null;
    return block_map[block_id.index()];
}

fn mappedInstruction(instruction_map: []const ?ids.InstructionId, instruction_id: ids.InstructionId) ?ids.InstructionId {
    if (instruction_id.index() >= instruction_map.len)
        return null;
    return instruction_map[instruction_id.index()];
}

fn removeNonEntryFunctions(module: *module_ir.Module, entry_point: ids.FunctionId) bool {
    var changed = false;
    for (module.functions.entries.items, 0..) |entry, function_index| {
        const function = entry orelse continue;
        const function_id = ids.FunctionId.fromIndex(function_index);
        if (function_id == entry_point)
            continue;

        for (function.parameters.items) |parameter_id|
            _ = module.values.remove(parameter_id);

        for (function.blocks.items) |block_id| {
            const block = module.blocks.get(block_id) orelse continue;
            for (block.parameters.items) |parameter_id|
                _ = module.values.remove(parameter_id);
            for (block.instructions.items) |instruction_id| {
                const inst = module.instructions.get(instruction_id) orelse continue;
                if (inst.result) |result_id|
                    _ = module.values.remove(result_id);
                _ = module.instructions.remove(instruction_id);
            }
            _ = module.blocks.remove(block_id);
        }

        _ = module.functions.remove(function_id);
        changed = true;
    }
    return changed;
}

fn runForTest(module: *module_ir.Module) !bool {
    var manager = transformer_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.add(transformer);

    var context: transformer_manager.Context = .{ .allocator = std.testing.allocator };
    return manager.run(module, &context);
}

fn liveFunctionCount(module: *const module_ir.Module) usize {
    var count: usize = 0;
    for (module.functions.entries.items) |entry| {
        if (entry != null)
            count += 1;
    }
    return count;
}

test "Inline All Functions: nested calls and multiple returns" {
    const parser = @import("../parser/parser.zig");
    const validator = @import("../validator/validator.zig");

    var module = try parser.parseString(std.testing.allocator,
        \\shader vertex @main
        \\{
        \\    %condition: constant bool = true
        \\    %one: constant u32 = bits(0x1)
        \\    %two: constant u32 = bits(0x2)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = call @outer(%one)
        \\            %sum: u32 = integer_add %result, %two
        \\            return
        \\    }
        \\    fn @outer(%outer_value: u32) -> u32
        \\    {
        \\        .entry():
        \\            %nested: u32 = call @identity(%outer_value)
        \\            return %nested
        \\    }
        \\    fn @identity(%identity_value: u32) -> u32
        \\    {
        \\        .entry():
        \\            conditional_branch %condition, .left(), .right()
        \\        .left():
        \\            return %identity_value
        \\        .right():
        \\            return %two
        \\    }
        \\}
    );
    defer module.deinit();

    try std.testing.expect(try runForTest(&module));
    try validator.validate(&module);
    try std.testing.expect(module.properties.no_function_calls);
    try std.testing.expectEqual(@as(usize, 1), liveFunctionCount(&module));

    for (module.instructions.entries.items) |entry| {
        const inst = entry orelse continue;
        try std.testing.expect(inst.operation != .call);
    }
}

test "Inline All Functions: reject reachable recursion" {
    const parser = @import("../parser/parser.zig");

    var module = try parser.parseString(std.testing.allocator,
        \\shader vertex @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = call @recurse(%one)
        \\            return
        \\    }
        \\    fn @recurse(%value: u32) -> u32
        \\    {
        \\        .entry():
        \\            %nested: u32 = call @recurse(%value)
        \\            return %nested
        \\    }
        \\}
    );
    defer module.deinit();

    try std.testing.expectError(Error.RecursiveCall, runForTest(&module));
    try std.testing.expectEqual(@as(usize, 2), liveFunctionCount(&module));
}

test "Inline All Functions: remove calls in unreachable blocks" {
    const parser = @import("../parser/parser.zig");
    const validator = @import("../validator/validator.zig");

    var module = try parser.parseString(std.testing.allocator,
        \\shader vertex @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return
        \\        .dead():
        \\            %local: u32 = integer_add %one, %one
        \\            %result: u32 = call @identity(%local)
        \\            return
        \\    }
        \\    fn @identity(%identity_value: u32) -> u32
        \\    {
        \\        .entry():
        \\            return %identity_value
        \\    }
        \\}
    );
    defer module.deinit();

    try std.testing.expect(try runForTest(&module));
    try validator.validate(&module);
    try std.testing.expectEqual(@as(usize, 1), liveFunctionCount(&module));
    const entry_function = module.functions.get(module.entry_point.?).?;
    try std.testing.expectEqual(@as(usize, 1), entry_function.blocks.items.len);
}

test "Inline All Functions: remove unreachable recursive helpers" {
    const parser = @import("../parser/parser.zig");
    const validator = @import("../validator/validator.zig");

    var module = try parser.parseString(std.testing.allocator,
        \\shader vertex @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\    fn @dead() -> void
        \\    {
        \\        .entry():
        \\            call @dead()
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    try std.testing.expect(try runForTest(&module));
    try validator.validate(&module);
    try std.testing.expectEqual(@as(usize, 1), liveFunctionCount(&module));
}
