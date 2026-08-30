const std = @import("std");
const builtin_info = @import("builtin");
const Parser = @import("Parser.zig");
const SourceModule = @import("SourceModule.zig");
const spirv = @import("spirv.zig");
const ir = @import("../ir/ir.zig");

pub const SpecializationValue = struct {
    constant_id: u32,
    data: []const u8,
};

pub const Options = struct {
    entry_point: []const u8,
    stage: ?ir.module.Stage = null,
    specializations: []const SpecializationValue = &.{},
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
    InvalidSpecialization,
    DuplicateSpecializationConstant,
    UnsupportedOpcode,
};

const EntryPoint = struct {
    model: spirv.ExecutionModel,
    function_id: u32,
    interface_ids: []const u32,
};

const Decorations = struct {
    spec_id: ?u32 = null,
    location: ?u32 = null,
    component: u8 = 0,
    index: u8 = 0,
    builtin: ?u32 = null,
    binding: ?u32 = null,
    descriptor_set: ?u32 = null,
    array_stride: ?u32 = null,
    block: bool = false,
    buffer_block: bool = false,
};

const MemberOffset = struct {
    structure_id: u32,
    member: u32,
    offset: u32,
};

const BufferAddress = struct {
    resource: ir.id.ResourceId,
    byte_offset: ?ir.id.ValueId,
    pointee_type: u32,
};

const CompositeAddress = struct {
    root: union(enum) {
        local: usize,
        interface: ir.id.InterfaceVariableId,
    },
    root_type: u32,
    pointee_type: u32,
    indices: []const u32,
};

const LocalVariable = struct {
    spv_id: u32,
    type: ir.id.TypeId,
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
    specializations: []const SpecializationValue,

    types: []?ir.id.TypeId,
    values: []?ir.id.ValueId,
    blocks: []?ir.id.BlockId,
    interfaces: []?ir.id.InterfaceVariableId,
    resources: []?ir.id.ResourceId,
    buffer_addresses: []?BufferAddress,
    composite_addresses: []?CompositeAddress,
    member_offsets: std.ArrayList(MemberOffset) = .empty,
    phi_infos: std.ArrayList(PhiInfo) = .empty,

    local_indices: []?usize,
    locals: std.ArrayList(LocalVariable) = .empty,
    block_local_inputs: []?ir.id.ValueId,
    block_local_outputs: []?ir.id.ValueId,
    current_locals: []?ir.id.ValueId,
    entry_label: ?u32 = null,

    fn idIndex(self: *const Context, id: u32) TranslationError!usize {
        if (id == 0 or id >= self.bound)
            return TranslationError.InvalidId;
        return id;
    }

    fn recordDefinition(self: *Context, definitions: []?Parser.Instruction, id: u32, instruction: Parser.Instruction) TranslationError!void {
        const index = try self.idIndex(id);
        if (definitions[index] != null)
            return TranslationError.DuplicateId;
        definitions[index] = instruction;
    }

    fn nameOf(self: *const Context, id: u32) ?[]const u8 {
        const index = self.idIndex(id) catch return null;
        return self.names[index];
    }

    fn specializationData(self: *const Context, result_id: u32) TranslationError!?[]const u8 {
        const index = try self.idIndex(result_id);
        const spec_id = self.decorations[index].spec_id orelse return null;

        for (self.specializations) |specialization| {
            if (specialization.constant_id == spec_id)
                return specialization.data;
        }
        return null;
    }

    fn translateType(self: *Context, spv_id: u32) anyerror!ir.id.TypeId {
        const index = try self.idIndex(spv_id);
        if (self.types[index]) |translated|
            return translated;

        const instruction = self.type_defs[index] orelse return TranslationError.MissingDefinition;
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
                    return TranslationError.UnsupportedType;

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
                    return TranslationError.UnsupportedType;

                break :blk try self.builder.internType(.{
                    .floating = .{
                        .bits = @intCast(operands[1]),
                    },
                });
            },
            .type_vector => blk: {
                try expectOperandCount(operands, 3);

                if (operands[2] < 2 or operands[2] > std.math.maxInt(u8))
                    return TranslationError.UnsupportedType;

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
                const length_constant_value = self.module.values.get(length_value) orelse return TranslationError.InvalidId;

                if (length_constant_value.definition != .constant)
                    return TranslationError.UnsupportedType;

                const constant = self.module.constants.get(length_constant_value.definition.constant) orelse return TranslationError.InvalidId;
                if (constant.value != .integer_bits or constant.value.integer_bits == 0 or constant.value.integer_bits > std.math.maxInt(u32))
                    return TranslationError.UnsupportedType;

                break :blk try self.builder.internType(.{
                    .array = .{
                        .element_type = try self.translateType(operands[1]),
                        .length = @intCast(constant.value.integer_bits),
                    },
                });
            },
            .type_struct => blk: {
                if (operands.len == 0)
                    return TranslationError.InvalidInstruction;

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
            .type_runtime_array => blk: {
                try expectOperandCount(operands, 2);
                break :blk try self.builder.internType(.{
                    .runtime_array = .{
                        .element_type = try self.translateType(operands[1]),
                    },
                });
            },

            else => return TranslationError.UnsupportedType,
        };
        self.types[index] = translated;
        return translated;
    }

    fn translateValue(self: *Context, spv_id: u32) anyerror!ir.id.ValueId {
        const index = try self.idIndex(spv_id);

        if (self.values[index]) |translated|
            return translated;

        const instruction = self.value_defs[index] orelse return TranslationError.MissingDefinition;
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
                    return TranslationError.InvalidInstruction;

                const ty = try self.translateType(operands[0]);
                const type_data = self.module.types.get(ty) orelse return TranslationError.InvalidId;
                const bits = try literalBits(operands[2..]);

                break :blk switch (type_data.*) {
                    .integer => try self.builder.internConstant(ty, .{ .integer_bits = bits }),
                    .floating => try self.builder.internConstant(ty, .{ .float_bits = bits }),
                    else => return TranslationError.UnsupportedConstant,
                };
            },
            .constant_null => blk: {
                try expectOperandCount(operands, 2);
                break :blk try self.builder.internConstant(try self.translateType(operands[0]), .null);
            },
            .constant_composite, .spec_constant_composite => blk: {
                if (operands.len < 2)
                    return TranslationError.InvalidInstruction;

                const elements = try self.scratch.alloc(ir.id.ConstantId, operands.len - 2);

                for (operands[2..], elements) |element_id, *element| {
                    const element_value = self.module.values.get(try self.translateValue(element_id)) orelse return TranslationError.InvalidId;

                    if (element_value.definition != .constant)
                        return TranslationError.UnsupportedConstant;

                    element.* = element_value.definition.constant;
                }

                break :blk try self.builder.internConstant(
                    try self.translateType(operands[0]),
                    .{ .composite = elements },
                );
            },
            .spec_constant_true, .spec_constant_false => blk: {
                try expectOperandCount(operands, 2);
                const ty = try self.translateType(operands[0]);
                const type_data = self.module.types.get(ty) orelse return TranslationError.InvalidId;
                if (type_data.* != .boolean)
                    return TranslationError.UnsupportedConstant;

                const value = if (try self.specializationData(spv_id)) |data|
                    try specializationBoolean(data)
                else
                    instruction.opcode == .spec_constant_true;
                break :blk try self.builder.internConstant(ty, .{ .boolean = value });
            },
            .spec_constant => blk: {
                if (operands.len < 3 or operands.len > 4)
                    return TranslationError.InvalidInstruction;

                const ty = try self.translateType(operands[0]);
                const type_data = self.module.types.get(ty) orelse return TranslationError.InvalidId;
                const default_bits = try literalBits(operands[2..]);
                const override = try self.specializationData(spv_id);

                break :blk switch (type_data.*) {
                    .integer => |integer| try self.builder.internConstant(ty, .{
                        .integer_bits = if (override) |data|
                            try specializationBits(data, integer.bits)
                        else
                            default_bits,
                    }),
                    .floating => |floating| try self.builder.internConstant(ty, .{
                        .float_bits = if (override) |data|
                            try specializationBits(data, floating.bits)
                        else
                            default_bits,
                    }),
                    else => return TranslationError.UnsupportedConstant,
                };
            },
            .spec_constant_op => return TranslationError.SpecializationConstantsNotApplied,

            else => return TranslationError.MissingDefinition,
        };
        try self.builder.setValueName(translated, self.nameOf(spv_id));
        self.values[index] = translated;
        return translated;
    }

    fn setValue(self: *Context, spv_id: u32, translated_value: ir.id.ValueId) TranslationError!void {
        const index = try self.idIndex(spv_id);

        if (self.values[index] != null)
            return TranslationError.DuplicateId;

        self.values[index] = translated_value;
    }

    fn resolveValue(self: *Context, spv_id: u32) anyerror!ir.id.ValueId {
        return self.translateValue(spv_id);
    }

    fn block(self: *const Context, spv_id: u32) TranslationError!ir.id.BlockId {
        const index = try self.idIndex(spv_id);
        return self.blocks[index] orelse TranslationError.InvalidBlock;
    }

    fn interfaceVariable(self: *const Context, spv_id: u32) TranslationError!ir.id.InterfaceVariableId {
        const index = try self.idIndex(spv_id);
        return self.interfaces[index] orelse TranslationError.UnsupportedOpcode;
    }

    fn bufferAddress(self: *const Context, spv_id: u32) TranslationError!?BufferAddress {
        const index = try self.idIndex(spv_id);
        return self.buffer_addresses[index];
    }

    fn compositeAddress(self: *const Context, spv_id: u32) TranslationError!?CompositeAddress {
        const index = try self.idIndex(spv_id);
        return self.composite_addresses[index];
    }

    fn localIndex(self: *const Context, spv_id: u32) TranslationError!?usize {
        const index = try self.idIndex(spv_id);
        return self.local_indices[index];
    }

    fn blockLocalIndex(self: *const Context, label: u32, local_index: usize) TranslationError!usize {
        const label_index = try self.idIndex(label);
        const base = std.math.mul(usize, label_index, self.locals.items.len) catch return TranslationError.InvalidInstruction;
        return std.math.add(usize, base, local_index) catch return TranslationError.InvalidInstruction;
    }
};

