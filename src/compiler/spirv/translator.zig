const std = @import("std");
const Parser = @import("Parser.zig");
const spirv = @import("spirv.zig");
const ir = @import("../ir/ir.zig");

pub const Options = struct {
    entry_point: []const u8,
};

pub const TranslationError = error{
    EntryPointNotFound,
    AmbiguousEntryPoint,
    UnsupportedExecutionModel,
    InvalidInstruction,
    InvalidId,
    DuplicateId,
    MissingDefinition,
    MissingFunction,
    InvalidFunctionType,
    InvalidFunctionParameter,
    InvalidBlock,
    InvalidPhi,
    MissingPhiIncomingValue,
    UnsupportedType,
    UnsupportedConstant,
    SpecializationConstantsNotApplied,
    UnsupportedOpcode,
};

const EntryPoint = struct {
    model: spirv.ExecutionModel,
    function_id: u32,
    interface_ids: []const u32,
};

const Decorations = struct {
    location: ?u32 = null,
    component: u8 = 0,
    index: u8 = 0,
    builtin: ?u32 = null,
};

const PhiInfo = struct {
    target_label: u32,
    incoming_words: []const u32,
};

const Context = struct {
    scratch: std.mem.Allocator,
    parser: Parser,
    module: *ir.module.Module,
    builder: ir.Builder,
    bound: usize,

    type_defs: []?Parser.Instruction,
    value_defs: []?Parser.Instruction,
    variable_defs: []?Parser.Instruction,
    names: []?[]const u8,
    decorations: []Decorations,

    types: []?ir.id.TypeId,
    values: []?ir.id.ValueId,
    blocks: []?ir.id.BlockId,
    interfaces: []?ir.id.InterfaceVariableId,
    phi_infos: std.ArrayList(PhiInfo) = .empty,

    fn idIndex(self: *const Context, id: u32) TranslationError!usize {
        if (id == 0 or id >= self.bound)
            return error.InvalidId;
        return id;
    }

    fn recordDefinition(self: *Context, definitions: []?Parser.Instruction, id: u32, instruction: Parser.Instruction) TranslationError!void {
        const index = try self.idIndex(id);
        if (definitions[index] != null)
            return error.DuplicateId;
        definitions[index] = instruction;
    }

    fn nameOf(self: *const Context, id: u32) ?[]const u8 {
        const index = self.idIndex(id) catch return null;
        return self.names[index];
    }

    fn translateType(self: *Context, spv_id: u32) anyerror!ir.id.TypeId {
        const index = try self.idIndex(spv_id);
        if (self.types[index]) |translated|
            return translated;

        const instruction = self.type_defs[index] orelse return error.MissingDefinition;
        const operands = instruction.operands;

        const translated = switch (instruction.opcode) {
            .type_void => blk: {
                try expectOperandCount(operands, 1);
                break :blk try self.builder.internType(.void);
            },
            .type_bool => blk: {
                try expectOperandCount(operands, 1);
                break :blk try self.builder.internType(.boolean);
            },
            .type_int => blk: {
                try expectOperandCount(operands, 3);

                if (operands[1] == 0 or operands[1] > 64 or operands[2] > 1)
                    return error.UnsupportedType;

                break :blk try self.builder.internType(.{
                    .integer = .{
                        .bits = @intCast(operands[1]),
                        .signedness = if (operands[2] == 0) .unsigned else .signed,
                    },
                });
            },
            .type_float => blk: {
                try expectOperandCount(operands, 2);

                if (operands[1] != 16 and operands[1] != 32 and operands[1] != 64)
                    return error.UnsupportedType;

                break :blk try self.builder.internType(.{
                    .floating = .{
                        .bits = @intCast(operands[1]),
                    },
                });
            },
            .type_vector => blk: {
                try expectOperandCount(operands, 3);

                if (operands[2] < 2 or operands[2] > std.math.maxInt(u8))
                    return error.UnsupportedType;

                break :blk try self.builder.internType(.{
                    .vector = .{
                        .element_type = try self.translateType(operands[1]),
                        .length = @intCast(operands[2]),
                    },
                });
            },
            .type_array => blk: {
                try expectOperandCount(operands, 3);

                const length_value = try self.translateValue(operands[2]);
                const length_constant_value = self.module.values.get(length_value) orelse return error.InvalidId;

                if (length_constant_value.definition != .constant)
                    return error.UnsupportedType;

                const constant = self.module.constants.get(length_constant_value.definition.constant) orelse return error.InvalidId;
                if (constant.value != .integer_bits or constant.value.integer_bits == 0 or constant.value.integer_bits > std.math.maxInt(u32))
                    return error.UnsupportedType;

                break :blk try self.builder.internType(.{
                    .array = .{
                        .element_type = try self.translateType(operands[1]),
                        .length = @intCast(constant.value.integer_bits),
                    },
                });
            },
            .type_struct => blk: {
                if (operands.len == 0)
                    return error.InvalidInstruction;

                const members = try self.scratch.alloc(ir.id.TypeId, operands.len - 1);

                for (operands[1..], members) |member_id, *member|
                    member.* = try self.translateType(member_id);

                break :blk try self.builder.internType(.{
                    .structure = .{
                        .members = members,
                    },
                });
            },
            .type_pointer => blk: {
                try expectOperandCount(operands, 3);
                break :blk try self.builder.internType(.{
                    .pointer = .{
                        .address_space = try translateStorageClass(@enumFromInt(operands[1])),
                        .pointee_type = try self.translateType(operands[2]),
                    },
                });
            },

            else => return error.UnsupportedType,
        };
        self.types[index] = translated;
        return translated;
    }

    fn translateValue(self: *Context, spv_id: u32) anyerror!ir.id.ValueId {
        const index = try self.idIndex(spv_id);

        if (self.values[index]) |translated|
            return translated;

        const instruction = self.value_defs[index] orelse return error.MissingDefinition;
        const operands = instruction.operands;

        const translated = switch (instruction.opcode) {
            .undef => blk: {
                try expectOperandCount(operands, 2);
                break :blk try self.module.values.add(self.module.allocator(), .{
                    .type = try self.translateType(operands[0]),
                    .definition = .undef,
                    .name = if (self.nameOf(spv_id)) |name| try self.module.allocator().dupe(u8, name) else null,
                });
            },
            .constant_true => blk: {
                try expectOperandCount(operands, 2);
                break :blk try self.builder.internConstant(try self.translateType(operands[0]), .{ .boolean = true });
            },
            .constant_false => blk: {
                try expectOperandCount(operands, 2);
                break :blk try self.builder.internConstant(try self.translateType(operands[0]), .{ .boolean = false });
            },
            .constant => blk: {
                if (operands.len < 3 or operands.len > 4)
                    return error.InvalidInstruction;

                const ty = try self.translateType(operands[0]);
                const type_data = self.module.types.get(ty) orelse return error.InvalidId;
                const bits = try literalBits(operands[2..]);

                break :blk switch (type_data.*) {
                    .integer => try self.builder.internConstant(ty, .{ .integer_bits = bits }),
                    .floating => try self.builder.internConstant(ty, .{ .float_bits = bits }),
                    else => return error.UnsupportedConstant,
                };
            },
            .constant_null => blk: {
                try expectOperandCount(operands, 2);
                break :blk try self.builder.internConstant(try self.translateType(operands[0]), .null);
            },
            .constant_composite => blk: {
                if (operands.len < 2)
                    return error.InvalidInstruction;

                const elements = try self.scratch.alloc(ir.id.ConstantId, operands.len - 2);

                for (operands[2..], elements) |element_id, *element| {
                    const element_value = self.module.values.get(try self.translateValue(element_id)) orelse return error.InvalidId;

                    if (element_value.definition != .constant)
                        return error.UnsupportedConstant;

                    element.* = element_value.definition.constant;
                }

                break :blk try self.builder.internConstant(
                    try self.translateType(operands[0]),
                    .{ .composite = elements },
                );
            },
            .spec_constant_true,
            .spec_constant_false,
            .spec_constant,
            .spec_constant_composite,
            .spec_constant_op,
            => return error.SpecializationConstantsNotApplied,

            else => return error.MissingDefinition,
        };
        try self.builder.setValueName(translated, self.nameOf(spv_id));
        self.values[index] = translated;
        return translated;
    }

    fn setValue(self: *Context, spv_id: u32, translated_value: ir.id.ValueId) TranslationError!void {
        const index = try self.idIndex(spv_id);

        if (self.values[index] != null)
            return error.DuplicateId;

        self.values[index] = translated_value;
    }

    fn resolveValue(self: *Context, spv_id: u32) anyerror!ir.id.ValueId {
        return self.translateValue(spv_id);
    }

    fn block(self: *const Context, spv_id: u32) TranslationError!ir.id.BlockId {
        const index = try self.idIndex(spv_id);
        return self.blocks[index] orelse error.InvalidBlock;
    }

    fn interfaceVariable(self: *const Context, spv_id: u32) TranslationError!ir.id.InterfaceVariableId {
        const index = try self.idIndex(spv_id);
        return self.interfaces[index] orelse error.UnsupportedOpcode;
    }
};