/// Translates one entry point from a retained SPIR-V source into an independent
/// common IR module. The returned module does not borrow from `source`.
pub fn instantiate(allocator: std.mem.Allocator, source: *const SourceModule, options: Options) !ir.module.Module {
    try validateSpecializations(options.specializations);
    const parser = source.parser();
    const entry_point = try findEntryPoint(parser, options.entry_point, options.stage);
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
        .specializations = options.specializations,
        .types = try allocOptional(ir.id.TypeId, scratch, bound),
        .values = try allocOptional(ir.id.ValueId, scratch, bound),
        .blocks = try allocOptional(ir.id.BlockId, scratch, bound),
        .interfaces = try allocOptional(ir.id.InterfaceVariableId, scratch, bound),
        .resources = try allocOptional(ir.id.ResourceId, scratch, bound),
        .buffer_addresses = try allocOptional(BufferAddress, scratch, bound),
        .composite_addresses = try allocOptional(CompositeAddress, scratch, bound),
        .local_indices = try allocOptional(usize, scratch, bound),
        .block_local_inputs = try allocOptional(ir.id.ValueId, scratch, 0),
        .block_local_outputs = try allocOptional(ir.id.ValueId, scratch, 0),
        .current_locals = try allocOptional(ir.id.ValueId, scratch, 0),
    };
    @memset(context.decorations, .{});
    defer context.member_offsets.deinit(scratch);
    defer context.phi_infos.deinit(scratch);
    defer context.locals.deinit(scratch);

    try collectDeclarations(&context);
    try translateInterfaces(&context, entry_point.interface_ids);
    try translateResources(&context);
    try applyExecutionModes(&context, entry_point.function_id);
    try translateFunction(&context, entry_point.function_id, options.entry_point);
    try ir.validator.validate(&module);
    module.properties.valid_cfg = true;
    module.properties.valid_ssa = true;
    module.properties.structured_control_flow = true;
    module.properties.no_function_calls = true;
    return module;
}

/// Convenience wrapper for callers that do not retain a source module.
pub fn translate(allocator: std.mem.Allocator, words: []const u32, options: Options) !ir.module.Module {
    var source = try SourceModule.init(allocator, words);
    defer source.deinit(allocator);
    return instantiate(allocator, &source, options);
}

fn collectDeclarations(context: *Context) !void {
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        const operands = instruction.operands;
        if (isTypeOpcode(instruction.opcode)) {
            if (operands.len == 0)
                return TranslationError.InvalidInstruction;

            try context.recordDefinition(context.type_defs, operands[0], instruction);
            continue;
        }
        if (isConstantOpcode(instruction.opcode) or instruction.opcode == .undef) {
            if (operands.len < 2)
                return TranslationError.InvalidInstruction;

            try context.recordDefinition(context.value_defs, operands[1], instruction);
            continue;
        }
        if (instruction.opcode == .name) {
            if (operands.len < 2)
                return TranslationError.InvalidInstruction;

            const index = try context.idIndex(operands[0]);
            context.names[index] = try Parser.copyLiteralString(context.scratch, operands[1..]);
            continue;
        }
        if (instruction.opcode == .variable) {
            if (operands.len < 3)
                return TranslationError.InvalidInstruction;

            try context.recordDefinition(context.variable_defs, operands[1], instruction);
            continue;
        }
        if (instruction.opcode == .decorate) {
            try collectDecoration(context, operands);
            continue;
        }
        if (instruction.opcode == .member_decorate) {
            try collectMemberDecoration(context, operands);
        }
    }
}

fn collectDecoration(context: *Context, operands: []const u32) !void {
    if (operands.len < 2) return TranslationError.InvalidInstruction;
    const index = try context.idIndex(operands[0]);
    const decoration: spirv.Decoration = @enumFromInt(operands[1]);
    switch (decoration) {
        .spec_id => {
            try expectOperandCount(operands, 3);
            if (context.decorations[index].spec_id != null)
                return TranslationError.InvalidInstruction;
            context.decorations[index].spec_id = operands[2];
        },
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
            if (operands[2] > std.math.maxInt(u8)) return TranslationError.InvalidInstruction;
            context.decorations[index].component = @intCast(operands[2]);
        },
        .index => {
            try expectOperandCount(operands, 3);
            if (operands[2] > std.math.maxInt(u8)) return TranslationError.InvalidInstruction;
            context.decorations[index].index = @intCast(operands[2]);
        },
        .binding => {
            try expectOperandCount(operands, 3);
            context.decorations[index].binding = operands[2];
        },
        .descriptor_set => {
            try expectOperandCount(operands, 3);
            context.decorations[index].descriptor_set = operands[2];
        },
        .array_stride => {
            try expectOperandCount(operands, 3);
            context.decorations[index].array_stride = operands[2];
        },
        .block => {
            try expectOperandCount(operands, 2);
            context.decorations[index].block = true;
        },
        .buffer_block => {
            try expectOperandCount(operands, 2);
            context.decorations[index].buffer_block = true;
        },
        else => {},
    }
}

fn collectMemberDecoration(context: *Context, operands: []const u32) !void {
    if (operands.len < 3)
        return TranslationError.InvalidInstruction;

    const decoration: spirv.Decoration = @enumFromInt(operands[2]);
    if (decoration != .offset)
        return;

    try expectOperandCount(operands, 4);
    _ = try context.idIndex(operands[0]);
    try context.member_offsets.append(context.scratch, .{
        .structure_id = operands[0],
        .member = operands[1],
        .offset = operands[3],
    });
}

fn translateInterfaces(context: *Context, interface_ids: []const u32) !void {
    for (interface_ids) |spv_id| {
        const index = try context.idIndex(spv_id);
        const variable = context.variable_defs[index] orelse return TranslationError.MissingDefinition;

        if (variable.operands.len < 3 or variable.operands.len > 4)
            return TranslationError.InvalidInstruction;

        const storage_class: spirv.StorageClass = @enumFromInt(variable.operands[2]);
        const direction: ir.module.InterfaceDirection = switch (storage_class) {
            .input => .input,
            .output => .output,
            else => continue,
        };

        const pointer_index = try context.idIndex(variable.operands[0]);
        const pointer = context.type_defs[pointer_index] orelse return TranslationError.MissingDefinition;

        if (pointer.opcode != .type_pointer)
            return TranslationError.InvalidInstruction;

        try expectOperandCount(pointer.operands, 3);

        if (pointer.operands[1] != variable.operands[2])
            return TranslationError.InvalidInstruction;

        const decoration = context.decorations[index];

        if (decoration.location != null and decoration.builtin != null)
            return TranslationError.InvalidInstruction;

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
                .builtin = try translateBuiltin(std.enums.fromInt(spirv.Builtin, builtin) orelse return TranslationError.UnsupportedOpcode),
            }
        else
            return TranslationError.InvalidInstruction;

        context.interfaces[index] = try context.builder.addInterfaceVariable(
            try context.translateType(pointer.operands[2]),
            direction,
            semantic,
            context.nameOf(spv_id),
        );
    }
}

fn translateResources(context: *Context) !void {
    for (context.variable_defs, 0..) |optional_variable, spv_index| {
        const variable = optional_variable orelse continue;
        if (variable.operands.len < 3 or variable.operands.len > 4)
            return TranslationError.InvalidInstruction;

        const storage_class: spirv.StorageClass = @enumFromInt(variable.operands[2]);
        if (storage_class != .uniform and storage_class != .storage_buffer)
            continue;

        const pointer = context.type_defs[try context.idIndex(variable.operands[0])] orelse return TranslationError.MissingDefinition;
        if (pointer.opcode != .type_pointer)
            return TranslationError.InvalidInstruction;
        try expectOperandCount(pointer.operands, 3);
        if (pointer.operands[1] != variable.operands[2])
            return TranslationError.InvalidInstruction;

        const pointee_id = pointer.operands[2];
        const pointee_decoration = context.decorations[try context.idIndex(pointee_id)];
        const kind: ir.types.ResourceKind = if (storage_class == .storage_buffer or pointee_decoration.buffer_block)
            .storage_buffer
        else if (pointee_decoration.block)
            .uniform_buffer
        else
            continue;

        const variable_decoration = context.decorations[spv_index];
        const resource = try context.builder.addResource(
            try context.translateType(pointee_id),
            kind,
            variable_decoration.descriptor_set orelse return TranslationError.InvalidInstruction,
            variable_decoration.binding orelse return TranslationError.InvalidInstruction,
            context.nameOf(@intCast(spv_index)),
        );
        context.resources[spv_index] = resource;
        context.buffer_addresses[spv_index] = .{
            .resource = resource,
            .byte_offset = null,
            .pointee_type = pointee_id,
        };
    }

    if (context.module.resources.entries.items.len != 0)
        context.module.properties.explicit_resource_offsets = true;
}