pub fn translate(allocator: std.mem.Allocator, words: []const u32, options: Options) !ir.module.Module {
    const parser = try Parser.init(words);
    const entry_point = try findEntryPoint(parser, options.entry_point);
    const stage = try translateStage(entry_point.model);

    var module = ir.module.Module.init(allocator, stage);
    errdefer module.deinit();

    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    const bound: usize = parser.header.bound;

    var context: Context = .{
        .scratch = scratch,
        .parser = parser,
        .module = &module,
        .builder = ir.Builder.init(&module),
        .bound = bound,
        .type_defs = try allocOptional(Parser.Instruction, scratch, bound),
        .value_defs = try allocOptional(Parser.Instruction, scratch, bound),
        .variable_defs = try allocOptional(Parser.Instruction, scratch, bound),
        .names = try allocOptional([]const u8, scratch, bound),
        .decorations = try scratch.alloc(Decorations, bound),
        .types = try allocOptional(ir.id.TypeId, scratch, bound),
        .values = try allocOptional(ir.id.ValueId, scratch, bound),
        .blocks = try allocOptional(ir.id.BlockId, scratch, bound),
        .interfaces = try allocOptional(ir.id.InterfaceVariableId, scratch, bound),
    };
    @memset(context.decorations, .{});
    defer context.phi_infos.deinit(scratch);

    try collectDeclarations(&context);
    try translateInterfaces(&context, entry_point.interface_ids);
    try applyExecutionModes(&context, entry_point.function_id);
    try translateFunction(&context, entry_point.function_id, options.entry_point);
    try ir.validator.validate(&module);
    module.properties.valid_cfg = true;
    module.properties.valid_ssa = true;
    module.properties.structured_control_flow = true;
    module.properties.no_function_calls = true;
    return module;
}