fn findEntryPoint(parser: Parser, requested_name: []const u8, requested_stage: ?ir.module.Stage) !EntryPoint {
    var found: ?EntryPoint = null;
    var iterator = parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode != .entry_point)
            continue;

        if (instruction.operands.len < 3)
            return TranslationError.InvalidInstruction;

        const string_words = try Parser.literalStringWordCount(instruction.operands[2..]);

        if (2 + string_words > instruction.operands.len)
            return TranslationError.InvalidInstruction;

        if (!try Parser.literalStringEquals(instruction.operands[2 .. 2 + string_words], requested_name))
            continue;

        const model: spirv.ExecutionModel = @enumFromInt(instruction.operands[0]);
        if (requested_stage) |stage| {
            const candidate_stage = translateStage(model) catch |err| switch (err) {
                TranslationError.UnsupportedExecutionModel => continue,
                else => return err,
            };
            if (candidate_stage != stage)
                continue;
        }

        if (found != null)
            return TranslationError.AmbiguousEntryPoint;

        found = .{
            .model = model,
            .function_id = instruction.operands[1],
            .interface_ids = instruction.operands[2 + string_words ..],
        };
    }
    return found orelse TranslationError.EntryPointNotFound;
}

fn applyExecutionModes(context: *Context, entry_function: u32) !void {
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode != .execution_mode)
            continue;

        if (instruction.operands.len < 2)
            return TranslationError.InvalidInstruction;

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
        return TranslationError.InvalidFunctionType;

    const function = try context.builder.addFunction(
        try context.translateType(function_instruction.operands[0]),
        context.nameOf(spv_function) orelse entry_name,
    );
    context.builder.setEntryPoint(function);

    try collectFunctionLocals(context, spv_function);
    try predeclareFunction(context, spv_function, function, function_type.operands[2..]);
    try translateFunctionInstructions(context, spv_function);
    try translateFunctionControlFlow(context, spv_function);
}

fn collectFunctionLocals(context: *Context, spv_function: u32) !void {
    var active = false;
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode == .function) {
            active = instruction.operands.len >= 2 and instruction.operands[1] == spv_function;
            continue;
        }
        if (!active)
            continue;
        if (instruction.opcode == .function_end)
            break;
        if (instruction.opcode != .variable)
            continue;

        try expectOperandCount(instruction.operands, 3);
        const storage_class: spirv.StorageClass = @enumFromInt(instruction.operands[2]);
        if (storage_class != .function)
            return TranslationError.UnsupportedOpcode;

        const pointer = context.type_defs[try context.idIndex(instruction.operands[0])] orelse return TranslationError.MissingDefinition;
        if (pointer.opcode != .type_pointer)
            return TranslationError.InvalidInstruction;
        try expectOperandCount(pointer.operands, 3);
        if (pointer.operands[1] != instruction.operands[2])
            return TranslationError.InvalidInstruction;

        const result_id = instruction.operands[1];
        const result_index = try context.idIndex(result_id);
        if (context.local_indices[result_index] != null)
            return TranslationError.DuplicateId;

        context.local_indices[result_index] = context.locals.items.len;
        try context.locals.append(context.scratch, .{
            .spv_id = result_id,
            .type = try context.translateType(pointer.operands[2]),
        });
    }

    const matrix_len = std.math.mul(usize, context.bound, context.locals.items.len) catch return TranslationError.InvalidInstruction;
    context.block_local_inputs = try allocOptional(ir.id.ValueId, context.scratch, matrix_len);
    context.block_local_outputs = try allocOptional(ir.id.ValueId, context.scratch, matrix_len);
    context.current_locals = try allocOptional(ir.id.ValueId, context.scratch, context.locals.items.len);
    context.module.properties.no_local_memory = true;
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
                    return TranslationError.InvalidFunctionParameter;

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
                    return TranslationError.DuplicateId;

                context.blocks[index] = try context.builder.addBlock(function, context.nameOf(label_id));
                if (context.entry_label == null) {
                    context.entry_label = label_id;
                } else {
                    for (context.locals.items, 0..) |local, local_index| {
                        const value = try context.builder.addBlockParameter(
                            context.blocks[index].?,
                            local.type,
                            context.nameOf(local.spv_id),
                        );
                        context.block_local_inputs[try context.blockLocalIndex(label_id, local_index)] = value;
                    }
                }
                current_label = label_id;
            },
            .phi => {
                if (instruction.operands.len < 4 or (instruction.operands.len - 2) % 2 != 0)
                    return TranslationError.InvalidPhi;

                const label = current_label orelse return TranslationError.InvalidPhi;
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
        return TranslationError.InvalidFunctionParameter;
}

fn translateFunctionInstructions(context: *Context, spv_function: u32) !void {
    var active = false;
    var current_label: ?u32 = null;
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
            .label => {
                try expectOperandCount(instruction.operands, 1);
                if (current_label) |label|
                    try saveBlockLocals(context, label);

                const label = instruction.operands[0];
                current_label = label;
                current_block = try context.block(label);
                for (context.current_locals, 0..) |*current, local_index| {
                    current.* = if (label == context.entry_label.?)
                        null
                    else
                        context.block_local_inputs[try context.blockLocalIndex(label, local_index)];
                }
            },

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

            .function_end => {
                if (current_label) |label|
                    try saveBlockLocals(context, label);
                break;
            },

            .variable => {},

            .nop,
            .line,
            .no_line,
            => {},

            else => try translateInstruction(context, current_block orelse return TranslationError.InvalidBlock, instruction),
        }
    }
}