fn collectDeclarations(context: *Context) !void {
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        const operands = instruction.operands;
        if (isTypeOpcode(instruction.opcode)) {
            if (operands.len == 0)
                return error.InvalidInstruction;

            try context.recordDefinition(context.type_defs, operands[0], instruction);
            continue;
        }
        if (isConstantOpcode(instruction.opcode) or instruction.opcode == .undef) {
            if (operands.len < 2)
                return error.InvalidInstruction;

            try context.recordDefinition(context.value_defs, operands[1], instruction);
            continue;
        }
        if (instruction.opcode == .name) {
            if (operands.len < 2)
                return error.InvalidInstruction;

            const index = try context.idIndex(operands[0]);
            context.names[index] = try Parser.copyLiteralString(context.scratch, operands[1..]);
            continue;
        }
        if (instruction.opcode == .variable) {
            if (operands.len < 3)
                return error.InvalidInstruction;

            try context.recordDefinition(context.variable_defs, operands[1], instruction);
            continue;
        }
        if (instruction.opcode == .decorate) {
            try collectDecoration(context, operands);
        }
    }
}

fn collectDecoration(context: *Context, operands: []const u32) !void {
    if (operands.len < 2) return error.InvalidInstruction;
    const index = try context.idIndex(operands[0]);
    const decoration: spirv.Decoration = @enumFromInt(operands[1]);
    switch (decoration) {
        .built_in => {
            try expectOperandCount(operands, 3);
            context.decorations[index].builtin = operands[2];
        },
        .location => {
            try expectOperandCount(operands, 3);
            context.decorations[index].location = operands[2];
        },
        .component => {
            try expectOperandCount(operands, 3);
            if (operands[2] > std.math.maxInt(u8)) return error.InvalidInstruction;
            context.decorations[index].component = @intCast(operands[2]);
        },
        .index => {
            try expectOperandCount(operands, 3);
            if (operands[2] > std.math.maxInt(u8)) return error.InvalidInstruction;
            context.decorations[index].index = @intCast(operands[2]);
        },
        else => {},
    }
}

fn translateInterfaces(context: *Context, interface_ids: []const u32) !void {
    for (interface_ids) |spv_id| {
        const index = try context.idIndex(spv_id);
        const variable = context.variable_defs[index] orelse return error.MissingDefinition;

        if (variable.operands.len < 3 or variable.operands.len > 4)
            return error.InvalidInstruction;

        const storage_class: spirv.StorageClass = @enumFromInt(variable.operands[2]);
        const direction: ir.module.InterfaceDirection = switch (storage_class) {
            .input => .input,
            .output => .output,
            else => continue,
        };

        const pointer_index = try context.idIndex(variable.operands[0]);
        const pointer = context.type_defs[pointer_index] orelse return error.MissingDefinition;

        if (pointer.opcode != .type_pointer)
            return error.InvalidInstruction;

        try expectOperandCount(pointer.operands, 3);

        if (pointer.operands[1] != variable.operands[2])
            return error.InvalidInstruction;

        const decoration = context.decorations[index];

        if (decoration.location != null and decoration.builtin != null)
            return error.InvalidInstruction;

        const semantic: ir.module.InterfaceSemantic = if (decoration.location) |location|
            .{
                .location = .{
                    .location = location,
                    .component = decoration.component,
                    .index = decoration.index,
                },
            }
        else if (decoration.builtin) |builtin|
            .{
                .builtin = try translateBuiltin(builtin),
            }
        else
            return error.InvalidInstruction;

        context.interfaces[index] = try context.builder.addInterfaceVariable(
            try context.translateType(pointer.operands[2]),
            direction,
            semantic,
            context.nameOf(spv_id),
        );
    }
}

fn findEntryPoint(parser: Parser, requested_name: []const u8) !EntryPoint {
    var found: ?EntryPoint = null;
    var iterator = parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode != .entry_point)
            continue;

        if (instruction.operands.len < 3)
            return error.InvalidInstruction;

        const string_words = try Parser.literalStringWordCount(instruction.operands[2..]);

        if (2 + string_words > instruction.operands.len)
            return error.InvalidInstruction;

        if (!try Parser.literalStringEquals(instruction.operands[2 .. 2 + string_words], requested_name))
            continue;

        if (found != null)
            return error.AmbiguousEntryPoint;

        found = .{
            .model = @enumFromInt(instruction.operands[0]),
            .function_id = instruction.operands[1],
            .interface_ids = instruction.operands[2 + string_words ..],
        };
    }
    return found orelse error.EntryPointNotFound;
}

fn applyExecutionModes(context: *Context, entry_function: u32) !void {
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode != .execution_mode)
            continue;

        if (instruction.operands.len < 2)
            return error.InvalidInstruction;

        if (instruction.operands[0] != entry_function)
            continue;

        const mode: spirv.ExecutionMode = @enumFromInt(instruction.operands[1]);

        switch (mode) {
            .early_fragment_tests => context.module.execution_modes.early_fragment_tests = true,
            .local_size => {
                try expectOperandCount(instruction.operands, 5);
                context.module.execution_modes.workgroup_size = instruction.operands[2..5].*;
            },
            else => {},
        }
    }
}