fn saveBlockLocals(context: *Context, label: u32) !void {
    for (context.current_locals, 0..) |value, local_index|
        context.block_local_outputs[try context.blockLocalIndex(label, local_index)] = value;
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
                return TranslationError.InvalidInstruction;

            try context.setValue(operands[1], source);
        },
        .load => {
            if (operands.len < 3)
                return TranslationError.InvalidInstruction;

            const result_type = try context.translateType(operands[0]);
            if (try context.localIndex(operands[2])) |local_index| {
                const value = context.current_locals[local_index] orelse return TranslationError.InvalidInstruction;
                if (context.module.typeOf(value) != result_type)
                    return TranslationError.InvalidInstruction;
                try context.setValue(operands[1], value);
            } else if (try context.bufferAddress(operands[2])) |address| {
                const result = (try context.builder.appendInstruction(block, result_type, .{
                    .load_buffer = .{
                        .resource = address.resource,
                        .byte_offset = try bufferByteOffset(context, address),
                    },
                }, context.nameOf(operands[1]))).?;
                try context.setValue(operands[1], result);
            } else if (try context.compositeAddress(operands[2])) |address| {
                const composite = switch (address.root) {
                    .local => |local_index| context.current_locals[local_index] orelse return TranslationError.InvalidInstruction,
                    .interface => |variable| (try context.builder.appendInstruction(
                        block,
                        try context.translateType(address.root_type),
                        .{ .load_interface = .{ .variable = variable } },
                        null,
                    )).?,
                };
                const result = (try context.builder.appendInstruction(block, result_type, .{
                    .composite_extract = .{
                        .composite = composite,
                        .indices = address.indices,
                    },
                }, context.nameOf(operands[1]))).?;
                try context.setValue(operands[1], result);
            } else {
                const result = (try context.builder.appendInstruction(block, result_type, .{
                    .load_interface = .{ .variable = try context.interfaceVariable(operands[2]) },
                }, context.nameOf(operands[1]))).?;
                try context.setValue(operands[1], result);
            }
        },
        .store => {
            if (operands.len < 2)
                return TranslationError.InvalidInstruction;

            const value = try context.resolveValue(operands[1]);
            if (try context.localIndex(operands[0])) |local_index| {
                if (context.module.typeOf(value) != context.locals.items[local_index].type)
                    return TranslationError.InvalidInstruction;
                context.current_locals[local_index] = value;
            } else if (try context.bufferAddress(operands[0])) |address| {
                _ = try context.builder.appendInstruction(block, null, .{
                    .store_buffer = .{
                        .resource = address.resource,
                        .byte_offset = try bufferByteOffset(context, address),
                        .value = value,
                    },
                }, null);
            } else if (try context.compositeAddress(operands[0]) != null) {
                return TranslationError.UnsupportedOpcode;
            } else {
                _ = try context.builder.appendInstruction(block, null, .{
                    .store_interface = .{
                        .variable = try context.interfaceVariable(operands[0]),
                        .value = value,
                    },
                }, null);
            }
        },
        .access_chain => try translateAccessChain(context, block, operands),
        .s_negate,
        .f_negate,
        .logical_not,
        .not,
        => {
            try expectOperandCount(operands, 3);

            const opcode: ir.instruction.UnaryOpcode = switch (instruction.opcode) {
                .s_negate,
                .f_negate,
                => .negate,

                .logical_not => .logical_not,
                .not => .bitwise_not,

                else => unreachable,
            };

            const result = (try context.builder.appendInstruction(
                block,
                try context.translateType(operands[0]),
                .{
                    .unary = .{
                        .opcode = opcode,
                        .operand = try context.resolveValue(operands[2]),
                    },
                },
                context.nameOf(operands[1]),
            )).?;

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

            const result_type = try context.translateType(operands[0]);
            const result = (try context.builder.appendInstruction(block, result_type, .{
                .binary = .{
                    .opcode = translateBinaryOpcode(instruction.opcode),
                    .lhs = try coerceIntegerSignedness(context, block, try context.resolveValue(operands[2]), result_type),
                    .rhs = try coerceIntegerSignedness(context, block, try context.resolveValue(operands[3]), result_type),
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
                return TranslationError.InvalidInstruction;

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
                return TranslationError.InvalidInstruction;

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .composite_extract = .{
                    .composite = try context.resolveValue(operands[2]),
                    .indices = operands[3..],
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },
        .function_call => return TranslationError.UnsupportedOpcode,
        .array_length => try translateArrayLength(context, block, operands),

        else => {
            if (std.enums.tagName(spirv.Opcode, instruction.opcode)) |opcode| {
                std.log.scoped(.spirv_translator).err("unsupported opcode: '{s}'", .{opcode});
            } else {
                std.log.scoped(.spirv_translator).err("unsupported opcode: {d}", .{instruction.opcode});
            }
            return TranslationError.UnsupportedOpcode;
        },
    }
}

fn translateAccessChain(context: *Context, block: ir.id.BlockId, operands: []const u32) !void {
    if (operands.len < 4)
        return TranslationError.InvalidInstruction;

    if (try context.bufferAddress(operands[2])) |base|
        return translateBufferAccessChain(context, block, operands, base);

    try translateCompositeAccessChain(context, operands);
}

fn translateBufferAccessChain(context: *Context, block: ir.id.BlockId, operands: []const u32, base: BufferAddress) !void {
    var current_type = base.pointee_type;
    var byte_offset = base.byte_offset;

    for (operands[3..]) |index_id| {
        const type_definition = context.type_defs[try context.idIndex(current_type)] orelse return TranslationError.MissingDefinition;
        switch (type_definition.opcode) {
            .type_struct => {
                const member = try constantIndex(context, index_id);
                if (member + 1 >= type_definition.operands.len)
                    return TranslationError.InvalidInstruction;

                const member_offset = try findMemberOffset(context, current_type, member);
                if (member_offset != 0) {
                    const offset_value = try context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = member_offset });
                    byte_offset = try addByteOffset(context, block, byte_offset, offset_value);
                }
                current_type = type_definition.operands[member + 1];
            },
            .type_array, .type_runtime_array => {
                try expectOperandCount(type_definition.operands, if (type_definition.opcode == .type_array) 3 else 2);
                const stride = context.decorations[try context.idIndex(current_type)].array_stride orelse return TranslationError.InvalidInstruction;
                const index = try unsignedOffsetValue(context, block, index_id);
                const stride_value = try context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = stride });
                const term = (try context.builder.appendInstruction(block, try unsigned32Type(context), .{
                    .binary = .{
                        .opcode = .integer_multiply,
                        .lhs = index,
                        .rhs = stride_value,
                    },
                }, null)).?;
                byte_offset = try addByteOffset(context, block, byte_offset, term);
                current_type = type_definition.operands[1];
            },
            else => return TranslationError.UnsupportedType,
        }
    }

    const result_pointer = context.type_defs[try context.idIndex(operands[0])] orelse return TranslationError.MissingDefinition;
    if (result_pointer.opcode != .type_pointer)
        return TranslationError.InvalidInstruction;
    try expectOperandCount(result_pointer.operands, 3);
    if (result_pointer.operands[2] != current_type)
        return TranslationError.InvalidInstruction;

    const result_index = try context.idIndex(operands[1]);
    if (context.buffer_addresses[result_index] != null)
        return TranslationError.DuplicateId;
    context.buffer_addresses[result_index] = .{
        .resource = base.resource,
        .byte_offset = byte_offset,
        .pointee_type = current_type,
    };
}

fn translateCompositeAccessChain(context: *Context, operands: []const u32) !void {
    var address: CompositeAddress = if (try context.compositeAddress(operands[2])) |base|
        base
    else if (try context.localIndex(operands[2])) |local_index| blk: {
        const pointee_type = try variablePointeeType(context, operands[2]);
        break :blk .{
            .root = .{ .local = local_index },
            .root_type = pointee_type,
            .pointee_type = pointee_type,
            .indices = &.{},
        };
    } else blk: {
        const pointee_type = try variablePointeeType(context, operands[2]);
        break :blk .{
            .root = .{ .interface = try context.interfaceVariable(operands[2]) },
            .root_type = pointee_type,
            .pointee_type = pointee_type,
            .indices = &.{},
        };
    };

    var indices = std.ArrayList(u32).empty;
    defer indices.deinit(context.scratch);
    try indices.appendSlice(context.scratch, address.indices);

    for (operands[3..]) |index_id| {
        const type_definition = context.type_defs[try context.idIndex(address.pointee_type)] orelse return TranslationError.MissingDefinition;
        const index = try constantIndex(context, index_id);
        address.pointee_type = switch (type_definition.opcode) {
            .type_struct => blk: {
                if (index + 1 >= type_definition.operands.len)
                    return TranslationError.InvalidInstruction;
                break :blk type_definition.operands[index + 1];
            },
            .type_vector, .type_matrix => blk: {
                try expectOperandCount(type_definition.operands, 3);
                if (index >= type_definition.operands[2])
                    return TranslationError.InvalidInstruction;
                break :blk type_definition.operands[1];
            },
            .type_array => blk: {
                try expectOperandCount(type_definition.operands, 3);
                const length = try constantIndex(context, type_definition.operands[2]);
                if (index >= length)
                    return TranslationError.InvalidInstruction;
                break :blk type_definition.operands[1];
            },
            else => return TranslationError.UnsupportedType,
        };
        try indices.append(context.scratch, index);
    }

    const result_pointer = context.type_defs[try context.idIndex(operands[0])] orelse return TranslationError.MissingDefinition;
    if (result_pointer.opcode != .type_pointer)
        return TranslationError.InvalidInstruction;
    try expectOperandCount(result_pointer.operands, 3);
    if (result_pointer.operands[2] != address.pointee_type)
        return TranslationError.InvalidInstruction;

    const result_index = try context.idIndex(operands[1]);
    if (context.composite_addresses[result_index] != null)
        return TranslationError.DuplicateId;
    address.indices = try context.scratch.dupe(u32, indices.items);
    context.composite_addresses[result_index] = address;
}

fn variablePointeeType(context: *Context, spv_id: u32) !u32 {
    const variable = context.variable_defs[try context.idIndex(spv_id)] orelse return TranslationError.MissingDefinition;
    const pointer = context.type_defs[try context.idIndex(variable.operands[0])] orelse return TranslationError.MissingDefinition;
    if (pointer.opcode != .type_pointer)
        return TranslationError.InvalidInstruction;
    try expectOperandCount(pointer.operands, 3);
    return pointer.operands[2];
}

fn translateArrayLength(context: *Context, block: ir.id.BlockId, operands: []const u32) !void {
    try expectOperandCount(operands, 4);

    const address = (try context.bufferAddress(operands[2])) orelse return TranslationError.UnsupportedOpcode;

    const structure_index = try context.idIndex(address.pointee_type);
    const structure = context.type_defs[structure_index] orelse return TranslationError.MissingDefinition;

    if (structure.opcode != .type_struct)
        return TranslationError.InvalidInstruction;

    const member_index: usize = @intCast(operands[3]);

    if (structure.operands.len < 2 or member_index != structure.operands.len - 2)
        return TranslationError.InvalidInstruction;

    const runtime_array_id =
        structure.operands[member_index + 1];

    const runtime_array_index =
        try context.idIndex(runtime_array_id);

    const runtime_array =
        context.type_defs[runtime_array_index] orelse return TranslationError.MissingDefinition;

    if (runtime_array.opcode != .type_runtime_array)
        return TranslationError.InvalidInstruction;

    const stride =
        context.decorations[runtime_array_index].array_stride orelse return TranslationError.InvalidInstruction;

    if (stride == 0)
        return TranslationError.InvalidInstruction;

    const member_offset = try findMemberOffset(
        context,
        address.pointee_type,
        operands[3],
    );

    var byte_offset = address.byte_offset;

    if (member_offset != 0) {
        const offset_value = try context.builder.internConstant(
            try unsigned32Type(context),
            .{ .integer_bits = member_offset },
        );

        byte_offset = try addByteOffset(
            context,
            block,
            byte_offset,
            offset_value,
        );
    }

    const result_type = try context.translateType(operands[0]);

    const result = (try context.builder.appendInstruction(
        block,
        result_type,
        .{
            .array_length = .{
                .resource = address.resource,
                .byte_offset = try bufferByteOffset(
                    context,
                    .{
                        .resource = address.resource,
                        .byte_offset = byte_offset,
                        .pointee_type = runtime_array_id,
                    },
                ),
                .stride = stride,
            },
        },
        context.nameOf(operands[1]),
    )).?;

    try context.setValue(operands[1], result);
}