fn translateFunction(context: *Context, spv_function: u32, entry_name: []const u8) !void {
    const function_instruction = try findFunction(context.parser, spv_function);
    try expectOperandCount(function_instruction.operands, 4);
    const function_type = try functionTypeDefinition(context, function_instruction.operands[3]);

    if (function_type.operands.len < 2 or function_type.operands[1] != function_instruction.operands[0])
        return error.InvalidFunctionType;

    const function = try context.builder.addFunction(
        try context.translateType(function_instruction.operands[0]),
        context.nameOf(spv_function) orelse entry_name,
    );
    context.builder.setEntryPoint(function);

    try predeclareFunction(context, spv_function, function, function_type.operands[2..]);
    try translateFunctionInstructions(context, spv_function);
    try translateFunctionControlFlow(context, spv_function);
}

fn predeclareFunction(context: *Context, spv_function: u32, function: ir.id.FunctionId, parameter_types: []const u32) !void {
    var active = false;
    var parameter_index: usize = 0;
    var current_label: ?u32 = null;
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode == .function) {
            active = instruction.operands.len >= 2 and instruction.operands[1] == spv_function;
            continue;
        }

        if (!active)
            continue;

        switch (instruction.opcode) {
            .function_parameter => {
                try expectOperandCount(instruction.operands, 2);

                if (parameter_index >= parameter_types.len or parameter_types[parameter_index] != instruction.operands[0])
                    return error.InvalidFunctionParameter;

                const value = try context.builder.addFunctionParameter(
                    function,
                    try context.translateType(instruction.operands[0]),
                    context.nameOf(instruction.operands[1]),
                );

                try context.setValue(instruction.operands[1], value);
                parameter_index += 1;
            },
            .label => {
                try expectOperandCount(instruction.operands, 1);
                const label_id = instruction.operands[0];
                const index = try context.idIndex(label_id);

                if (context.blocks[index] != null)
                    return error.DuplicateId;

                context.blocks[index] = try context.builder.addBlock(function, context.nameOf(label_id));
                current_label = label_id;
            },
            .phi => {
                if (instruction.operands.len < 4 or (instruction.operands.len - 2) % 2 != 0)
                    return error.InvalidPhi;

                const label = current_label orelse return error.InvalidPhi;
                const value = try context.builder.addBlockParameter(
                    try context.block(label),
                    try context.translateType(instruction.operands[0]),
                    context.nameOf(instruction.operands[1]),
                );

                try context.setValue(instruction.operands[1], value);
                try context.phi_infos.append(context.scratch, .{
                    .target_label = label,
                    .incoming_words = instruction.operands[2..],
                });
            },
            .function_end => break,

            else => {},
        }
    }
    if (parameter_index != parameter_types.len)
        return error.InvalidFunctionParameter;
}

fn translateFunctionInstructions(context: *Context, spv_function: u32) !void {
    var active = false;
    var current_block: ?ir.id.BlockId = null;
    var iterator = context.parser.iterator();

    while (try iterator.next()) |instruction| {
        if (instruction.opcode == .function) {
            active = instruction.operands.len >= 2 and instruction.operands[1] == spv_function;
            continue;
        }

        if (!active)
            continue;

        switch (instruction.opcode) {
            .label => current_block = try context.block(instruction.operands[0]),

            .function_parameter,
            .phi,
            .selection_merge,
            .loop_merge,
            .branch,
            .branch_conditional,
            .return_,
            .return_value,
            .kill,
            .@"unreachable",
            => {},

            .function_end => break,

            .nop,
            .line,
            .no_line,
            => {},

            else => try translateInstruction(context, current_block orelse return error.InvalidBlock, instruction),
        }
    }
}