fn unsigned32Type(context: *Context) !ir.id.TypeId {
    return context.builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
}

fn coerceIntegerSignedness(context: *Context, block: ir.id.BlockId, value: ir.id.ValueId, target_type: ir.id.TypeId) !ir.id.ValueId {
    const source_type = context.module.typeOf(value) orelse return TranslationError.InvalidId;
    if (source_type == target_type)
        return value;

    const source_shape = integerTypeShape(context, source_type) orelse return TranslationError.InvalidInstruction;
    const target_shape = integerTypeShape(context, target_type) orelse return TranslationError.InvalidInstruction;
    if (!std.meta.eql(source_shape, target_shape))
        return TranslationError.InvalidInstruction;

    return (try context.builder.appendInstruction(block, target_type, .{ .bitcast = value }, null)).?;
}

const IntegerTypeShape = struct {
    bits: u16,
    components: u8,
};

fn integerTypeShape(context: *const Context, type_id: ir.id.TypeId) ?IntegerTypeShape {
    const ty = context.module.types.get(type_id) orelse return null;
    return switch (ty.*) {
        .integer => |integer| .{ .bits = integer.bits, .components = 1 },
        .vector => |vector| blk: {
            const element_type = context.module.types.get(vector.element_type) orelse return null;
            const integer = switch (element_type.*) {
                .integer => |integer| integer,
                else => return null,
            };
            break :blk .{ .bits = integer.bits, .components = vector.length };
        },
        else => null,
    };
}

fn unsignedOffsetValue(context: *Context, block: ir.id.BlockId, spv_id: u32) !ir.id.ValueId {
    const value = try context.resolveValue(spv_id);
    const type_id = context.module.typeOf(value) orelse return TranslationError.InvalidId;
    const ty = context.module.types.get(type_id) orelse return TranslationError.InvalidId;
    const integer = switch (ty.*) {
        .integer => |integer| integer,
        else => return TranslationError.UnsupportedType,
    };
    if (integer.bits != 32)
        return TranslationError.UnsupportedType;
    if (integer.signedness == .unsigned)
        return value;

    return (try context.builder.appendInstruction(block, try unsigned32Type(context), .{
        .bitcast = value,
    }, null)).?;
}

fn addByteOffset(context: *Context, block: ir.id.BlockId, current: ?ir.id.ValueId, term: ir.id.ValueId) !ir.id.ValueId {
    const lhs = current orelse return term;
    return (try context.builder.appendInstruction(block, try unsigned32Type(context), .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = lhs,
            .rhs = term,
        },
    }, null)).?;
}

fn bufferByteOffset(context: *Context, address: BufferAddress) !ir.id.ValueId {
    return address.byte_offset orelse context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = 0 });
}

fn constantIndex(context: *Context, spv_id: u32) !u32 {
    const value = context.module.values.get(try context.resolveValue(spv_id)) orelse return TranslationError.InvalidId;
    if (value.definition != .constant)
        return TranslationError.InvalidInstruction;
    const constant = context.module.constants.get(value.definition.constant) orelse return TranslationError.InvalidId;
    if (constant.value != .integer_bits or constant.value.integer_bits > std.math.maxInt(u32))
        return TranslationError.InvalidInstruction;
    return @intCast(constant.value.integer_bits);
}

fn findMemberOffset(context: *const Context, structure_id: u32, member: u32) !u32 {
    var found: ?u32 = null;
    for (context.member_offsets.items) |entry| {
        if (entry.structure_id != structure_id or entry.member != member)
            continue;
        if (found != null)
            return TranslationError.InvalidInstruction;
        found = entry.offset;
    }
    return found orelse TranslationError.InvalidInstruction;
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
                const block = context.module.blocks.getMut(try context.block(current_label orelse return TranslationError.InvalidBlock)).?;
                block.structured_control = .{
                    .selection = .{
                        .merge_block = try context.block(operands[0]),
                    },
                };
            },
            .loop_merge => {
                try expectOperandCount(operands, 3);
                const block = context.module.blocks.getMut(try context.block(current_label orelse return TranslationError.InvalidBlock)).?;
                block.structured_control = .{
                    .loop = .{
                        .merge_block = try context.block(operands[0]),
                        .continue_block = try context.block(operands[1]),
                    },
                };
            },
            .branch => {
                try expectOperandCount(operands, 1);
                const predecessor = current_label orelse return TranslationError.InvalidBlock;
                try context.builder.setTerminator(try context.block(predecessor), .{
                    .branch = try makeEdge(context, predecessor, operands[0]),
                });
            },
            .branch_conditional => {
                if (operands.len < 3 or operands.len > 5) return TranslationError.InvalidInstruction;
                const predecessor = current_label orelse return TranslationError.InvalidBlock;
                try context.builder.setTerminator(try context.block(predecessor), .{ .conditional_branch = .{
                    .condition = try context.resolveValue(operands[0]),
                    .true_edge = try makeEdge(context, predecessor, operands[1]),
                    .false_edge = try makeEdge(context, predecessor, operands[2]),
                } });
            },
            .return_ => {
                try expectOperandCount(operands, 0);
                try context.builder.setTerminator(try context.block(current_label orelse return TranslationError.InvalidBlock), .return_void);
            },
            .return_value => {
                try expectOperandCount(operands, 1);
                try context.builder.setTerminator(
                    try context.block(current_label orelse return TranslationError.InvalidBlock),
                    .{ .return_value = try context.resolveValue(operands[0]) },
                );
            },
            .kill => {
                try expectOperandCount(operands, 0);
                try context.builder.setTerminator(try context.block(current_label orelse return TranslationError.InvalidBlock), .discard);
            },
            .@"unreachable" => {
                try expectOperandCount(operands, 0);
                try context.builder.setTerminator(try context.block(current_label orelse return TranslationError.InvalidBlock), .@"unreachable");
            },
            .@"switch" => return TranslationError.UnsupportedOpcode,
            .function_end => break,

            else => {},
        }
    }
}

fn makeEdge(context: *Context, predecessor_label: u32, target_label: u32) !ir.module.Edge {
    var arguments: std.ArrayList(ir.id.ValueId) = .empty;
    defer arguments.deinit(context.scratch);

    if (target_label != context.entry_label.?) {
        for (context.locals.items, 0..) |_, local_index| {
            const value = context.block_local_outputs[try context.blockLocalIndex(predecessor_label, local_index)] orelse return TranslationError.InvalidInstruction;
            try arguments.append(context.scratch, value);
        }
    }

    for (context.phi_infos.items) |phi| {
        if (phi.target_label != target_label)
            continue;

        var incoming: ?u32 = null;
        var index: usize = 0;

        while (index < phi.incoming_words.len) : (index += 2) {
            if (phi.incoming_words[index + 1] == predecessor_label) {
                if (incoming != null)
                    return TranslationError.InvalidPhi;

                incoming = phi.incoming_words[index];
            }
        }
        try arguments.append(context.scratch, try context.resolveValue(incoming orelse return TranslationError.MissingPhiIncomingValue));
    }

    return context.builder.edge(try context.block(target_label), arguments.items);
}

fn findFunction(parser: Parser, function_id: u32) !Parser.Instruction {
    var iterator = parser.iterator();

    while (try iterator.next()) |instruction| {
        if (instruction.opcode == .function and instruction.operands.len >= 2 and instruction.operands[1] == function_id)
            return instruction;
    }

    return TranslationError.MissingFunction;
}

fn functionTypeDefinition(context: *Context, type_id: u32) !Parser.Instruction {
    const index = try context.idIndex(type_id);
    const instruction = context.type_defs[index] orelse return TranslationError.InvalidFunctionType;

    if (instruction.opcode != .type_function)
        return TranslationError.InvalidFunctionType;

    return instruction;
}

fn translateStage(model: spirv.ExecutionModel) TranslationError!ir.module.Stage {
    return switch (model) {
        .vertex => .vertex,
        .fragment => .fragment,
        .gl_compute => .compute,

        else => TranslationError.UnsupportedExecutionModel,
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

        else => TranslationError.UnsupportedType,
    };
}