fn translateInstruction(context: *Context, block: ir.id.BlockId, instruction: Parser.Instruction) !void {
    const operands = instruction.operands;
    switch (instruction.opcode) {
        .undef => {
            try expectOperandCount(operands, 2);
            _ = try context.translateValue(operands[1]);
        },
        .copy_object => {
            try expectOperandCount(operands, 3);
            const source = try context.resolveValue(operands[2]);

            if (context.module.typeOf(source) != try context.translateType(operands[0]))
                return error.InvalidInstruction;

            try context.setValue(operands[1], source);
        },
        .load => {
            if (operands.len < 3)
                return error.InvalidInstruction;

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .load_interface = .{ .variable = try context.interfaceVariable(operands[2]) },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .store => {
            if (operands.len < 2)
                return error.InvalidInstruction;

            _ = try context.builder.appendInstruction(block, null, .{
                .store_interface = .{
                    .variable = try context.interfaceVariable(operands[0]),
                    .value = try context.resolveValue(operands[1]),
                },
            }, null);
        },
        .s_negate, .f_negate, .logical_not => {
            try expectOperandCount(operands, 3);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .unary = .{
                    .opcode = if (instruction.opcode == .logical_not) .logical_not else .negate,
                    .operand = try context.resolveValue(operands[2]),
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .i_add,
        .i_sub,
        .i_mul,
        .u_div,
        .s_div,
        .u_mod,
        .s_mod,
        .f_add,
        .f_sub,
        .f_mul,
        .f_div,
        .f_mod,
        .shift_left_logical,
        .shift_right_logical,
        .shift_right_arithmetic,
        .bitwise_and,
        .bitwise_or,
        .bitwise_xor,
        .logical_and,
        .logical_or,
        => {
            try expectOperandCount(operands, 4);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .binary = .{
                    .opcode = translateBinaryOpcode(instruction.opcode),
                    .lhs = try context.resolveValue(operands[2]),
                    .rhs = try context.resolveValue(operands[3]),
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .logical_equal,
        .logical_not_equal,
        .i_equal,
        .i_not_equal,
        .u_less_than,
        .s_less_than,
        .f_ord_equal,
        .f_unord_equal,
        .f_ord_not_equal,
        .f_unord_not_equal,
        .f_ord_less_than,
        .f_unord_less_than,
        => {
            try expectOperandCount(operands, 4);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .compare = .{
                    .opcode = translateCompareOpcode(instruction.opcode),
                    .lhs = try context.resolveValue(operands[2]),
                    .rhs = try context.resolveValue(operands[3]),
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .select => {
            try expectOperandCount(operands, 5);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .select = .{
                    .condition = try context.resolveValue(operands[2]),
                    .true_value = try context.resolveValue(operands[3]),
                    .false_value = try context.resolveValue(operands[4]),
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .bitcast => {
            try expectOperandCount(operands, 3);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .bitcast = try context.resolveValue(operands[2]),
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .composite_construct => {
            if (operands.len < 2)
                return error.InvalidInstruction;

            const elements = try context.scratch.alloc(ir.id.ValueId, operands.len - 2);

            for (operands[2..], elements) |element_id, *element|
                element.* = try context.resolveValue(element_id);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .composite_construct = .{
                    .elements = elements,
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .composite_extract => {
            if (operands.len < 4)
                return error.InvalidInstruction;

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .composite_extract = .{
                    .composite = try context.resolveValue(operands[2]),
                    .indices = operands[3..],
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .function_call => return error.UnsupportedOpcode,

        else => return error.UnsupportedOpcode,
    }
}

fn translateFunctionControlFlow(context: *Context, spv_function: u32) !void {
    var active = false;
    var current_label: ?u32 = null;
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode == .function) {
            active = instruction.operands.len >= 2 and instruction.operands[1] == spv_function;
            continue;
        }

        if (!active)
            continue;

        const operands = instruction.operands;
        switch (instruction.opcode) {
            .label => {
                try expectOperandCount(operands, 1);
                current_label = operands[0];
            },
            .selection_merge => {
                try expectOperandCount(operands, 2);
                const block = context.module.blocks.getMut(try context.block(current_label orelse return error.InvalidBlock)).?;
                block.structured_control = .{
                    .selection = .{
                        .merge_block = try context.block(operands[0]),
                    },
                };
            },
            .loop_merge => {
                try expectOperandCount(operands, 3);
                const block = context.module.blocks.getMut(try context.block(current_label orelse return error.InvalidBlock)).?;
                block.structured_control = .{
                    .loop = .{
                        .merge_block = try context.block(operands[0]),
                        .continue_block = try context.block(operands[1]),
                    },
                };
            },
            .branch => {
                try expectOperandCount(operands, 1);
                const predecessor = current_label orelse return error.InvalidBlock;
                try context.builder.setTerminator(try context.block(predecessor), .{
                    .branch = try makeEdge(context, predecessor, operands[0]),
                });
            },
            .branch_conditional => {
                if (operands.len < 3 or operands.len > 5) return error.InvalidInstruction;
                const predecessor = current_label orelse return error.InvalidBlock;
                try context.builder.setTerminator(try context.block(predecessor), .{ .conditional_branch = .{
                    .condition = try context.resolveValue(operands[0]),
                    .true_edge = try makeEdge(context, predecessor, operands[1]),
                    .false_edge = try makeEdge(context, predecessor, operands[2]),
                } });
            },
            .return_ => {
                try expectOperandCount(operands, 0);
                try context.builder.setTerminator(try context.block(current_label orelse return error.InvalidBlock), .return_void);
            },
            .return_value => {
                try expectOperandCount(operands, 1);
                try context.builder.setTerminator(
                    try context.block(current_label orelse return error.InvalidBlock),
                    .{ .return_value = try context.resolveValue(operands[0]) },
                );
            },
            .kill => {
                try expectOperandCount(operands, 0);
                try context.builder.setTerminator(try context.block(current_label orelse return error.InvalidBlock), .discard);
            },
            .@"unreachable" => {
                try expectOperandCount(operands, 0);
                try context.builder.setTerminator(try context.block(current_label orelse return error.InvalidBlock), .@"unreachable");
            },
            .@"switch" => return error.UnsupportedOpcode,
            .function_end => break,

            else => {},
        }
    }
}

fn makeEdge(context: *Context, predecessor_label: u32, target_label: u32) !ir.module.Edge {
    var arguments: std.ArrayList(ir.id.ValueId) = .empty;
    defer arguments.deinit(context.scratch);

    for (context.phi_infos.items) |phi| {
        if (phi.target_label != target_label)
            continue;

        var incoming: ?u32 = null;
        var index: usize = 0;

        while (index < phi.incoming_words.len) : (index += 2) {
            if (phi.incoming_words[index + 1] == predecessor_label) {
                if (incoming != null)
                    return error.InvalidPhi;

                incoming = phi.incoming_words[index];
            }
        }
        try arguments.append(context.scratch, try context.resolveValue(incoming orelse return error.MissingPhiIncomingValue));
    }

    return context.builder.edge(try context.block(target_label), arguments.items);
}

fn findFunction(parser: Parser, function_id: u32) !Parser.Instruction {
    var iterator = parser.iterator();

    while (try iterator.next()) |instruction| {
        if (instruction.opcode == .function and instruction.operands.len >= 2 and instruction.operands[1] == function_id)
            return instruction;
    }

    return error.MissingFunction;
}

fn functionTypeDefinition(context: *Context, type_id: u32) !Parser.Instruction {
    const index = try context.idIndex(type_id);
    const instruction = context.type_defs[index] orelse return error.InvalidFunctionType;

    if (instruction.opcode != .type_function)
        return error.InvalidFunctionType;

    return instruction;
}

fn translateStage(model: spirv.ExecutionModel) TranslationError!ir.module.Stage {
    return switch (model) {
        .vertex => .vertex,
        .fragment => .fragment,
        .gl_compute => .compute,

        else => error.UnsupportedExecutionModel,
    };
}

fn translateStorageClass(storage_class: spirv.StorageClass) TranslationError!ir.types.AddressSpace {
    return switch (storage_class) {
        .function => .function,
        .private => .private,
        .workgroup => .workgroup,
        .input => .input,
        .output => .output,
        .uniform, .uniform_constant => .uniform,
        .storage_buffer => .storage,
        .push_constant => .push_constant,
        .physical_storage_buffer => .physical,

        else => error.UnsupportedType,
    };
}

fn translateBuiltin(builtin: u32) TranslationError!ir.module.Builtin {
    return switch (builtin) {
        0 => .position,
        15 => .frag_coord,
        22 => .frag_depth,
        28 => .global_invocation_id,
        42 => .vertex_index,
        43 => .instance_index,

        else => error.UnsupportedOpcode,
    };
}

fn translateBinaryOpcode(opcode: spirv.Opcode) ir.instruction.BinaryOpcode {
    return switch (opcode) {
        .i_add => .integer_add,
        .i_sub => .integer_subtract,
        .i_mul => .integer_multiply,
        .u_div => .unsigned_divide,
        .s_div => .signed_divide,
        .u_mod => .unsigned_modulo,
        .s_mod => .signed_modulo,
        .f_add => .float_add,
        .f_sub => .float_subtract,
        .f_mul => .float_multiply,
        .f_div => .float_divide,
        .f_mod => .float_modulo,
        .shift_left_logical => .shift_left,
        .shift_right_logical => .logical_shift_right,
        .shift_right_arithmetic => .arithmetic_shift_right,
        .bitwise_and => .bitwise_and,
        .bitwise_or => .bitwise_or,
        .bitwise_xor => .bitwise_xor,
        .logical_and => .logical_and,
        .logical_or => .logical_or,

        else => unreachable,
    };
}

fn translateCompareOpcode(opcode: spirv.Opcode) ir.instruction.CompareOpcode {
    return switch (opcode) {
        .logical_equal, .i_equal => .equal,
        .logical_not_equal, .i_not_equal => .not_equal,
        .u_less_than => .unsigned_less,
        .s_less_than => .signed_less,
        .f_ord_equal => .ordered_float_equal,
        .f_unord_equal => .unordered_float_equal,
        .f_ord_not_equal => .ordered_float_not_equal,
        .f_unord_not_equal => .unordered_float_not_equal,
        .f_ord_less_than => .ordered_float_less,
        .f_unord_less_than => .unordered_float_less,

        else => unreachable,
    };
}

fn literalBits(words: []const u32) TranslationError!u64 {
    return switch (words.len) {
        1 => words[0],
        2 => @as(u64, words[0]) | (@as(u64, words[1]) << 32),

        else => error.UnsupportedConstant,
    };
}

fn isTypeOpcode(opcode: spirv.Opcode) bool {
    return switch (opcode) {
        .type_void,
        .type_bool,
        .type_int,
        .type_float,
        .type_vector,
        .type_matrix,
        .type_image,
        .type_sampler,
        .type_sampled_image,
        .type_array,
        .type_runtime_array,
        .type_struct,
        .type_opaque,
        .type_pointer,
        .type_function,
        => true,

        else => false,
    };
}

fn isConstantOpcode(opcode: spirv.Opcode) bool {
    return switch (opcode) {
        .constant_true,
        .constant_false,
        .constant,
        .constant_composite,
        .constant_null,
        .spec_constant_true,
        .spec_constant_false,
        .spec_constant,
        .spec_constant_composite,
        .spec_constant_op,
        => true,

        else => false,
    };
}

fn expectOperandCount(operands: []const u32, expected: usize) TranslationError!void {
    if (operands.len != expected)
        return error.InvalidInstruction;
}

fn allocOptional(comptime T: type, allocator: std.mem.Allocator, count: usize) ![]?T {
    const values = try allocator.alloc(?T, count);
    @memset(values, null);
    return values;
}