fn translateBuiltin(builtin: spirv.Builtin) TranslationError!ir.module.Builtin {
    return switch (builtin) {
        .position => .position,
        .frag_coord => .frag_coord,
        .frag_depth => .frag_depth,
        .global_invocation_id => .global_invocation_id,
        .workgroup_size => .workgroup_size,
        .num_workgroups => .num_workgroups,
        .vertex_index => .vertex_index,
        .instance_index => .instance_index,

        else => TranslationError.UnsupportedOpcode,
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

fn validateSpecializations(specializations: []const SpecializationValue) TranslationError!void {
    for (specializations, 0..) |specialization, index| {
        for (specializations[0..index]) |previous| {
            if (previous.constant_id == specialization.constant_id)
                return TranslationError.DuplicateSpecializationConstant;
        }
    }
}

fn specializationBoolean(data: []const u8) TranslationError!bool {
    if (data.len != @sizeOf(u32))
        return TranslationError.InvalidSpecialization;
    return std.mem.readInt(u32, data[0..4], builtin_info.target.cpu.arch.endian()) != 0;
}

fn specializationBits(data: []const u8, bit_width: u16) TranslationError!u64 {
    const expected_size: usize = (@as(usize, bit_width) + 7) / 8;
    if (data.len != expected_size)
        return TranslationError.InvalidSpecialization;

    return switch (expected_size) {
        1 => data[0],
        2 => std.mem.readInt(u16, data[0..2], builtin_info.target.cpu.arch.endian()),
        4 => std.mem.readInt(u32, data[0..4], builtin_info.target.cpu.arch.endian()),
        8 => std.mem.readInt(u64, data[0..8], builtin_info.target.cpu.arch.endian()),
        else => TranslationError.InvalidSpecialization,
    };
}

fn literalBits(words: []const u32) TranslationError!u64 {
    return switch (words.len) {
        1 => words[0],
        2 => @as(u64, words[0]) | (@as(u64, words[1]) << 32),

        else => TranslationError.UnsupportedConstant,
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
        return TranslationError.InvalidInstruction;
}

fn allocOptional(comptime T: type, allocator: std.mem.Allocator, count: usize) ![]?T {
    const values = try allocator.alloc(?T, count);
    @memset(values, null);
    return values;
}

test "SPIR-V: structured branches and OpPhi to block parameters" {
    const assembly =
        \\ OpCapability Shader
        \\ OpMemoryModel Logical GLSL450
        \\ OpEntryPoint GLCompute %main "main"
        \\ OpExecutionMode %main LocalSize 1 1 1
        \\ OpName %main "main"
        \\ OpName %entry "entry"
        \\ OpName %true "true"
        \\ OpName %one "one"
        \\ OpName %then "then"
        \\ OpName %then_value "then_value"
        \\ OpName %else "else"
        \\ OpName %else_value "else_value"
        \\ OpName %merge "merge"
        \\ OpName %merged "merged"
        \\ OpName %product "product"
        \\
        \\ %void = OpTypeVoid
        \\ %bool = OpTypeBool
        \\ %uint = OpTypeInt 32 0
        \\ %fn_void = OpTypeFunction %void
        \\ %true = OpConstantTrue %bool
        \\ %one = OpConstant %uint 1
        \\
        \\ %main = OpFunction %void None %fn_void
        \\     %entry = OpLabel
        \\     OpSelectionMerge %merge None
        \\     OpBranchConditional %true %then %else
        \\     %then = OpLabel
        \\     %then_value = OpIAdd %uint %one %one
        \\     OpBranch %merge
        \\     %else = OpLabel
        \\     %else_value = OpISub %uint %one %one
        \\     OpBranch %merge
        \\     %merge = OpLabel
        \\     %merged = OpPhi %uint %then_value %then %else_value %else
        \\     %product = OpIMul %uint %merged %one
        \\     OpReturn
        \\ OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    try std.testing.expectEqual(ir.module.Stage.compute, module.stage);
    try std.testing.expectEqual([3]u32{ 1, 1, 1 }, module.execution_modes.workgroup_size.?);
    try std.testing.expect(module.properties.valid_cfg);
    try std.testing.expect(module.properties.valid_ssa);

    const function = module.functions.get(module.entry_point.?).?;
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);
    const entry = module.blocks.get(function.blocks.items[0]).?;
    try std.testing.expect(entry.structured_control == .selection);
    const merge = module.blocks.get(function.blocks.items[3]).?;
    try std.testing.expectEqual(@as(usize, 1), merge.parameters.items.len);
    try std.testing.expectEqual(@as(usize, 1), merge.instructions.items.len);
    const multiply = module.instructions.get(merge.instructions.items[0]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.integer_multiply, multiply.operation.binary.opcode);

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "%one: constant u32 = bits(0x1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%true: constant bool = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "conditional_branch %true, .then(), .else()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%then_value: u32 = integer_add %one, %one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "branch .merge(%then_value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%else_value: u32 = integer_subtract %one, %one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".merge(%merged: u32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%product: u32 = integer_multiply %merged, %one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "integerMultiply") == null);

    var parsed = try ir.parser.parseString(std.testing.allocator, text);
    defer parsed.deinit();
    const round_trip = try ir.printer.allocPrint(std.testing.allocator, &parsed);
    defer std.testing.allocator.free(round_trip);
    try std.testing.expectEqualStrings(text, round_trip);
}

test "SPIR-V: decorated vertex interfaces and load-store operations" {
    const assembly =
        \\ OpCapability Shader
        \\ OpMemoryModel Logical GLSL450
        \\ OpEntryPoint Vertex %main "main" %in_color %out_color
        \\ OpName %in_color "in_color"
        \\ OpName %out_color "out_color"
        \\ OpDecorate %in_color Location 0
        \\ OpDecorate %out_color Location 0
        \\
        \\ %void = OpTypeVoid
        \\ %float = OpTypeFloat 32
        \\ %vec4 = OpTypeVector %float 4
        \\ %input_vec4 = OpTypePointer Input %vec4
        \\ %output_vec4 = OpTypePointer Output %vec4
        \\ %fn_void = OpTypeFunction %void
        \\ %in_color = OpVariable %input_vec4 Input
        \\ %out_color = OpVariable %output_vec4 Output
        \\
        \\ %main = OpFunction %void None %fn_void
        \\     %entry = OpLabel
        \\     %color = OpLoad %vec4 %in_color
        \\     OpStore %out_color %color
        \\     OpReturn
        \\ OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();
    try std.testing.expectEqual(ir.module.Stage.vertex, module.stage);
    try std.testing.expectEqual(@as(usize, 2), module.interface_variables.entries.items.len);

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "load_interface @in_color") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_interface @out_color") != null);
}

test "SPIR-V: access chains into interface vectors and promoted local vectors" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main" %global_id
        \\OpExecutionMode %main LocalSize 1 1 1
        \\OpName %global_y "global_y"
        \\OpName %local_z "local_z"
        \\OpName %signed_one "signed_one"
        \\OpDecorate %global_id BuiltIn GlobalInvocationId
        \\%void = OpTypeVoid
        \\%uint = OpTypeInt 32 0
        \\%int = OpTypeInt 32 1
        \\%vec3 = OpTypeVector %uint 3
        \\%ptr_input_vec3 = OpTypePointer Input %vec3
        \\%ptr_input_uint = OpTypePointer Input %uint
        \\%ptr_function_vec3 = OpTypePointer Function %vec3
        \\%ptr_function_uint = OpTypePointer Function %uint
        \\%fn_void = OpTypeFunction %void
        \\%one = OpConstant %uint 1
        \\%two = OpConstant %uint 2
        \\%signed_one = OpConstant %int 1
        \\%global_id = OpVariable %ptr_input_vec3 Input
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %local = OpVariable %ptr_function_vec3 Function
        \\    %global = OpLoad %vec3 %global_id
        \\    OpStore %local %global
        \\    %global_y_ptr = OpAccessChain %ptr_input_uint %global_id %one
        \\    %global_y = OpLoad %uint %global_y_ptr
        \\    %local_z_ptr = OpAccessChain %ptr_function_uint %local %two
        \\    %local_z = OpLoad %uint %local_z_ptr
        \\    %sum = OpIAdd %uint %global_y %local_z
        \\    %increment = OpIAdd %uint %sum %signed_one
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "%global_y: u32 = composite_extract") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%local_z: u32 = composite_extract") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bitcast %signed_one") != null);
}

test "SPIR-V: storage buffers and promoted function locals" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\OpName %index "index"
        \\OpName %source "source"
        \\OpName %destination "destination"
        \\OpDecorate %source_array ArrayStride 16
        \\OpDecorate %Source BufferBlock
        \\OpMemberDecorate %Source 0 Offset 0
        \\OpDecorate %source Binding 0
        \\OpDecorate %source DescriptorSet 0
        \\OpDecorate %destination_array ArrayStride 16
        \\OpDecorate %Destination BufferBlock
        \\OpMemberDecorate %Destination 0 Offset 0
        \\OpDecorate %destination Binding 1
        \\OpDecorate %destination DescriptorSet 0
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%int = OpTypeInt 32 1
        \\%uint = OpTypeInt 32 0
        \\%bool = OpTypeBool
        \\%vec4 = OpTypeVector %uint 4
        \\%uint_4 = OpConstant %uint 4
        \\%source_array = OpTypeArray %vec4 %uint_4
        \\%destination_array = OpTypeArray %vec4 %uint_4
        \\%Source = OpTypeStruct %source_array
        \\%Destination = OpTypeStruct %destination_array
        \\%ptr_uniform_source = OpTypePointer Uniform %Source
        \\%ptr_uniform_destination = OpTypePointer Uniform %Destination
        \\%ptr_uniform_vec4 = OpTypePointer Uniform %vec4
        \\%ptr_function_int = OpTypePointer Function %int
        \\%int_0 = OpConstant %int 0
        \\%int_1 = OpConstant %int 1
        \\%int_4 = OpConstant %int 4
        \\%source = OpVariable %ptr_uniform_source Uniform
        \\%destination = OpVariable %ptr_uniform_destination Uniform
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %index = OpVariable %ptr_function_int Function
        \\    OpStore %index %int_0
        \\    OpBranch %header
        \\    %header = OpLabel
        \\    OpLoopMerge %exit %continue None
        \\    OpBranch %condition
        \\    %condition = OpLabel
        \\    %current = OpLoad %int %index
        \\    %less = OpSLessThan %bool %current %int_4
        \\    OpBranchConditional %less %body %exit
        \\    %body = OpLabel
        \\    %source_index = OpLoad %int %index
        \\    %source_ptr = OpAccessChain %ptr_uniform_vec4 %source %int_0 %source_index
        \\    %value = OpLoad %vec4 %source_ptr
        \\    %destination_index = OpLoad %int %index
        \\    %destination_ptr = OpAccessChain %ptr_uniform_vec4 %destination %int_0 %destination_index
        \\    OpStore %destination_ptr %value
        \\    OpBranch %continue
        \\    %continue = OpLabel
        \\    %old_index = OpLoad %int %index
        \\    %next_index = OpIAdd %int %old_index %int_1
        \\    OpStore %index %next_index
        \\    OpBranch %header
        \\    %exit = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), module.resources.entries.items.len);
    try std.testing.expect(module.properties.explicit_resource_offsets);
    try std.testing.expect(module.properties.no_local_memory);

    const source = module.resources.get(ir.id.ResourceId.fromIndex(0)).?;
    const destination = module.resources.get(ir.id.ResourceId.fromIndex(1)).?;
    try std.testing.expectEqual(ir.types.ResourceKind.storage_buffer, source.kind);
    try std.testing.expectEqual(@as(u32, 0), source.binding);
    try std.testing.expectEqual(@as(u32, 1), destination.binding);

    const function = module.functions.get(module.entry_point.?).?;
    try std.testing.expectEqual(@as(usize, 6), function.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), module.blocks.get(function.blocks.items[0]).?.parameters.items.len);
    for (function.blocks.items[1..]) |block_id|
        try std.testing.expectEqual(@as(usize, 1), module.blocks.get(block_id).?.parameters.items.len);

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "@source: struct[array[vec4[u32], 4]] = storage_buffer[set(0), binding(0)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load_buffer @source") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_buffer @destination") != null);

    var parsed = try ir.parser.parseString(std.testing.allocator, text);
    defer parsed.deinit();
}

test "SPIR-V: fragment execution modes and translated properties" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint Fragment %main "main"
        \\OpExecutionMode %main OriginUpperLeft
        \\OpExecutionMode %main EarlyFragmentTests
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    try std.testing.expectEqual(ir.module.Stage.fragment, module.stage);
    try std.testing.expect(module.execution_modes.early_fragment_tests);
    try std.testing.expectEqual(@as(?[3]u32, null), module.execution_modes.workgroup_size);
    try std.testing.expect(module.properties.valid_cfg);
    try std.testing.expect(module.properties.valid_ssa);
    try std.testing.expect(module.properties.structured_control_flow);
    try std.testing.expect(module.properties.no_function_calls);

    const function = module.functions.get(module.entry_point.?).?;
    try std.testing.expectEqualStrings("main", function.name.?);
    try std.testing.expectEqual(@as(usize, 1), function.blocks.items.len);
    const entry = module.blocks.get(function.entry_block.?).?;
    try std.testing.expect(entry.terminator.? == .return_void);
}

test "SPIR-V: retained source instantiates independent entry points" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint Vertex %vertex_main "main"
        \\OpEntryPoint GLCompute %compute_main "main"
        \\OpExecutionMode %compute_main LocalSize 2 1 1
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%vertex_main = OpFunction %void None %fn_void
        \\    %vertex_entry = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
        \\%compute_main = OpFunction %void None %fn_void
        \\    %compute_entry = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var source = try SourceModule.init(std.testing.allocator, words);
    defer source.deinit(std.testing.allocator);

    var vertex_module = try instantiate(std.testing.allocator, &source, .{
        .entry_point = "main",
        .stage = .vertex,
    });
    defer vertex_module.deinit();
    var compute_module = try instantiate(std.testing.allocator, &source, .{
        .entry_point = "main",
        .stage = .compute,
    });
    defer compute_module.deinit();

    try std.testing.expectEqual(ir.module.Stage.vertex, vertex_module.stage);
    try std.testing.expectEqual(ir.module.Stage.compute, compute_module.stage);
    try std.testing.expectEqual(@as(?[3]u32, .{ 2, 1, 1 }), compute_module.execution_modes.workgroup_size);
    try std.testing.expect(vertex_module.entry_point != null);
    try std.testing.expect(compute_module.entry_point != null);
}

test "SPIR-V: scalar specialization constants and defaults" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\OpName %number "number"
        \\OpName %enabled "enabled"
        \\OpName %pair "pair"
        \\OpDecorate %number SpecId 7
        \\OpDecorate %enabled SpecId 8
        \\%void = OpTypeVoid
        \\%bool = OpTypeBool
        \\%u32 = OpTypeInt 32 0
        \\%vec2_u32 = OpTypeVector %u32 2
        \\%fn_void = OpTypeFunction %void
        \\%number = OpSpecConstant %u32 3
        \\%enabled = OpSpecConstantFalse %bool
        \\%pair = OpSpecConstantComposite %vec2_u32 %number %number
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %sum = OpIAdd %u32 %number %number
        \\    %selected = OpSelect %u32 %enabled %sum %number
        \\    %first = OpCompositeExtract %u32 %pair 0
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var source = try SourceModule.init(std.testing.allocator, words);
    defer source.deinit(std.testing.allocator);

    var defaults = try instantiate(std.testing.allocator, &source, .{
        .entry_point = "main",
        .stage = .compute,
    });
    defer defaults.deinit();
    try expectNamedIntegerConstant(&defaults, "number", 3);
    try expectNamedBooleanConstant(&defaults, "enabled", false);

    const number_override: u32 = 42;
    const enabled_override: u32 = 1;
    const specializations = [_]SpecializationValue{
        .{ .constant_id = 7, .data = std.mem.asBytes(&number_override) },
        .{ .constant_id = 8, .data = std.mem.asBytes(&enabled_override) },
    };
    var specialized = try instantiate(std.testing.allocator, &source, .{
        .entry_point = "main",
        .stage = .compute,
        .specializations = &specializations,
    });
    defer specialized.deinit();
    try expectNamedIntegerConstant(&specialized, "number", 42);
    try expectNamedBooleanConstant(&specialized, "enabled", true);

    const invalid_size: u16 = 9;
    try std.testing.expectError(TranslationError.InvalidSpecialization, instantiate(std.testing.allocator, &source, .{
        .entry_point = "main",
        .stage = .compute,
        .specializations = &.{.{ .constant_id = 7, .data = std.mem.asBytes(&invalid_size) }},
    }));
    try std.testing.expectError(TranslationError.DuplicateSpecializationConstant, instantiate(std.testing.allocator, &source, .{
        .entry_point = "main",
        .stage = .compute,
        .specializations = &.{
            .{ .constant_id = 7, .data = std.mem.asBytes(&number_override) },
            .{ .constant_id = 7, .data = std.mem.asBytes(&number_override) },
        },
    }));
}

test "SPIR-V: entry point lookup errors" {
    const single_entry_assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const single_entry_words = try assembleSpirv(std.testing.allocator, single_entry_assembly);
    defer std.testing.allocator.free(single_entry_words);
    try std.testing.expectError(TranslationError.EntryPointNotFound, translate(std.testing.allocator, single_entry_words, .{ .entry_point = "missing" }));

    const ambiguous_assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %first "main"
        \\OpEntryPoint GLCompute %second "main"
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%first = OpFunction %void None %fn_void
        \\    %first_entry = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
        \\%second = OpFunction %void None %fn_void
        \\    %second_entry = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const ambiguous_words = try assembleSpirv(std.testing.allocator, ambiguous_assembly);
    defer std.testing.allocator.free(ambiguous_words);
    try std.testing.expectError(TranslationError.AmbiguousEntryPoint, translate(std.testing.allocator, ambiguous_words, .{ .entry_point = "main" }));

    const unsupported_assembly =
        \\OpCapability Shader
        \\OpCapability Geometry
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint Geometry %main "main"
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const unsupported_words = try assembleSpirv(std.testing.allocator, unsupported_assembly);
    defer std.testing.allocator.free(unsupported_words);
    try std.testing.expectError(TranslationError.UnsupportedExecutionModel, translate(std.testing.allocator, unsupported_words, .{ .entry_point = "main" }));
}

test "SPIR-V: operation mappings to backend-agnostic IR" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%bool = OpTypeBool
        \\%uint = OpTypeInt 32 0
        \\%float = OpTypeFloat 32
        \\%vec2 = OpTypeVector %uint 2
        \\%fn_void = OpTypeFunction %void
        \\%true = OpConstantTrue %bool
        \\%one = OpConstant %uint 1
        \\%two = OpConstant %uint 2
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %not = OpLogicalNot %bool %true
        \\    %sum = OpIAdd %uint %one %two
        \\    %less = OpULessThan %bool %one %two
        \\    %selected = OpSelect %uint %less %one %two
        \\    %cast = OpBitcast %float %one
        \\    %vector = OpCompositeConstruct %vec2 %one %two
        \\    %element = OpCompositeExtract %uint %vector 1
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    const block = module.blocks.get(function.entry_block.?).?;
    try std.testing.expectEqual(@as(usize, 7), block.instructions.items.len);

    const logical_not = module.instructions.get(block.instructions.items[0]).?;
    try std.testing.expectEqual(ir.instruction.UnaryOpcode.logical_not, logical_not.operation.unary.opcode);

    const add = module.instructions.get(block.instructions.items[1]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.integer_add, add.operation.binary.opcode);

    const less = module.instructions.get(block.instructions.items[2]).?;
    try std.testing.expectEqual(ir.instruction.CompareOpcode.unsigned_less, less.operation.compare.opcode);

    const select = module.instructions.get(block.instructions.items[3]).?;
    try std.testing.expect(select.operation == .select);

    const bitcast = module.instructions.get(block.instructions.items[4]).?;
    try std.testing.expect(bitcast.operation == .bitcast);

    const construct = module.instructions.get(block.instructions.items[5]).?;
    try std.testing.expectEqual(@as(usize, 2), construct.operation.composite_construct.elements.len);

    const extract = module.instructions.get(block.instructions.items[6]).?;
    try std.testing.expectEqualSlices(u32, &.{1}, extract.operation.composite_extract.indices);
}

test "SPIR-V: unknown opcode reports an error without formatting the enum" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    OpNop
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    const nop_word: u32 = (@as(u32, 1) << 16) | @intFromEnum(spirv.Opcode.nop);
    for (words[spirv.header_word_count..]) |*word| {
        if (word.* != nop_word)
            continue;
        word.* = (@as(u32, 1) << 16) | 999;
        break;
    } else return error.MissingNop;

    try std.testing.expectError(error.UnsupportedOpcode, translate(std.testing.allocator, words, .{ .entry_point = "main" }));
}

test "SPIR-V: structured loop and OpPhi back edge" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\OpName %entry "entry"
        \\OpName %header "header"
        \\OpName %body "body"
        \\OpName %continue "continue"
        \\OpName %merge "merge"
        \\%void = OpTypeVoid
        \\%bool = OpTypeBool
        \\%uint = OpTypeInt 32 0
        \\%fn_void = OpTypeFunction %void
        \\%true = OpConstantTrue %bool
        \\%zero = OpConstant %uint 0
        \\%one = OpConstant %uint 1
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    OpBranch %header
        \\    %header = OpLabel
        \\    %index = OpPhi %uint %zero %entry %next %continue
        \\    OpLoopMerge %merge %continue None
        \\    OpBranchConditional %true %body %merge
        \\    %body = OpLabel
        \\    OpBranch %continue
        \\    %continue = OpLabel
        \\    %next = OpIAdd %uint %index %one
        \\    OpBranch %header
        \\    %merge = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    try std.testing.expectEqual(@as(usize, 5), function.blocks.items.len);
    const entry_id = function.blocks.items[0];
    const header_id = function.blocks.items[1];
    const continue_id = function.blocks.items[3];
    const merge_id = function.blocks.items[4];

    const entry = module.blocks.get(entry_id).?;
    try std.testing.expectEqual(@as(usize, 1), entry.terminator.?.branch.arguments.len);

    const header = module.blocks.get(header_id).?;
    try std.testing.expectEqual(@as(usize, 1), header.parameters.items.len);
    try std.testing.expect(header.structured_control == .loop);
    try std.testing.expectEqual(merge_id, header.structured_control.loop.merge_block);
    try std.testing.expectEqual(continue_id, header.structured_control.loop.continue_block);

    const continue_block = module.blocks.get(continue_id).?;
    try std.testing.expectEqual(header_id, continue_block.terminator.?.branch.target);
    try std.testing.expectEqual(@as(usize, 1), continue_block.terminator.?.branch.arguments.len);
}

test "SPIR-V: rejects a missing OpPhi incoming value" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%bool = OpTypeBool
        \\%uint = OpTypeInt 32 0
        \\%fn_void = OpTypeFunction %void
        \\%true = OpConstantTrue %bool
        \\%one = OpConstant %uint 1
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    OpBranchConditional %true %left %right
        \\    %left = OpLabel
        \\    OpBranch %merge
        \\    %right = OpLabel
        \\    OpBranch %merge
        \\    %merge = OpLabel
        \\    %value = OpPhi %uint %one %left
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    try std.testing.expectError(error.MissingPhiIncomingValue, translate(std.testing.allocator, words, .{ .entry_point = "main" }));
}

test "SPIR-V: preserves location components and builtin interfaces" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint Vertex %main "main" %input_value %position
        \\OpDecorate %input_value Location 3
        \\OpDecorate %input_value Component 2
        \\OpDecorate %input_value Index 1
        \\OpDecorate %position BuiltIn Position
        \\%void = OpTypeVoid
        \\%float = OpTypeFloat 32
        \\%vec4 = OpTypeVector %float 4
        \\%input_vec4 = OpTypePointer Input %vec4
        \\%output_vec4 = OpTypePointer Output %vec4
        \\%fn_void = OpTypeFunction %void
        \\%input_value = OpVariable %input_vec4 Input
        \\%position = OpVariable %output_vec4 Output
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const input = module.interface_variables.get(ir.id.InterfaceVariableId.fromIndex(0)).?;
    try std.testing.expectEqual(ir.module.InterfaceDirection.input, input.direction);
    try std.testing.expect(input.semantic == .location);
    try std.testing.expectEqual(@as(u32, 3), input.semantic.location.location);
    try std.testing.expectEqual(@as(u8, 2), input.semantic.location.component);
    try std.testing.expectEqual(@as(u8, 1), input.semantic.location.index);

    const position = module.interface_variables.get(ir.id.InterfaceVariableId.fromIndex(1)).?;
    try std.testing.expectEqual(ir.module.InterfaceDirection.output, position.direction);
    try std.testing.expect(position.semantic == .builtin);
    try std.testing.expectEqual(ir.module.Builtin.position, position.semantic.builtin);
}

fn expectNamedIntegerConstant(module: *const ir.module.Module, name: []const u8, expected: u64) !void {
    const value = findNamedConstant(module, name) orelse return error.MissingNamedConstant;
    try std.testing.expect(value == .integer_bits);
    try std.testing.expectEqual(expected, value.integer_bits);
}

fn expectNamedBooleanConstant(module: *const ir.module.Module, name: []const u8, expected: bool) !void {
    const value = findNamedConstant(module, name) orelse return error.MissingNamedConstant;
    try std.testing.expect(value == .boolean);
    try std.testing.expectEqual(expected, value.boolean);
}

fn findNamedConstant(module: *const ir.module.Module, name: []const u8) ?ir.constant.ConstantValue {
    for (module.values.entries.items) |entry| {
        const value = entry orelse continue;
        const value_name = value.name orelse continue;
        if (!std.mem.eql(u8, value_name, name) or value.definition != .constant)
            continue;
        return module.constants.get(value.definition.constant).?.value;
    }
    return null;
}

fn assembleSpirv(allocator: std.mem.Allocator, assembly: []const u8) ![]u32 {
    var io_backend: std.Io.Threaded = .init(allocator, .{});
    defer io_backend.deinit();
    const io = io_backend.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{ "spirv-as", "--target-env", "spv1.0", "-o", "-", "-" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    {
        const stdin = child.stdin.?;
        var stdin_writer = stdin.writer(io, &.{});
        try stdin_writer.interface.writeAll(assembly);
        try stdin_writer.interface.flush();
        stdin.close(io);
        child.stdin = null;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    const binary = try stdout_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(binary);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buffer);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(stderr);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.log.err("spirv-as failed:\n{s}", .{stderr});
            return error.SpirvAssemblyFailed;
        },
        else => {
            std.log.err("spirv-as terminated unexpectedly:\n{s}", .{stderr});
            return error.SpirvAssemblyFailed;
        },
    }

    if (binary.len % @sizeOf(u32) != 0) return error.InvalidSpirvBinaryLength;
    const words = try allocator.alloc(u32, binary.len / @sizeOf(u32));
    errdefer allocator.free(words);
    for (words, 0..) |*word, index| {
        const offset = index * @sizeOf(u32);
        word.* = std.mem.readInt(u32, binary[offset..][0..4], .little);
    }
    return words;
}
