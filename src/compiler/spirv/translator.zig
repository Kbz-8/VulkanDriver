const std = @import("std");
const builtin_info = @import("builtin");
const Parser = @import("Parser.zig");
const SourceModule = @import("SourceModule.zig");
const extensions = @import("extensions/extensions.zig");
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
    AmbiguousEntryPoint,
    DuplicateId,
    DuplicateSpecializationConstant,
    EntryPointNotFound,
    InvalidBlock,
    InvalidFunctionParameter,
    InvalidFunctionType,
    InvalidId,
    InvalidInstruction,
    InvalidPhi,
    InvalidSpecialization,
    MissingDefinition,
    MissingFunction,
    MissingPhiIncomingValue,
    SpecializationConstantsNotApplied,
    UnsupportedBuiltin,
    UnsupportedConstant,
    UnsupportedExecutionModel,
    UnsupportedExtendedInstruction,
    UnsupportedExtendedInstructionSet,
    UnsupportedOpcode,
    UnsupportedPrivateCrossFunction,
    UnsupportedStoreDestination,
    UnsupportedType,
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

const MatrixMajor = enum { row, column };

const MatrixMemoryLayout = struct {
    stride: u32,
    major: MatrixMajor,
};

const MemberMatrixLayout = struct {
    structure_id: u32,
    member: u32,
    stride: ?u32 = null,
    major: ?MatrixMajor = null,
};

const BufferAddress = struct {
    resource: ir.id.ResourceId,
    descriptor_index: ?ir.id.ValueId = null,
    byte_offset: ?ir.id.ValueId,
    pointee_type: u32,
    matrix_layout: ?MatrixMemoryLayout = null,
    vector_stride: ?u32 = null,
};

const PushConstantAddress = struct {
    byte_offset: ?ir.id.ValueId,
    pointee_type: u32,
    matrix_layout: ?MatrixMemoryLayout = null,
    vector_stride: ?u32 = null,
};

const DescriptorArray = struct {
    resources: []const ir.id.ResourceId,
    element_type: u32,
};

const WorkgroupAddress = struct {
    variable: ir.id.WorkgroupVariableId,
    byte_offset: ?ir.id.ValueId,
    pointee_type: u32,
};

const ImageAddress = struct {
    resource: ir.id.ResourceId,
    coordinate: ir.id.ValueId,
    dimension: ir.types.ImageDimension,
    arrayed: bool,
};

const SampledImage = struct {
    image: ir.id.ResourceId,
    sampler: ?ir.id.ResourceId,
    image_type: u32,
};

const ImageTypeInfo = struct {
    dimension: ir.types.ImageDimension,
    arrayed: bool,
};

const AtomicAddress = union(enum) {
    buffer: BufferAddress,
    workgroup: WorkgroupAddress,
};

const CompositeIndex = union(enum) {
    constant: u32,
    dynamic: struct { value: ir.id.ValueId, length: u32 },
};

const MemberInterface = struct {
    structure_id: u32,
    member: u32,
    decoration: Decorations,
};

const InterfaceBlock = struct {
    variable: u32,
    structure_id: u32,
    direction: ir.module.InterfaceDirection,
};

const CompositeAddress = struct {
    root: union(enum) {
        local: usize,
        value: ir.id.ValueId,
        interface: ir.id.InterfaceVariableId,
    },
    root_type: u32,
    pointee_type: u32,
    indices: []const CompositeIndex,
};

const LocalVariable = struct {
    spv_id: u32,
    type: ir.id.TypeId,
    initial_value: ir.id.ValueId,
    pointer_parameter: bool = false,
};

const PointerParameter = struct {
    parameter_index: usize,
    pointee_type: u32,
    return_member: u32,
};

const FunctionLowering = struct {
    source_return_type: ir.id.TypeId,
    lowered_return_type: ir.id.TypeId,
    pointer_parameters: []const PointerParameter,
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
    extended_instruction_sets: []?extensions.Set,
    names: []?[]const u8,
    decorations: []Decorations,
    specializations: []const SpecializationValue,

    types: []?ir.id.TypeId,
    values: []?ir.id.ValueId,
    blocks: []?ir.id.BlockId,
    functions: []?ir.id.FunctionId,
    reachable_functions: []bool,
    function_lowerings: []?FunctionLowering,
    interfaces: []?ir.id.InterfaceVariableId,
    resources: []?ir.id.ResourceId,
    image_resources: []?ir.id.ResourceId,
    image_types: []?u32,
    sampled_images: []?SampledImage,
    sampled_image_arrays: []?[]const SampledImage,
    image_addresses: []?ImageAddress,
    buffer_addresses: []?BufferAddress,
    push_constant_addresses: []?PushConstantAddress,
    descriptor_arrays: []?DescriptorArray,
    workgroup_variables: []?ir.id.WorkgroupVariableId,
    workgroup_addresses: []?WorkgroupAddress,
    composite_addresses: []?CompositeAddress,
    member_offsets: std.ArrayList(MemberOffset) = .empty,
    member_matrix_layouts: std.ArrayList(MemberMatrixLayout) = .empty,
    member_interfaces: std.ArrayList(MemberInterface) = .empty,
    interface_blocks: std.ArrayList(InterfaceBlock) = .empty,
    member_bindings: std.AutoHashMapUnmanaged(u64, ir.id.InterfaceVariableId) = .empty,
    phi_infos: std.ArrayList(PhiInfo) = .empty,

    local_indices: []?usize,
    function_parameter_pointees: []?u32,
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
            .type_matrix => blk: {
                try expectOperandCount(operands, 3);

                if (operands[2] < 2 or operands[2] > std.math.maxInt(u8))
                    return TranslationError.UnsupportedType;

                break :blk try self.builder.internType(.{
                    .matrix = .{
                        .element_type = try self.translateType(operands[1]),
                        .column_count = @intCast(operands[2]),
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
            .type_image => blk: {
                if (operands.len < 8 or operands.len > 9)
                    return TranslationError.UnsupportedType;

                const image_info = try imageTypeInfo(self, spv_id);
                const kind: ir.types.ResourceKind = switch (operands[6]) {
                    1 => if (image_info.dimension == .buffer) .uniform_texel_buffer else .sampled_image,
                    2 => if (image_info.dimension == .buffer) .storage_texel_buffer else .storage_image,
                    else => return TranslationError.UnsupportedType,
                };
                break :blk try self.builder.internType(.{
                    .resource_handle = .{
                        .kind = kind,
                        .data_type = try self.translateType(operands[1]),
                    },
                });
            },
            .type_sampler => blk: {
                try expectOperandCount(operands, 1);
                break :blk try self.builder.internType(.{ .resource_handle = .{ .kind = .sampler } });
            },
            .type_sampled_image => blk: {
                try expectOperandCount(operands, 2);
                const image = self.type_defs[try self.idIndex(operands[1])] orelse return TranslationError.MissingDefinition;
                if (image.opcode != .type_image or image.operands.len < 8 or image.operands[6] != 1)
                    return TranslationError.UnsupportedType;
                break :blk try self.translateType(operands[1]);
            },
            .type_pointer => blk: {
                try expectOperandCount(operands, 3);
                break :blk try self.builder.internType(.{
                    .pointer = .{
                        .address_space = try translateStorageClass(@fromBackingInt(@intCast(operands[1]))),
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
            .spec_constant_op => blk: {
                try expectOperandCount(operands, 5);
                const opcode: spirv.Opcode = @fromBackingInt(@intCast(operands[2]));
                if (opcode != .i_equal and opcode != .i_not_equal and opcode != .bitwise_and and opcode != .shift_right_logical) {
                    const name = std.enums.tagName(spirv.Opcode, opcode) orelse "unknown";
                    std.log.scoped(.spirv_translator).err("unsupported OpSpecConstantOp {s} ({d}) for %{d}", .{ name, operands[2], spv_id });
                    return TranslationError.SpecializationConstantsNotApplied;
                }

                const result_type = try self.translateType(operands[0]);
                const result_type_data = self.module.types.get(result_type) orelse return TranslationError.InvalidId;
                const lhs = (self.module.values.get(try self.translateValue(operands[3])) orelse return TranslationError.InvalidId).*;
                const rhs = (self.module.values.get(try self.translateValue(operands[4])) orelse return TranslationError.InvalidId).*;
                if (lhs.type != rhs.type or lhs.definition != .constant or rhs.definition != .constant)
                    return TranslationError.UnsupportedConstant;

                const operand_type = self.module.types.get(lhs.type) orelse return TranslationError.InvalidId;
                const operand_integer = switch (operand_type.*) {
                    .integer => |integer| integer,
                    else => return TranslationError.UnsupportedConstant,
                };

                const lhs_constant = self.module.constants.get(lhs.definition.constant) orelse return TranslationError.InvalidId;
                const rhs_constant = self.module.constants.get(rhs.definition.constant) orelse return TranslationError.InvalidId;
                if (lhs_constant.value != .integer_bits or rhs_constant.value != .integer_bits)
                    return TranslationError.UnsupportedConstant;

                break :blk switch (opcode) {
                    .i_equal, .i_not_equal => result: {
                        if (result_type_data.* != .boolean)
                            return TranslationError.UnsupportedConstant;
                        break :result try self.builder.internConstant(result_type, .{
                            .boolean = if (opcode == .i_equal)
                                lhs_constant.value.integer_bits == rhs_constant.value.integer_bits
                            else
                                lhs_constant.value.integer_bits != rhs_constant.value.integer_bits,
                        });
                    },
                    .bitwise_and => result: {
                        if (result_type != lhs.type or result_type_data.* != .integer)
                            return TranslationError.UnsupportedConstant;
                        break :result try self.builder.internConstant(result_type, .{
                            .integer_bits = lhs_constant.value.integer_bits & rhs_constant.value.integer_bits,
                        });
                    },
                    .shift_right_logical => result: {
                        if (result_type != lhs.type or result_type_data.* != .integer or rhs_constant.value.integer_bits >= operand_integer.bits)
                            return TranslationError.UnsupportedConstant;
                        const mask = if (operand_integer.bits == 64)
                            std.math.maxInt(u64)
                        else
                            (@as(u64, 1) << @intCast(operand_integer.bits)) - 1;
                        break :result try self.builder.internConstant(result_type, .{
                            .integer_bits = (lhs_constant.value.integer_bits & mask) >> @intCast(rhs_constant.value.integer_bits),
                        });
                    },
                    else => unreachable,
                };
            },

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

    fn function(self: *const Context, spv_id: u32) TranslationError!ir.id.FunctionId {
        return self.functions[try self.idIndex(spv_id)] orelse TranslationError.MissingFunction;
    }

    fn interfaceVariable(self: *const Context, spv_id: u32) TranslationError!ir.id.InterfaceVariableId {
        const index = try self.idIndex(spv_id);
        return self.interfaces[index] orelse TranslationError.UnsupportedOpcode;
    }

    fn resource(self: *const Context, spv_id: u32) TranslationError!?ir.id.ResourceId {
        return self.resources[try self.idIndex(spv_id)];
    }

    fn imageResource(self: *const Context, spv_id: u32) TranslationError!?ir.id.ResourceId {
        return self.image_resources[try self.idIndex(spv_id)];
    }

    fn sampledImage(self: *const Context, spv_id: u32) TranslationError!?SampledImage {
        return self.sampled_images[try self.idIndex(spv_id)];
    }

    fn imageAddress(self: *const Context, spv_id: u32) TranslationError!?ImageAddress {
        return self.image_addresses[try self.idIndex(spv_id)];
    }

    fn bufferAddress(self: *const Context, spv_id: u32) TranslationError!?BufferAddress {
        const index = try self.idIndex(spv_id);
        return self.buffer_addresses[index];
    }

    fn pushConstantAddress(self: *const Context, spv_id: u32) TranslationError!?PushConstantAddress {
        return self.push_constant_addresses[try self.idIndex(spv_id)];
    }

    fn descriptorArray(self: *const Context, spv_id: u32) TranslationError!?DescriptorArray {
        const index = try self.idIndex(spv_id);
        return self.descriptor_arrays[index];
    }

    fn workgroupAddress(self: *const Context, spv_id: u32) TranslationError!?WorkgroupAddress {
        const index = try self.idIndex(spv_id);
        return self.workgroup_addresses[index];
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

fn isImageResourceKind(kind: ir.types.ResourceKind) bool {
    return switch (kind) {
        .sampled_image, .storage_image, .uniform_texel_buffer, .storage_texel_buffer => true,
        else => false,
    };
}

fn imageTypeInfo(context: *const Context, image_type: u32) TranslationError!ImageTypeInfo {
    const definition = context.type_defs[try context.idIndex(image_type)] orelse return TranslationError.MissingDefinition;
    if (definition.opcode != .type_image or definition.operands.len < 8 or definition.operands.len > 9)
        return TranslationError.UnsupportedType;

    const dimension: ir.types.ImageDimension = switch (definition.operands[2]) {
        0 => .one_d,
        1 => .two_d,
        2 => .three_d,
        3 => .cube,
        5 => .buffer,
        else => return TranslationError.UnsupportedType,
    };
    const arrayed = switch (definition.operands[4]) {
        0 => false,
        1 => true,
        else => return TranslationError.UnsupportedType,
    };
    if (definition.operands[5] != 0 or (arrayed and (dimension == .three_d or dimension == .buffer)))
        return TranslationError.UnsupportedType;
    return .{ .dimension = dimension, .arrayed = arrayed };
}

fn canonicalizeImageCoordinate(context: *Context, block: ir.id.BlockId, spv_coordinate: u32, image: ImageTypeInfo) !ir.id.ValueId {
    const coordinate = try context.resolveValue(spv_coordinate);
    const coordinate_type = context.module.typeOf(coordinate) orelse return TranslationError.InvalidId;
    const shape = integerTypeShape(context, coordinate_type) orelse return TranslationError.InvalidInstruction;
    const required: u8 = switch (image.dimension) {
        .one_d => 1 + @as(u8, @intFromBool(image.arrayed)),
        .two_d => 2 + @as(u8, @intFromBool(image.arrayed)),
        .three_d, .cube => 3,
        .buffer => 1,
    };

    if (shape.bits != 32 or shape.components < required)
        return TranslationError.InvalidInstruction;

    const source_type = context.module.types.get(coordinate_type).?.*;

    if (source_type == .integer or (shape.components == required and required != 1))
        return coordinate;

    const elements = try context.scratch.alloc(ir.id.ValueId, required);
    for (elements, 0..) |*element, index| {
        element.* = (try context.builder.appendInstruction(block, source_type.vector.element_type, .{
            .composite_extract = .{
                .composite = coordinate,
                .indices = try context.scratch.dupe(u32, &.{@intCast(index)}),
            },
        }, null)).?;
    }

    if (required == 1)
        return elements[0];

    const result_type = try context.builder.internType(.{
        .vector = .{
            .element_type = source_type.vector.element_type,
            .length = required,
        },
    });

    return (try context.builder.appendInstruction(block, result_type, .{
        .composite_construct = .{
            .elements = elements,
        },
    }, null)).?;
}

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
        .extended_instruction_sets = try allocOptional(extensions.Set, scratch, bound),
        .names = try allocOptional([]const u8, scratch, bound),
        .decorations = try scratch.alloc(Decorations, bound),
        .specializations = options.specializations,
        .types = try allocOptional(ir.id.TypeId, scratch, bound),
        .values = try allocOptional(ir.id.ValueId, scratch, bound),
        .blocks = try allocOptional(ir.id.BlockId, scratch, bound),
        .functions = try allocOptional(ir.id.FunctionId, scratch, bound),
        .reachable_functions = try scratch.alloc(bool, bound),
        .function_lowerings = try allocOptional(FunctionLowering, scratch, bound),
        .interfaces = try allocOptional(ir.id.InterfaceVariableId, scratch, bound),
        .resources = try allocOptional(ir.id.ResourceId, scratch, bound),
        .image_resources = try allocOptional(ir.id.ResourceId, scratch, bound),
        .image_types = try allocOptional(u32, scratch, bound),
        .sampled_images = try allocOptional(SampledImage, scratch, bound),
        .sampled_image_arrays = try allocOptional([]const SampledImage, scratch, bound),
        .image_addresses = try allocOptional(ImageAddress, scratch, bound),
        .buffer_addresses = try allocOptional(BufferAddress, scratch, bound),
        .push_constant_addresses = try allocOptional(PushConstantAddress, scratch, bound),
        .descriptor_arrays = try allocOptional(DescriptorArray, scratch, bound),
        .workgroup_variables = try allocOptional(ir.id.WorkgroupVariableId, scratch, bound),
        .workgroup_addresses = try allocOptional(WorkgroupAddress, scratch, bound),
        .composite_addresses = try allocOptional(CompositeAddress, scratch, bound),
        .local_indices = try allocOptional(usize, scratch, bound),
        .function_parameter_pointees = try allocOptional(u32, scratch, bound),
        .block_local_inputs = try allocOptional(ir.id.ValueId, scratch, 0),
        .block_local_outputs = try allocOptional(ir.id.ValueId, scratch, 0),
        .current_locals = try allocOptional(ir.id.ValueId, scratch, 0),
    };
    @memset(context.decorations, .{});
    defer context.member_offsets.deinit(scratch);
    defer context.member_matrix_layouts.deinit(scratch);
    defer context.phi_infos.deinit(scratch);
    defer context.locals.deinit(scratch);

    try collectDeclarations(&context);
    try translateInterfaces(&context, entry_point.interface_ids);
    try translateResources(&context);
    try translatePushConstantVariables(&context);
    try translateWorkgroupVariables(&context);
    try applyExecutionModes(&context, entry_point.function_id);
    try collectReachableFunctions(&context, entry_point.function_id);
    try declareFunctions(&context, entry_point, options.entry_point);
    try validatePrivateScope(&context);
    try translateFunctions(&context);
    // Output reads are translator-internal until invocation state is promoted
    // after inlining. Public IR and backends still only load input interfaces.
    const output_reads = hasOutputReads(&module);
    if (!output_reads)
        try ir.validator.validate(&module);
    module.properties.structured_control_flow = true;

    if (hasFunctionCalls(&module)) {
        var manager = ir.transformer_manager.Manager.init(scratch);
        defer manager.deinit();
        try manager.add(ir.inline_all_functions.transformer);
        var transformer_context: ir.transformer_manager.Context = .{
            .allocator = scratch,
            .validate_after_each_transformer = !output_reads and builtin_info.mode == .debug,
        };
        _ = try manager.run(&module, &transformer_context);
    } else {
        module.properties.no_function_calls = true;
    }
    if (output_reads)
        try promoteOutputReads(&context);
    try ir.validator.validate(&module);
    module.properties.valid_cfg = true;
    module.properties.valid_ssa = true;
    return module;
}

fn hasOutputReads(module: *const ir.module.Module) bool {
    for (module.instructions.entries.items) |entry| {
        const instruction = entry orelse continue;
        if (instruction.operation == .load_interface and
            module.interface_variables.get(instruction.operation.load_interface.variable).?.direction == .output)
            return true;
    }
    return false;
}

// Once calls are inlined, output memory is invocation-local SSA state. Keep
// stores observable, but replace reads by the most recent value along each CFG
// edge. Unwritten components remain undef rather than being reset by a store
fn promoteOutputReads(context: *Context) !void {
    const module = context.module;
    const function = module.functions.get(module.entry_point.?).?;
    const entry_block = function.entry_block.?;
    var rewriter = ir.Rewriter.init(module);
    for (module.interface_variables.entries.items, 0..) |optional_variable, variable_index| {
        const variable = optional_variable orelse continue;
        if (variable.direction != .output)
            continue;
        const variable_id = ir.id.InterfaceVariableId.fromIndex(variable_index);
        var read = false;
        for (module.instructions.entries.items) |optional_instruction| {
            const instruction = optional_instruction orelse continue;
            if (instruction.operation == .load_interface and instruction.operation.load_interface.variable == variable_id) {
                if (instruction.operation.load_interface.element_index != null)
                    return TranslationError.UnsupportedOpcode;
                read = true;
            }
        }
        if (!read)
            continue;

        const inputs = try context.scratch.alloc(ir.id.ValueId, module.blocks.entries.items.len);
        const outputs = try context.scratch.alloc(ir.id.ValueId, module.blocks.entries.items.len);
        for (function.blocks.items) |block_id| {
            inputs[block_id.index()] = if (block_id == entry_block)
                try module.values.add(module.allocator(), .{ .type = variable.type, .definition = .undef })
            else
                try context.builder.addBlockParameter(block_id, variable.type, null);
        }
        for (function.blocks.items) |block_id| {
            var current = inputs[block_id.index()];
            var index: usize = 0;
            while (index < module.blocks.get(block_id).?.instructions.items.len) {
                const instruction_id = module.blocks.get(block_id).?.instructions.items[index];
                const instruction = module.instructions.get(instruction_id).?.*;
                switch (instruction.operation) {
                    .load_interface => |load| if (load.variable == variable_id) {
                        _ = try rewriter.replaceAllUses(instruction.result.?, current);
                        try rewriter.eraseInstruction(instruction_id);
                        continue;
                    },
                    .store_interface => |store| if (store.variable == variable_id) {
                        if (store.element_index != null or module.typeOf(store.value) != variable.type)
                            return TranslationError.InvalidInstruction;
                        current = store.value;
                    },
                    else => {},
                }
                index += 1;
            }
            outputs[block_id.index()] = current;
        }
        for (function.blocks.items) |block_id| {
            const terminator = &module.blocks.getMut(block_id).?.terminator.?;
            switch (terminator.*) {
                .branch => |*edge| try appendOutputArgument(module, edge, entry_block, outputs[block_id.index()]),
                .conditional_branch => |*branch| {
                    try appendOutputArgument(module, &branch.true_edge, entry_block, outputs[block_id.index()]);
                    try appendOutputArgument(module, &branch.false_edge, entry_block, outputs[block_id.index()]);
                },
                else => {},
            }
        }
    }
}

fn appendOutputArgument(module: *ir.module.Module, edge: *ir.module.Edge, entry_block: ir.id.BlockId, value: ir.id.ValueId) !void {
    if (edge.target == entry_block)
        return TranslationError.InvalidBlock;
    const arguments = try module.allocator().alloc(ir.id.ValueId, edge.arguments.len + 1);
    @memcpy(arguments[0..edge.arguments.len], edge.arguments);
    arguments[edge.arguments.len] = value;
    edge.arguments = arguments;
}

fn hasFunctionCalls(module: *const ir.module.Module) bool {
    for (module.instructions.entries.items) |entry| {
        const instruction = entry orelse continue;
        if (instruction.operation == .call)
            return true;
    }
    return false;
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
        if (instruction.opcode == .ext_inst_import) {
            if (operands.len < 2)
                return TranslationError.InvalidInstruction;

            const index = try context.idIndex(operands[0]);
            if (context.extended_instruction_sets[index] != null)
                return TranslationError.DuplicateId;
            const name = try Parser.copyLiteralString(context.scratch, operands[1..]);
            context.extended_instruction_sets[index] = extensions.classify(name);
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
    const decoration: spirv.Decoration = @fromBackingInt(@intCast(operands[1]));
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

    const decoration: spirv.Decoration = @fromBackingInt(@intCast(operands[2]));
    if (decoration == .row_major or decoration == .col_major or decoration == .matrix_stride) {
        _ = try context.idIndex(operands[0]);
        var entry: ?*MemberMatrixLayout = null;
        for (context.member_matrix_layouts.items) |*layout| {
            if (layout.structure_id == operands[0] and layout.member == operands[1]) {
                entry = layout;
                break;
            }
        }
        if (entry == null) {
            try context.member_matrix_layouts.append(context.scratch, .{
                .structure_id = operands[0],
                .member = operands[1],
            });
            entry = &context.member_matrix_layouts.items[context.member_matrix_layouts.items.len - 1];
        }

        switch (decoration) {
            .row_major, .col_major => {
                try expectOperandCount(operands, 3);
                if (entry.?.major != null)
                    return TranslationError.InvalidInstruction;
                entry.?.major = if (decoration == .row_major) .row else .column;
            },
            .matrix_stride => {
                try expectOperandCount(operands, 4);
                if (entry.?.stride != null or operands[3] == 0)
                    return TranslationError.InvalidInstruction;
                entry.?.stride = operands[3];
            },
            else => unreachable,
        }
        return;
    }

    if (decoration != .offset) {
        if (decoration != .built_in and decoration != .location and decoration != .component and decoration != .index)
            return;
        try expectOperandCount(operands, 4);
        var entry: ?*MemberInterface = null;
        for (context.member_interfaces.items) |*member| {
            if (member.structure_id == operands[0] and member.member == operands[1]) {
                entry = member;
                break;
            }
        }
        if (entry == null) {
            try context.member_interfaces.append(context.scratch, .{ .structure_id = operands[0], .member = operands[1], .decoration = .{} });
            entry = &context.member_interfaces.items[context.member_interfaces.items.len - 1];
        }
        switch (decoration) {
            .built_in => entry.?.decoration.builtin = operands[3],
            .location => entry.?.decoration.location = operands[3],
            .component => entry.?.decoration.component = std.math.cast(u8, operands[3]) orelse return TranslationError.InvalidInstruction,
            .index => entry.?.decoration.index = std.math.cast(u8, operands[3]) orelse return TranslationError.InvalidInstruction,
            else => unreachable,
        }
        return;
    }

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

        const storage_class: spirv.StorageClass = @fromBackingInt(@intCast(variable.operands[2]));
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
        const pointee = context.type_defs[try context.idIndex(pointer.operands[2])] orelse return TranslationError.MissingDefinition;
        if (pointee.opcode == .type_struct and decoration.location == null and decoration.builtin == null) {
            try context.interface_blocks.append(context.scratch, .{ .variable = spv_id, .structure_id = pointer.operands[2], .direction = direction });
            continue;
        }

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
                .builtin = try translateBuiltin(std.enums.fromInt(spirv.Builtin, builtin) orelse return TranslationError.UnsupportedBuiltin),
            }
        else
            return TranslationError.UnsupportedOpcode;

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

        const storage_class: spirv.StorageClass = @fromBackingInt(@intCast(variable.operands[2]));
        if (storage_class != .uniform and storage_class != .storage_buffer and storage_class != .uniform_constant)
            continue;

        const pointer = context.type_defs[try context.idIndex(variable.operands[0])] orelse return TranslationError.MissingDefinition;
        if (pointer.opcode != .type_pointer)
            return TranslationError.InvalidInstruction;
        try expectOperandCount(pointer.operands, 3);
        if (pointer.operands[1] != variable.operands[2])
            return TranslationError.InvalidInstruction;

        const pointee_id = pointer.operands[2];
        const pointee = context.type_defs[try context.idIndex(pointee_id)] orelse return TranslationError.MissingDefinition;
        const variable_decoration = context.decorations[spv_index];
        if (storage_class == .uniform_constant) {
            const array = if (pointee.opcode == .type_array) pointee else null;
            const element = if (array) |array_type| blk: {
                try expectOperandCount(array_type.operands, 3);
                break :blk context.type_defs[try context.idIndex(array_type.operands[1])] orelse return TranslationError.MissingDefinition;
            } else pointee;
            if (element.opcode == .type_sampled_image) {
                try expectOperandCount(element.operands, 2);
                const image_type_id = element.operands[1];
                const image_type = try context.translateType(image_type_id);
                const image_type_data = context.module.types.get(image_type) orelse return TranslationError.InvalidId;
                if (image_type_data.* != .resource_handle or (image_type_data.resource_handle.kind != .sampled_image and image_type_data.resource_handle.kind != .uniform_texel_buffer))
                    return TranslationError.UnsupportedType;

                const set = variable_decoration.descriptor_set orelse return TranslationError.InvalidInstruction;
                const binding = variable_decoration.binding orelse return TranslationError.InvalidInstruction;
                const name = context.nameOf(@intCast(spv_index));
                const image_kind = image_type_data.resource_handle.kind;
                const needs_sampler = image_kind != .uniform_texel_buffer;
                const sampler_type = if (needs_sampler) try context.builder.internType(.{ .resource_handle = .{ .kind = .sampler } }) else null;
                const sampler_name = if (needs_sampler) (if (name) |base| try std.fmt.allocPrint(context.scratch, "{s}_sampler", .{base}) else null) else null;
                const count: usize = if (array) |array_type| try constantIndex(context, array_type.operands[2]) else 1;
                if (count == 0)
                    return TranslationError.InvalidInstruction;
                const sampled_images = try context.scratch.alloc(SampledImage, count);
                for (sampled_images, 0..) |*sampled_image, array_element| {
                    sampled_image.* = .{
                        .image = try context.builder.addResourceArrayElement(image_type, image_kind, set, binding, @intCast(array_element), if (array_element == 0) name else null),
                        .sampler = if (sampler_type) |ty| try context.builder.addResourceArrayElement(ty, .sampler, set, binding, @intCast(array_element), if (array_element == 0) sampler_name else null) else null,
                        .image_type = image_type_id,
                    };
                }
                if (array != null)
                    context.sampled_image_arrays[spv_index] = sampled_images
                else
                    context.sampled_images[spv_index] = sampled_images[0];
                continue;
            }
            if (pointee.opcode != .type_image and pointee.opcode != .type_sampler)
                continue;
            const resource_type = try context.translateType(pointee_id);
            const type_data = context.module.types.get(resource_type) orelse return TranslationError.InvalidId;
            const handle = switch (type_data.*) {
                .resource_handle => |handle| handle,
                else => continue,
            };
            if (!isImageResourceKind(handle.kind) and handle.kind != .sampler)
                continue;

            const resource = try context.builder.addResource(
                resource_type,
                handle.kind,
                variable_decoration.descriptor_set orelse return TranslationError.InvalidInstruction,
                variable_decoration.binding orelse return TranslationError.InvalidInstruction,
                context.nameOf(@intCast(spv_index)),
            );
            context.resources[spv_index] = resource;
            if (isImageResourceKind(handle.kind)) {
                context.image_resources[spv_index] = resource;
                context.image_types[spv_index] = pointee_id;
            }
            continue;
        }
        const is_descriptor_array = pointee.opcode == .type_array;
        const resource_type_id = if (is_descriptor_array) blk: {
            try expectOperandCount(pointee.operands, 3);
            break :blk pointee.operands[1];
        } else pointee_id;
        const resource_decoration = context.decorations[try context.idIndex(resource_type_id)];
        const kind: ir.types.ResourceKind = if (storage_class == .storage_buffer or resource_decoration.buffer_block)
            .storage_buffer
        else if (resource_decoration.block)
            .uniform_buffer
        else
            continue;

        const set = variable_decoration.descriptor_set orelse return TranslationError.InvalidInstruction;
        const binding = variable_decoration.binding orelse return TranslationError.InvalidInstruction;
        const resource_type = try context.translateType(resource_type_id);
        if (is_descriptor_array) {
            const count: usize = try constantIndex(context, pointee.operands[2]);
            if (count == 0)
                return TranslationError.InvalidInstruction;
            const resources = try context.scratch.alloc(ir.id.ResourceId, count);
            for (resources, 0..) |*resource, array_element| {
                resource.* = try context.builder.addResourceArrayElement(
                    resource_type,
                    kind,
                    set,
                    binding,
                    @intCast(array_element),
                    if (array_element == 0) context.nameOf(@intCast(spv_index)) else null,
                );
            }
            context.resources[spv_index] = resources[0];
            context.descriptor_arrays[spv_index] = .{
                .resources = resources,
                .element_type = resource_type_id,
            };
        } else {
            const resource = try context.builder.addResource(
                resource_type,
                kind,
                set,
                binding,
                context.nameOf(@intCast(spv_index)),
            );
            context.resources[spv_index] = resource;
            context.buffer_addresses[spv_index] = .{
                .resource = resource,
                .byte_offset = null,
                .pointee_type = pointee_id,
            };
        }
    }

    if (context.module.resources.entries.items.len != 0)
        context.module.properties.explicit_resource_offsets = true;
}

fn translatePushConstantVariables(context: *Context) !void {
    for (context.variable_defs, 0..) |optional_variable, spv_index| {
        const variable = optional_variable orelse continue;
        if (variable.operands.len < 3 or variable.operands.len > 4)
            return TranslationError.InvalidInstruction;
        if (variable.operands[2] != @backingInt(spirv.StorageClass.push_constant))
            continue;
        if (variable.operands.len != 3)
            return TranslationError.UnsupportedOpcode;

        const pointer = context.type_defs[try context.idIndex(variable.operands[0])] orelse return TranslationError.MissingDefinition;
        if (pointer.opcode != .type_pointer)
            return TranslationError.InvalidInstruction;

        try expectOperandCount(pointer.operands, 3);
        if (pointer.operands[1] != variable.operands[2])
            return TranslationError.InvalidInstruction;

        context.push_constant_addresses[spv_index] = .{
            .byte_offset = null,
            .pointee_type = pointer.operands[2],
        };
    }
}

fn translateWorkgroupVariables(context: *Context) !void {
    for (context.variable_defs, 0..) |optional_variable, spv_index| {
        const variable = optional_variable orelse continue;
        if (variable.operands.len < 3 or variable.operands.len > 4)
            return TranslationError.InvalidInstruction;

        const storage_class: spirv.StorageClass = @fromBackingInt(@intCast(variable.operands[2]));
        if (storage_class != .workgroup)
            continue;
        if (variable.operands.len != 3)
            return TranslationError.UnsupportedOpcode;

        const pointer = context.type_defs[try context.idIndex(variable.operands[0])] orelse return TranslationError.MissingDefinition;
        if (pointer.opcode != .type_pointer)
            return TranslationError.InvalidInstruction;
        try expectOperandCount(pointer.operands, 3);
        if (pointer.operands[1] != variable.operands[2])
            return TranslationError.InvalidInstruction;

        const pointee_type = pointer.operands[2];
        _ = try workgroupTypeSize(context, pointee_type);
        const translated = try context.builder.addWorkgroupVariable(
            try context.translateType(pointee_type),
            context.nameOf(@intCast(spv_index)),
        );
        context.workgroup_variables[spv_index] = translated;
        context.workgroup_addresses[spv_index] = .{
            .variable = translated,
            .byte_offset = null,
            .pointee_type = pointee_type,
        };
    }
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

        const model: spirv.ExecutionModel = @fromBackingInt(@intCast(instruction.operands[0]));
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
        if (instruction.opcode != .execution_mode and instruction.opcode != .execution_mode_id)
            continue;

        if (instruction.operands.len < 2)
            return TranslationError.InvalidInstruction;

        if (instruction.operands[0] != entry_function)
            continue;

        const mode: spirv.ExecutionMode = @fromBackingInt(@intCast(instruction.operands[1]));

        switch (mode) {
            .early_fragment_tests => context.module.execution_modes.early_fragment_tests = true,
            .local_size => {
                if (instruction.opcode != .execution_mode)
                    return TranslationError.InvalidInstruction;
                try expectOperandCount(instruction.operands, 5);
                context.module.execution_modes.workgroup_size = instruction.operands[2..5].*;
            },
            .local_size_id => {
                if (instruction.opcode != .execution_mode_id)
                    return TranslationError.InvalidInstruction;
                try expectOperandCount(instruction.operands, 5);
                context.module.execution_modes.workgroup_size = .{
                    try constantIndex(context, instruction.operands[2]),
                    try constantIndex(context, instruction.operands[3]),
                    try constantIndex(context, instruction.operands[4]),
                };
            },
            else => {},
        }
    }

    for (context.decorations, 0..) |decoration, spv_id| {
        if (decoration.builtin != @backingInt(spirv.Builtin.workgroup_size))
            continue;
        const definition = context.value_defs[spv_id] orelse continue;
        if (definition.opcode != .spec_constant_composite and definition.opcode != .constant_composite)
            continue;
        try expectOperandCount(definition.operands, 5);
        context.module.execution_modes.workgroup_size = .{
            try constantIndex(context, definition.operands[2]),
            try constantIndex(context, definition.operands[3]),
            try constantIndex(context, definition.operands[4]),
        };
    }
}

fn collectReachableFunctions(context: *Context, entry_function: u32) !void {
    @memset(context.reachable_functions, false);
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(context.scratch);
    context.reachable_functions[try context.idIndex(entry_function)] = true;
    try pending.append(context.scratch, entry_function);
    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        _ = try findFunction(context.parser, pending.items[next]);
        var active = false;
        var iterator = context.parser.iterator();
        while (try iterator.next()) |instruction| {
            switch (instruction.opcode) {
                .function => {
                    try expectOperandCount(instruction.operands, 4);
                    active = instruction.operands[1] == pending.items[next];
                },
                .function_end => active = false,
                .function_call => if (active) {
                    if (instruction.operands.len < 3)
                        return TranslationError.InvalidInstruction;
                    const callee = instruction.operands[2];
                    const index = try context.idIndex(callee);
                    if (!context.reachable_functions[index]) {
                        context.reachable_functions[index] = true;
                        try pending.append(context.scratch, callee);
                    }
                },
                else => {},
            }
        }
    }
}

fn declareFunctions(context: *Context, entry_point: EntryPoint, entry_name: []const u8) !void {
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode != .function)
            continue;
        try expectOperandCount(instruction.operands, 4);
        const spv_function = instruction.operands[1];
        const index = try context.idIndex(spv_function);
        if (!context.reachable_functions[index])
            continue;
        if (context.functions[index] != null)
            return TranslationError.DuplicateId;
        const function_type = try functionTypeDefinition(context, instruction.operands[3]);
        if (function_type.operands.len < 2 or function_type.operands[1] != instruction.operands[0])
            return TranslationError.InvalidFunctionType;
        const source_return_type = try context.translateType(instruction.operands[0]);
        const source_return = context.module.types.get(source_return_type) orelse return TranslationError.InvalidId;
        var pointer_parameters: std.ArrayList(PointerParameter) = .empty;
        defer pointer_parameters.deinit(context.scratch);
        var return_members: std.ArrayList(ir.id.TypeId) = .empty;
        defer return_members.deinit(context.scratch);
        if (source_return.* != .void)
            try return_members.append(context.scratch, source_return_type);

        for (function_type.operands[2..], 0..) |parameter_type_id, parameter_index| {
            const parameter_type = context.type_defs[try context.idIndex(parameter_type_id)] orelse return TranslationError.MissingDefinition;
            if (parameter_type.opcode != .type_pointer)
                continue;
            try expectOperandCount(parameter_type.operands, 3);
            if (parameter_type.operands[1] != @backingInt(spirv.StorageClass.function))
                continue;

            const pointee_type = try context.translateType(parameter_type.operands[2]);
            const return_member: u32 = @intCast(return_members.items.len);
            try return_members.append(context.scratch, pointee_type);
            try pointer_parameters.append(context.scratch, .{
                .parameter_index = parameter_index,
                .pointee_type = parameter_type.operands[2],
                .return_member = return_member,
            });
        }

        if (spv_function == entry_point.function_id and pointer_parameters.items.len != 0)
            return TranslationError.InvalidFunctionType;

        const lowered_return_type = if (pointer_parameters.items.len == 0)
            source_return_type
        else
            try context.builder.internType(.{ .structure = .{
                .members = return_members.items,
            } });
        const function = try context.builder.addFunction(
            lowered_return_type,
            context.nameOf(spv_function) orelse if (spv_function == entry_point.function_id) entry_name else null,
        );
        context.functions[index] = function;
        context.function_lowerings[index] = .{
            .source_return_type = source_return_type,
            .lowered_return_type = lowered_return_type,
            .pointer_parameters = try context.scratch.dupe(PointerParameter, pointer_parameters.items),
        };
        if (spv_function == entry_point.function_id)
            context.builder.setEntryPoint(function);
    }
    if (context.module.entry_point == null)
        return TranslationError.MissingFunction;
}

// Private memory lives for an invocation, not a function call. Until the IR
// models that memory (or promotion happens after inlining), only promote it in
// single-function modules. Even a global used by only one helper could retain
// state between calls, so counting its users is not sufficient.
fn validatePrivateScope(context: *Context) !void {
    var function_count: usize = 0;
    for (context.functions) |function| {
        if (function != null) function_count += 1;
    }
    if (function_count <= 1) return;
    for (context.variable_defs) |definition| {
        const variable = definition orelse continue;
        if (variable.operands[2] == @backingInt(spirv.StorageClass.private)) {
            std.log.scoped(.spirv_translator).warn("Private variable %{d} requires invocation-scoped memory in a multi-function module", .{variable.operands[1]});
            return TranslationError.UnsupportedPrivateCrossFunction;
        }
    }
}

fn translateFunctions(context: *Context) !void {
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode == .function) {
            try expectOperandCount(instruction.operands, 4);
            if (context.reachable_functions[try context.idIndex(instruction.operands[1])])
                try translateFunction(context, instruction.operands[1]);
        }
    }
}

fn translateFunction(context: *Context, spv_function: u32) !void {
    const function_instruction = try findFunction(context.parser, spv_function);
    try expectOperandCount(function_instruction.operands, 4);
    const function_type = try functionTypeDefinition(context, function_instruction.operands[3]);

    if (function_type.operands.len < 2 or function_type.operands[1] != function_instruction.operands[0])
        return TranslationError.InvalidFunctionType;

    const function = try context.function(spv_function);
    context.locals.clearRetainingCapacity();
    @memset(context.local_indices, null);
    @memset(context.composite_addresses, null);
    context.entry_label = null;
    try collectFunctionLocals(context, spv_function);
    try predeclareFunction(context, spv_function, function, function_type.operands[2..]);
    try translateFunctionInstructions(context, spv_function);
    try translateFunctionControlFlow(context, spv_function);
}

fn collectFunctionLocals(context: *Context, spv_function: u32) !void {
    const function_instruction = try findFunction(context.parser, spv_function);
    try expectOperandCount(function_instruction.operands, 4);
    const function_type = try functionTypeDefinition(context, function_instruction.operands[3]);
    const function = try context.function(spv_function);

    var active = false;
    var parameter_index: usize = 0;
    var parameter_iterator = context.parser.iterator();
    while (try parameter_iterator.next()) |instruction| {
        if (instruction.opcode == .function) {
            active = instruction.operands.len >= 2 and instruction.operands[1] == spv_function;
            continue;
        }
        if (!active)
            continue;
        if (instruction.opcode == .label or instruction.opcode == .function_end)
            break;
        if (instruction.opcode != .function_parameter)
            continue;

        try expectOperandCount(instruction.operands, 2);
        if (parameter_index + 2 >= function_type.operands.len or function_type.operands[parameter_index + 2] != instruction.operands[0])
            return TranslationError.InvalidFunctionParameter;

        const parameter_type_id = instruction.operands[0];
        const parameter_type = context.type_defs[try context.idIndex(parameter_type_id)] orelse return TranslationError.MissingDefinition;
        const is_function_pointer = parameter_type.opcode == .type_pointer and parameter_type.operands.len == 3 and
            parameter_type.operands[1] == @backingInt(spirv.StorageClass.function);
        const translated_type = if (is_function_pointer)
            try context.translateType(parameter_type.operands[2])
        else
            try context.translateType(parameter_type_id);
        const value = try context.builder.addFunctionParameter(function, translated_type, context.nameOf(instruction.operands[1]));
        try context.setValue(instruction.operands[1], value);

        if (is_function_pointer) {
            const result_index = try context.idIndex(instruction.operands[1]);
            context.function_parameter_pointees[result_index] = parameter_type.operands[2];
            context.local_indices[result_index] = context.locals.items.len;
            try context.locals.append(context.scratch, .{
                .spv_id = instruction.operands[1],
                .type = translated_type,
                .initial_value = value,
                .pointer_parameter = true,
            });
        }
        parameter_index += 1;
    }
    if (parameter_index + 2 != function_type.operands.len)
        return TranslationError.InvalidFunctionParameter;

    active = false;
    var iterator = context.parser.iterator();
    while (try iterator.next()) |instruction| {
        if (instruction.opcode == .function) {
            active = instruction.operands.len >= 2 and instruction.operands[1] == spv_function;
            continue;
        }
        if (instruction.opcode == .function_end and active)
            break;
        if (instruction.opcode != .variable)
            continue;
        const is_private = instruction.operands.len >= 3 and instruction.operands[2] == @backingInt(spirv.StorageClass.private);
        if (!active and !is_private)
            continue;

        if (instruction.operands.len < 3 or instruction.operands.len > 4)
            return TranslationError.InvalidInstruction;
        const storage_class: spirv.StorageClass = @fromBackingInt(@intCast(instruction.operands[2]));
        if (storage_class != .function and storage_class != .private)
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

        const local_type = try context.translateType(pointer.operands[2]);
        const initial_value = if (instruction.operands.len == 4)
            try context.resolveValue(instruction.operands[3])
        else
            try context.module.values.add(context.module.allocator(), .{
                .type = local_type,
                .definition = .undef,
            });
        if (context.module.typeOf(initial_value) != local_type)
            return TranslationError.InvalidInstruction;

        context.local_indices[result_index] = context.locals.items.len;
        try context.locals.append(context.scratch, .{
            .spv_id = result_id,
            .type = local_type,
            .initial_value = initial_value,
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
                        context.locals.items[local_index].initial_value
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
            .@"switch",
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

fn unsupportedStoreDestination(context: *Context, destination: u32) TranslationError {
    // Locate the result type even for pointer-producing operations that are not
    // represented in the translator's address tables.
    var storage: ?u32 = null;
    var iterator = context.parser.iterator();
    while (iterator.next() catch null) |instruction| {
        const operands = instruction.operands;

        if (operands.len < 2 or operands[1] != destination)
            continue;

        if (operands[0] == 0 or operands[0] >= context.bound)
            continue;

        const pointer = context.type_defs[operands[0]] orelse continue;
        if (pointer.opcode == .type_pointer and pointer.operands.len == 3) {
            storage = pointer.operands[1];
            break;
        }
    }

    if (storage) |value| {
        const name = std.enums.tagName(spirv.StorageClass, @fromBackingInt(@intCast(value))) orelse "unknown";
        std.log.scoped(.spirv_translator).warn("unsupported OpStore destination %{d}, storage class {s} ({d})", .{ destination, name, value });
    } else {
        std.log.scoped(.spirv_translator).warn("unsupported OpStore destination %{d}, storage class unknown", .{destination});
    }

    return TranslationError.UnsupportedStoreDestination;
}

fn translateInstruction(context: *Context, block: ir.id.BlockId, instruction: Parser.Instruction) !void {
    const operands = instruction.operands;
    switch (instruction.opcode) {
        .undef => {
            try expectOperandCount(operands, 2);
            _ = try context.translateValue(operands[1]);
        },

        .ext_inst => try translateExtendedInstruction(context, block, operands),

        .copy_object => {
            try expectOperandCount(operands, 3);
            const result_index = try context.idIndex(operands[1]);

            if (try context.sampledImage(operands[2])) |sampled_image| {
                const image = context.module.resources.get(sampled_image.image) orelse return TranslationError.InvalidId;
                if (image.type != try context.translateType(operands[0]) or context.sampled_images[result_index] != null)
                    return TranslationError.InvalidInstruction;
                context.sampled_images[result_index] = sampled_image;
                return;
            }

            if (try context.resource(operands[2])) |resource| {
                const resource_data = context.module.resources.get(resource) orelse return TranslationError.InvalidId;
                if (isImageResourceKind(resource_data.kind) or resource_data.kind == .sampler) {
                    if (resource_data.type != try context.translateType(operands[0]) or context.resources[result_index] != null)
                        return TranslationError.InvalidInstruction;
                    context.resources[result_index] = resource;
                    if (isImageResourceKind(resource_data.kind)) {
                        context.image_resources[result_index] = resource;
                        context.image_types[result_index] = context.image_types[try context.idIndex(operands[2])];
                    }
                    return;
                }
            }

            const source = try context.resolveValue(operands[2]);
            if (context.module.typeOf(source) != try context.translateType(operands[0]))
                return TranslationError.InvalidInstruction;
            try context.setValue(operands[1], source);
        },

        .load => {
            if (operands.len < 3)
                return TranslationError.InvalidInstruction;

            if (try context.sampledImage(operands[2])) |sampled_image| {
                const result_type_definition = context.type_defs[try context.idIndex(operands[0])] orelse return TranslationError.MissingDefinition;
                if (result_type_definition.opcode != .type_sampled_image)
                    return TranslationError.InvalidInstruction;
                try expectOperandCount(result_type_definition.operands, 2);
                if (result_type_definition.operands[1] != sampled_image.image_type)
                    return TranslationError.InvalidInstruction;

                const result_index = try context.idIndex(operands[1]);
                if (context.sampled_images[result_index] != null)
                    return TranslationError.DuplicateId;
                context.sampled_images[result_index] = sampled_image;
                return;
            }

            const result_type = try context.translateType(operands[0]);
            if (try context.resource(operands[2])) |resource| {
                const resource_data = context.module.resources.get(resource) orelse return TranslationError.InvalidId;
                if (isImageResourceKind(resource_data.kind) or resource_data.kind == .sampler) {
                    if (resource_data.type != result_type)
                        return TranslationError.InvalidInstruction;

                    const result_index = try context.idIndex(operands[1]);
                    if (context.resources[result_index] != null)
                        return TranslationError.DuplicateId;

                    context.resources[result_index] = resource;
                    if (isImageResourceKind(resource_data.kind)) {
                        context.image_resources[result_index] = resource;
                        context.image_types[result_index] = operands[0];
                    }
                    return;
                }
            }
            if (try context.localIndex(operands[2])) |local_index| {
                const value = context.current_locals[local_index] orelse return TranslationError.InvalidInstruction;

                if (context.module.typeOf(value) != result_type)
                    return TranslationError.InvalidInstruction;

                try context.setValue(operands[1], value);
            } else if (context.function_parameter_pointees[try context.idIndex(operands[2])]) |pointee_type| {
                const value = context.values[try context.idIndex(operands[2])] orelse return TranslationError.MissingDefinition;

                if (result_type != try context.translateType(pointee_type) or context.module.typeOf(value) != result_type)
                    return TranslationError.InvalidInstruction;

                try context.setValue(operands[1], value);
            } else if (try context.pushConstantAddress(operands[2])) |address| {
                if (result_type != try context.translateType(address.pointee_type))
                    return TranslationError.InvalidInstruction;

                const result = if (address.matrix_layout) |layout|
                    try translatePushConstantMatrixLoad(context, block, address, layout, context.nameOf(operands[1]))
                else if (address.vector_stride) |stride|
                    try translatePushConstantStridedVectorLoad(context, block, address, stride, context.nameOf(operands[1]))
                else
                    (try context.builder.appendInstruction(block, result_type, .{
                        .load_push_constant = .{ .byte_offset = try pushConstantByteOffset(context, address) },
                    }, context.nameOf(operands[1]))).?;

                try context.setValue(operands[1], result);
            } else if (try context.bufferAddress(operands[2])) |address| {
                if (result_type != try context.translateType(address.pointee_type))
                    return TranslationError.InvalidInstruction;

                const result = if (address.matrix_layout) |layout|
                    try translateBufferMatrixLoad(context, block, address, layout, context.nameOf(operands[1]))
                else if (address.vector_stride) |stride|
                    try translateBufferStridedVectorLoad(context, block, address, stride, context.nameOf(operands[1]))
                else
                    (try context.builder.appendInstruction(block, result_type, .{
                        .load_buffer = .{
                            .resource = address.resource,
                            .descriptor_index = address.descriptor_index,
                            .byte_offset = try bufferByteOffset(context, address),
                        },
                    }, context.nameOf(operands[1]))).?;

                try context.setValue(operands[1], result);
            } else if (try context.workgroupAddress(operands[2])) |address| {
                if (result_type != try context.translateType(address.pointee_type))
                    return TranslationError.InvalidInstruction;

                const result = (try context.builder.appendInstruction(block, result_type, .{
                    .load_workgroup = .{
                        .variable = address.variable,
                        .byte_offset = try workgroupByteOffset(context, address),
                    },
                }, context.nameOf(operands[1]))).?;

                try context.setValue(operands[1], result);
            } else if (try context.compositeAddress(operands[2])) |address| {
                const composite = switch (address.root) {
                    .local => |local_index| context.current_locals[local_index] orelse return TranslationError.InvalidInstruction,
                    .value => |value| value,
                    .interface => |variable| (try context.builder.appendInstruction(
                        block,
                        try context.translateType(address.root_type),
                        .{ .load_interface = .{ .variable = variable } },
                        null,
                    )).?,
                };

                const result = try extractCompositeAddress(context, block, composite, address.indices, context.nameOf(operands[1]));

                if (context.module.typeOf(result) != result_type)
                    return TranslationError.InvalidInstruction;

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
                if (context.module.typeOf(value) != try context.translateType(address.pointee_type))
                    return TranslationError.InvalidInstruction;

                if (address.matrix_layout) |layout| {
                    try translateBufferMatrixStore(context, block, address, layout, value);
                } else if (address.vector_stride) |stride| {
                    try translateBufferStridedVectorStore(context, block, address, stride, value);
                } else {
                    _ = try context.builder.appendInstruction(block, null, .{
                        .store_buffer = .{
                            .resource = address.resource,
                            .descriptor_index = address.descriptor_index,
                            .byte_offset = try bufferByteOffset(context, address),
                            .value = value,
                        },
                    }, null);
                }
            } else if (try context.workgroupAddress(operands[0])) |address| {
                if (context.module.typeOf(value) != try context.translateType(address.pointee_type))
                    return TranslationError.InvalidInstruction;

                _ = try context.builder.appendInstruction(block, null, .{
                    .store_workgroup = .{
                        .variable = address.variable,
                        .byte_offset = try workgroupByteOffset(context, address),
                        .value = value,
                    },
                }, null);
            } else if (try context.compositeAddress(operands[0])) |address| {
                if (context.module.typeOf(value) != try context.translateType(address.pointee_type))
                    return TranslationError.InvalidInstruction;

                switch (address.root) {
                    .local => try storeFunctionLvalue(context, block, operands[0], value),
                    .interface => |variable| {
                        const interface = context.module.interface_variables.get(variable).?;
                        if (interface.direction != .output)
                            return unsupportedStoreDestination(context, operands[0]);
                        const updated = if (address.indices.len == 0)
                            value
                        else blk: {
                            const composite = (try context.builder.appendInstruction(block, interface.type, .{
                                .load_interface = .{ .variable = variable },
                            }, null)).?;
                            break :blk try insertCompositeAddress(context, block, composite, value, address.indices);
                        };
                        _ = try context.builder.appendInstruction(block, null, .{
                            .store_interface = .{ .variable = variable, .value = updated },
                        }, null);
                    },
                    .value => return unsupportedStoreDestination(context, operands[0]),
                }
            } else {
                const variable = context.interfaces[try context.idIndex(operands[0])] orelse
                    return unsupportedStoreDestination(context, operands[0]);
                _ = try context.builder.appendInstruction(block, null, .{
                    .store_interface = .{
                        .variable = variable,
                        .value = value,
                    },
                }, null);
            }
        },

        .access_chain => try translateAccessChain(context, block, operands),
        .vector_shuffle => try translateVectorShuffle(context, block, operands),

        .sampled_image => {
            try expectOperandCount(operands, 4);
            const result_type = context.type_defs[try context.idIndex(operands[0])] orelse return TranslationError.MissingDefinition;
            if (result_type.opcode != .type_sampled_image)
                return TranslationError.InvalidInstruction;

            try expectOperandCount(result_type.operands, 2);

            const image_id = (try context.resource(operands[2])) orelse return TranslationError.UnsupportedOpcode;
            const sampler_id = (try context.resource(operands[3])) orelse return TranslationError.UnsupportedOpcode;
            const image = context.module.resources.get(image_id) orelse return TranslationError.InvalidId;
            const sampler = context.module.resources.get(sampler_id) orelse return TranslationError.InvalidId;
            if ((image.kind != .sampled_image and image.kind != .uniform_texel_buffer) or sampler.kind != .sampler or image.type != try context.translateType(result_type.operands[1]))
                return TranslationError.InvalidInstruction;

            const result_index = try context.idIndex(operands[1]);
            if (context.sampled_images[result_index] != null)
                return TranslationError.DuplicateId;

            context.sampled_images[result_index] = .{
                .image = image_id,
                .sampler = sampler_id,
                .image_type = result_type.operands[1],
            };
        },

        .image_sample_implicit_lod => {
            if (operands.len != 4)
                return TranslationError.UnsupportedOpcode;

            const sampled_image = (try context.sampledImage(operands[2])) orelse return TranslationError.UnsupportedOpcode;
            const image_info = try imageTypeInfo(context, sampled_image.image_type);
            if (image_info.dimension == .buffer)
                return TranslationError.UnsupportedOpcode;
            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .image_sample_implicit_lod = .{
                    .image = sampled_image.image,
                    .sampler = sampled_image.sampler orelse return TranslationError.UnsupportedOpcode,
                    .coordinate = try context.resolveValue(operands[3]),
                    .dimension = image_info.dimension,
                    .arrayed = image_info.arrayed,
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },

        .image_gather => {
            if (operands.len != 5)
                return TranslationError.UnsupportedOpcode;

            const sampled_image = (try context.sampledImage(operands[2])) orelse return TranslationError.UnsupportedOpcode;
            const image_info = try imageTypeInfo(context, sampled_image.image_type);
            if (image_info.dimension == .buffer)
                return TranslationError.UnsupportedOpcode;
            if (image_info.dimension != .two_d or image_info.arrayed)
                return TranslationError.UnsupportedOpcode;

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .image_gather = .{
                    .image = sampled_image.image,
                    .sampler = sampled_image.sampler orelse return TranslationError.UnsupportedOpcode,
                    .coordinate = try context.resolveValue(operands[3]),
                    .component = try context.resolveValue(operands[4]),
                    .dimension = image_info.dimension,
                    .arrayed = image_info.arrayed,
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },

        .image_sample_explicit_lod => {
            if (operands.len != 6 or operands[4] != 0x2)
                return TranslationError.UnsupportedOpcode;

            const sampled_image = (try context.sampledImage(operands[2])) orelse return TranslationError.UnsupportedOpcode;
            const image_info = try imageTypeInfo(context, sampled_image.image_type);
            if (image_info.dimension == .buffer)
                return TranslationError.UnsupportedOpcode;
            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .image_sample_explicit_lod = .{
                    .image = sampled_image.image,
                    .sampler = sampled_image.sampler orelse return TranslationError.UnsupportedOpcode,
                    .coordinate = try context.resolveValue(operands[3]),
                    .lod = try context.resolveValue(operands[5]),
                    .dimension = image_info.dimension,
                    .arrayed = image_info.arrayed,
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },

        .image => {
            try expectOperandCount(operands, 3);
            const sampled_image = (try context.sampledImage(operands[2])) orelse return TranslationError.UnsupportedOpcode;
            if (operands[0] != sampled_image.image_type)
                return TranslationError.InvalidInstruction;

            const result_index = try context.idIndex(operands[1]);
            if (context.resources[result_index] != null or context.image_resources[result_index] != null)
                return TranslationError.DuplicateId;

            context.resources[result_index] = sampled_image.image;
            context.image_resources[result_index] = sampled_image.image;
            context.image_types[result_index] = sampled_image.image_type;
        },

        .image_fetch => {
            if (operands.len < 4)
                return TranslationError.InvalidInstruction;

            const resource = (try context.imageResource(operands[2])) orelse return TranslationError.UnsupportedOpcode;
            const image_type = context.image_types[try context.idIndex(operands[2])] orelse return TranslationError.MissingDefinition;
            const image_info = try imageTypeInfo(context, image_type);
            if (image_info.dimension == .cube)
                return TranslationError.UnsupportedOpcode;

            const lod: ?ir.id.ValueId = if (image_info.dimension == .buffer) blk: {
                if (operands.len != 4)
                    return TranslationError.UnsupportedOpcode;
                break :blk null;
            } else blk: {
                if (operands.len == 4)
                    break :blk try context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = 0 });
                if (operands.len != 6 or operands[4] != 0x2)
                    return TranslationError.UnsupportedOpcode;
                break :blk try context.resolveValue(operands[5]);
            };

            const coordinate = try canonicalizeImageCoordinate(context, block, operands[3], image_info);
            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .image_fetch = .{
                    .resource = resource,
                    .coordinate = coordinate,
                    .lod = lod,
                    .dimension = image_info.dimension,
                    .arrayed = image_info.arrayed,
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },

        .image_read => {
            if (operands.len < 4)
                return TranslationError.InvalidInstruction;

            const resource = (try context.imageResource(operands[2])) orelse return TranslationError.UnsupportedOpcode;
            const image_type = context.image_types[try context.idIndex(operands[2])] orelse return TranslationError.MissingDefinition;
            const image_info = try imageTypeInfo(context, image_type);
            const coordinate = try canonicalizeImageCoordinate(context, block, operands[3], image_info);
            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .image_read = .{
                    .resource = resource,
                    .coordinate = coordinate,
                    .dimension = image_info.dimension,
                    .arrayed = image_info.arrayed,
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },

        .image_write => {
            if (operands.len < 3)
                return TranslationError.InvalidInstruction;

            const resource = (try context.imageResource(operands[0])) orelse return TranslationError.UnsupportedOpcode;
            const image_type = context.image_types[try context.idIndex(operands[0])] orelse return TranslationError.MissingDefinition;
            const image_info = try imageTypeInfo(context, image_type);
            const coordinate = try canonicalizeImageCoordinate(context, block, operands[1], image_info);
            _ = try context.builder.appendInstruction(block, null, .{ .image_write = .{
                .resource = resource,
                .coordinate = coordinate,
                .value = try context.resolveValue(operands[2]),
                .dimension = image_info.dimension,
                .arrayed = image_info.arrayed,
            } }, null);
        },

        .image_texel_pointer => {
            try expectOperandCount(operands, 5);
            const resource = (try context.imageResource(operands[2])) orelse return TranslationError.UnsupportedOpcode;

            if (try constantIndex(context, operands[4]) != 0)
                return TranslationError.UnsupportedOpcode;

            const index = try context.idIndex(operands[1]);

            if (context.image_addresses[index] != null)
                return TranslationError.DuplicateId;

            const image_type = context.image_types[try context.idIndex(operands[2])] orelse return TranslationError.MissingDefinition;
            const image_info = try imageTypeInfo(context, image_type);
            context.image_addresses[index] = .{
                .resource = resource,
                .coordinate = try context.resolveValue(operands[3]),
                .dimension = image_info.dimension,
                .arrayed = image_info.arrayed,
            };
        },

        .memory_barrier => {
            try expectOperandCount(operands, 2);
            _ = try constantIndex(context, operands[0]);
            _ = try constantIndex(context, operands[1]);
        },
        .control_barrier => {
            try expectOperandCount(operands, 3);
            const execution_scope = try constantIndex(context, operands[0]);
            const memory_scope = try constantIndex(context, operands[1]);
            _ = try constantIndex(context, operands[2]);
            if (execution_scope != 2 or (memory_scope != 1 and memory_scope != 2))
                return TranslationError.UnsupportedOpcode;
            _ = try context.builder.appendInstruction(block, null, .control_barrier, null);
            context.module.properties.uses_control_barriers = true;
        },

        .atomic_i_add => try translateAtomicIAdd(context, block, operands),
        .atomic_exchange => try translateAtomicExchange(context, block, operands),

        .all,
        .any,
        .d_pdx,
        .d_pdy,
        .f_negate,
        .fwidth,
        .is_inf,
        .is_nan,
        .logical_not,
        .not,
        .s_negate,
        .transpose,
        .bit_reverse,
        .bit_count,
        => {
            try expectOperandCount(operands, 3);

            const opcode: ir.instruction.UnaryOpcode = switch (instruction.opcode) {
                .all => .all,
                .any => .any,
                .d_pdx => .d_pdx,
                .d_pdy => .d_pdy,
                .fwidth => .fwidth,
                .is_inf => .is_inf,
                .is_nan => .is_nan,
                .logical_not => .logical_not,
                .not => .bitwise_not,
                .transpose => .transpose,
                .bit_reverse => .bit_reverse,
                .bit_count => .bit_count,

                .f_negate,
                .s_negate,
                => .negate,

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

        .vector_extract_dynamic => {
            try expectOperandCount(operands, 4);
            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .binary = .{
                    .opcode = .vector_extract_dynamic,
                    .lhs = try context.resolveValue(operands[2]),
                    .rhs = try context.resolveValue(operands[3]),
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },

        .vector_times_scalar => {
            try expectOperandCount(operands, 4);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .binary = .{
                    .opcode = .vector_times_scalar,
                    .lhs = try context.resolveValue(operands[2]),
                    .rhs = try context.resolveValue(operands[3]),
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },
        .vector_times_matrix => {
            try expectOperandCount(operands, 4);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .binary = .{
                    .opcode = .vector_times_matrix,
                    .lhs = try context.resolveValue(operands[2]),
                    .rhs = try context.resolveValue(operands[3]),
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },

        .matrix_times_matrix => {
            try expectOperandCount(operands, 4);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .binary = .{
                    .opcode = .matrix_times_matrix,
                    .lhs = try context.resolveValue(operands[2]),
                    .rhs = try context.resolveValue(operands[3]),
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },
        .matrix_times_scalar => {
            try expectOperandCount(operands, 4);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .binary = .{
                    .opcode = .matrix_times_scalar,
                    .lhs = try context.resolveValue(operands[2]),
                    .rhs = try context.resolveValue(operands[3]),
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },
        .matrix_times_vector => {
            try expectOperandCount(operands, 4);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .binary = .{
                    .opcode = .matrix_times_vector,
                    .lhs = try context.resolveValue(operands[2]),
                    .rhs = try context.resolveValue(operands[3]),
                },
            }, context.nameOf(operands[1]))).?;
            try context.setValue(operands[1], result);
        },

        .i_add_carry,
        .i_sub_borrow,
        .u_mul_extended,
        .s_mul_extended,
        .f_rem,
        .dot,
        .outer_product,
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

        .bit_field_s_extract,
        .bit_field_u_extract,
        => {
            try expectOperandCount(operands, 5);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .bit_field_extract = .{
                    .opcode = switch (instruction.opcode) {
                        .bit_field_s_extract => .signed,
                        .bit_field_u_extract => .unsigned,
                        else => unreachable,
                    },
                    .base = try context.resolveValue(operands[2]),
                    .offset = try context.resolveValue(operands[3]),
                    .count = try context.resolveValue(operands[4]),
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },

        .bit_field_insert => {
            try expectOperandCount(operands, 6);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .bit_field_insert = .{
                    .base = try context.resolveValue(operands[2]),
                    .insert = try context.resolveValue(operands[3]),
                    .offset = try context.resolveValue(operands[4]),
                    .count = try context.resolveValue(operands[5]),
                },
            }, context.nameOf(operands[1]))).?;

            try context.setValue(operands[1], result);
        },

        .logical_equal,
        .logical_not_equal,
        .i_equal,
        .i_not_equal,
        .u_greater_than,
        .s_greater_than,
        .u_greater_than_equal,
        .s_greater_than_equal,
        .u_less_than,
        .s_less_than,
        .u_less_than_equal,
        .s_less_than_equal,
        .f_ord_equal,
        .f_unord_equal,
        .f_ord_not_equal,
        .f_unord_not_equal,
        .f_ord_less_than,
        .f_unord_less_than,
        .f_ord_greater_than,
        .f_unord_greater_than,
        .f_ord_less_than_equal,
        .f_unord_less_than_equal,
        .f_ord_greater_than_equal,
        .f_unord_greater_than_equal,
        => {
            try expectOperandCount(operands, 4);

            const lowering = translateComparison(instruction.opcode);
            const result_type = try context.translateType(operands[0]);
            const comparison = (try context.builder.appendInstruction(block, result_type, .{
                .compare = .{
                    .opcode = lowering.opcode,
                    .lhs = try context.resolveValue(operands[if (lowering.reverse_operands) 3 else 2]),
                    .rhs = try context.resolveValue(operands[if (lowering.reverse_operands) 2 else 3]),
                },
            }, if (lowering.negate_result) null else context.nameOf(operands[1]))).?;

            const result = if (lowering.negate_result)
                (try context.builder.appendInstruction(block, result_type, .{
                    .unary = .{
                        .opcode = .logical_not,
                        .operand = comparison,
                    },
                }, context.nameOf(operands[1]))).?
            else
                comparison;
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

        .convert_f_to_s,
        .convert_f_to_u,
        .convert_s_to_f,
        .convert_u_to_f,
        => {
            try expectOperandCount(operands, 3);

            const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
                .convert = .{
                    .opcode = switch (instruction.opcode) {
                        .convert_f_to_s => .float_to_signed,
                        .convert_f_to_u => .float_to_unsigned,
                        .convert_s_to_f => .signed_to_float,
                        .convert_u_to_f => .unsigned_to_float,
                        else => unreachable,
                    },
                    .operand = try context.resolveValue(operands[2]),
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

        .function_call => {
            if (operands.len < 3)
                return TranslationError.InvalidInstruction;

            const lowering = context.function_lowerings[try context.idIndex(operands[2])] orelse return TranslationError.MissingFunction;
            const arguments = try context.scratch.alloc(ir.id.ValueId, operands.len - 3);
            for (operands[3..], arguments, 0..) |argument, *translated, parameter_index| {
                var pointer_parameter = false;
                for (lowering.pointer_parameters) |pointer| {
                    if (pointer.parameter_index == parameter_index) {
                        pointer_parameter = true;
                        break;
                    }
                }
                translated.* = if (pointer_parameter)
                    try loadFunctionLvalue(context, block, argument)
                else
                    try context.resolveValue(argument);
            }

            const source_return = context.module.types.get(lowering.source_return_type) orelse return TranslationError.InvalidId;
            const result = try context.builder.appendInstruction(block, if (lowering.pointer_parameters.len != 0 or source_return.* != .void) lowering.lowered_return_type else null, .{
                .call = .{
                    .function = try context.function(operands[2]),
                    .arguments = arguments,
                },
            }, if (lowering.pointer_parameters.len == 0) context.nameOf(operands[1]) else null);

            if (lowering.pointer_parameters.len == 0) {
                if (result) |value|
                    try context.setValue(operands[1], value);
            } else {
                const bundle = result orelse return TranslationError.InvalidInstruction;
                if (source_return.* != .void) {
                    const source_result = (try context.builder.appendInstruction(block, lowering.source_return_type, .{
                        .composite_extract = .{ .composite = bundle, .indices = &.{0} },
                    }, context.nameOf(operands[1]))).?;
                    try context.setValue(operands[1], source_result);
                }
                for (lowering.pointer_parameters) |pointer| {
                    const output = (try context.builder.appendInstruction(block, try context.translateType(pointer.pointee_type), .{
                        .composite_extract = .{ .composite = bundle, .indices = &.{pointer.return_member} },
                    }, null)).?;
                    try storeFunctionLvalue(context, block, operands[3 + pointer.parameter_index], output);
                }
            }
        },

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

fn translateExtendedInstruction(context: *Context, block: ir.id.BlockId, operands: []const u32) !void {
    if (operands.len < 4)
        return TranslationError.InvalidInstruction;

    const set_index = try context.idIndex(operands[2]);
    const set = context.extended_instruction_sets[set_index] orelse return TranslationError.InvalidInstruction;
    try extensions.validateSupported(set);

    const resolved_operands = try context.scratch.alloc(ir.id.ValueId, operands.len - 4);
    for (operands[4..], resolved_operands) |operand, *resolved|
        resolved.* = try context.resolveValue(operand);

    var emitter: extensions.Emitter = .{
        .module = context.module,
        .builder = &context.builder,
        .scratch = context.scratch,
        .block = block,
    };
    const result = try extensions.translate(set, &emitter, .{
        .result_type = try context.translateType(operands[0]),
        .result_name = context.nameOf(operands[1]),
        .opcode = operands[3],
        .operands = resolved_operands,
    });
    try context.setValue(operands[1], result);
}

fn translateVectorShuffle(context: *Context, block: ir.id.BlockId, operands: []const u32) !void {
    if (operands.len < 5)
        return TranslationError.InvalidInstruction;
    const first = try context.resolveValue(operands[2]);
    const second = try context.resolveValue(operands[3]);
    const first_type = context.module.types.get(context.module.typeOf(first) orelse return TranslationError.InvalidId) orelse return TranslationError.InvalidId;
    const second_type = context.module.types.get(context.module.typeOf(second) orelse return TranslationError.InvalidId) orelse return TranslationError.InvalidId;
    const first_vector = if (first_type.* == .vector) first_type.vector else return TranslationError.UnsupportedType;
    const second_vector = if (second_type.* == .vector) second_type.vector else return TranslationError.UnsupportedType;
    if (first_vector.element_type != second_vector.element_type)
        return TranslationError.InvalidInstruction;
    const elements = try context.scratch.alloc(ir.id.ValueId, operands.len - 4);
    for (operands[4..], elements) |selector, *element| {
        const selected = if (selector < first_vector.length)
            .{ first, selector }
        else if (selector < @as(u32, first_vector.length) + second_vector.length)
            .{ second, selector - first_vector.length }
        else
            return TranslationError.UnsupportedOpcode;
        element.* = (try context.builder.appendInstruction(block, first_vector.element_type, .{
            .composite_extract = .{ .composite = selected[0], .indices = &.{selected[1]} },
        }, null)).?;
    }
    const result = (try context.builder.appendInstruction(block, try context.translateType(operands[0]), .{
        .composite_construct = .{ .elements = elements },
    }, context.nameOf(operands[1]))).?;
    try context.setValue(operands[1], result);
}

fn translateAtomicIAdd(context: *Context, block: ir.id.BlockId, operands: []const u32) !void {
    try expectOperandCount(operands, 6);

    if (try context.imageAddress(operands[2])) |address|
        return translateImageAtomicIAdd(context, block, operands, address);

    const address: AtomicAddress = if (try context.bufferAddress(operands[2])) |buffer|
        .{ .buffer = buffer }
    else if (try context.workgroupAddress(operands[2])) |workgroup|
        .{ .workgroup = workgroup }
    else
        return TranslationError.UnsupportedOpcode;
    _ = try constantIndex(context, operands[3]);
    _ = try constantIndex(context, operands[4]);

    const pointee_type = switch (address) {
        .buffer => |item| item.pointee_type,
        .workgroup => |item| item.pointee_type,
    };
    const result_type = try context.translateType(operands[0]);
    if (result_type != try context.translateType(pointee_type))
        return TranslationError.InvalidInstruction;
    const result_type_definition = context.module.types.get(result_type) orelse return TranslationError.InvalidId;
    switch (result_type_definition.*) {
        .integer => |integer| if (integer.bits != 32) return TranslationError.UnsupportedType,
        else => return TranslationError.UnsupportedType,
    }

    const value = try context.resolveValue(operands[5]);
    if (context.module.typeOf(value) != result_type)
        return TranslationError.InvalidInstruction;
    const previous = (try context.builder.appendInstruction(block, result_type, switch (address) {
        .buffer => |item| .{
            .load_buffer = .{
                .resource = item.resource,
                .descriptor_index = item.descriptor_index,
                .byte_offset = try bufferByteOffset(context, item),
            },
        },
        .workgroup => |item| .{ .load_workgroup = .{
            .variable = item.variable,
            .byte_offset = try workgroupByteOffset(context, item),
        } },
    }, context.nameOf(operands[1]))).?;
    const updated = (try context.builder.appendInstruction(block, result_type, .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = previous,
            .rhs = value,
        },
    }, null)).?;
    _ = try context.builder.appendInstruction(block, null, switch (address) {
        .buffer => |item| .{
            .store_buffer = .{
                .resource = item.resource,
                .descriptor_index = item.descriptor_index,
                .byte_offset = try bufferByteOffset(context, item),
                .value = updated,
            },
        },
        .workgroup => |item| .{ .store_workgroup = .{
            .variable = item.variable,
            .byte_offset = try workgroupByteOffset(context, item),
            .value = updated,
        } },
    }, null);

    try context.setValue(operands[1], previous);
    context.module.properties.uses_atomics = true;
}

fn translateAtomicExchange(context: *Context, block: ir.id.BlockId, operands: []const u32) !void {
    try expectOperandCount(operands, 6);
    _ = try constantIndex(context, operands[3]);
    _ = try constantIndex(context, operands[4]);

    const result_type = try context.translateType(operands[0]);
    const value = try context.resolveValue(operands[5]);
    if (context.module.typeOf(value) != result_type)
        return TranslationError.InvalidInstruction;

    if (try context.bufferAddress(operands[2])) |address| {
        if (result_type != try context.translateType(address.pointee_type))
            return TranslationError.InvalidInstruction;
        const previous = (try context.builder.appendInstruction(block, result_type, .{ .load_buffer = .{
            .resource = address.resource,
            .descriptor_index = address.descriptor_index,
            .byte_offset = try bufferByteOffset(context, address),
        } }, context.nameOf(operands[1]))).?;
        _ = try context.builder.appendInstruction(block, null, .{
            .store_buffer = .{
                .resource = address.resource,
                .descriptor_index = address.descriptor_index,
                .byte_offset = try bufferByteOffset(context, address),
                .value = value,
            },
        }, null);
        try context.setValue(operands[1], previous);
    } else if (try context.workgroupAddress(operands[2])) |address| {
        if (result_type != try context.translateType(address.pointee_type))
            return TranslationError.InvalidInstruction;
        const previous = (try context.builder.appendInstruction(block, result_type, .{ .load_workgroup = .{
            .variable = address.variable,
            .byte_offset = try workgroupByteOffset(context, address),
        } }, context.nameOf(operands[1]))).?;
        _ = try context.builder.appendInstruction(block, null, .{ .store_workgroup = .{
            .variable = address.variable,
            .byte_offset = try workgroupByteOffset(context, address),
            .value = value,
        } }, null);
        try context.setValue(operands[1], previous);
    } else {
        return TranslationError.UnsupportedOpcode;
    }
    context.module.properties.uses_atomics = true;
}

fn translateImageAtomicIAdd(context: *Context, block: ir.id.BlockId, operands: []const u32, address: ImageAddress) !void {
    _ = try constantIndex(context, operands[3]);
    _ = try constantIndex(context, operands[4]);

    const result_type = try context.translateType(operands[0]);
    const result_type_definition = context.module.types.get(result_type) orelse return TranslationError.InvalidId;
    switch (result_type_definition.*) {
        .integer => |integer| if (integer.bits != 32 or integer.signedness != .unsigned) return TranslationError.UnsupportedType,
        else => return TranslationError.UnsupportedType,
    }
    const value = try context.resolveValue(operands[5]);
    if (context.module.typeOf(value) != result_type)
        return TranslationError.InvalidInstruction;

    const vector_type = try context.builder.internType(.{ .vector = .{
        .element_type = result_type,
        .length = 4,
    } });
    const previous_vector = (try context.builder.appendInstruction(block, vector_type, .{ .image_read = .{
        .resource = address.resource,
        .coordinate = address.coordinate,
        .dimension = address.dimension,
        .arrayed = address.arrayed,
    } }, null)).?;
    var components: [4]ir.id.ValueId = undefined;
    for (&components, 0..) |*component, index| {
        component.* = (try context.builder.appendInstruction(block, result_type, .{ .composite_extract = .{
            .composite = previous_vector,
            .indices = &.{@as(u32, @intCast(index))},
        } }, if (index == 0) context.nameOf(operands[1]) else null)).?;
    }
    const previous = components[0];
    const updated = (try context.builder.appendInstruction(block, result_type, .{ .binary = .{
        .opcode = .integer_add,
        .lhs = previous,
        .rhs = value,
    } }, null)).?;
    components[0] = updated;
    const updated_vector = (try context.builder.appendInstruction(block, vector_type, .{ .composite_construct = .{
        .elements = &components,
    } }, null)).?;
    _ = try context.builder.appendInstruction(block, null, .{ .image_write = .{
        .resource = address.resource,
        .coordinate = address.coordinate,
        .value = updated_vector,
        .dimension = address.dimension,
        .arrayed = address.arrayed,
    } }, null);

    try context.setValue(operands[1], previous);
    context.module.properties.uses_atomics = true;
}

fn translateAccessChain(context: *Context, block: ir.id.BlockId, operands: []const u32) !void {
    if (operands.len < 4)
        return TranslationError.InvalidInstruction;

    if (try context.bufferAddress(operands[2])) |base|
        return translateBufferAccessChain(context, block, operands, base, 3);

    if (try context.workgroupAddress(operands[2])) |base|
        return translateWorkgroupAccessChain(context, block, operands, base);

    if (context.sampled_image_arrays[try context.idIndex(operands[2])]) |sampled_images| {
        try expectOperandCount(operands, 4);
        const index = try context.resolveValue(operands[3]);
        if (context.module.values.get(index).?.definition != .constant) {
            std.log.scoped(.spirv_translator).warn("dynamic combined sampled-image descriptor array indexing is unsupported for %{d}", .{operands[2]});
            return TranslationError.UnsupportedOpcode;
        }
        const array_element: usize = try constantIndex(context, operands[3]);
        if (array_element >= sampled_images.len)
            return TranslationError.InvalidInstruction;
        const sampled_image = sampled_images[array_element];
        const pointer = context.type_defs[try context.idIndex(operands[0])] orelse return TranslationError.MissingDefinition;
        if (pointer.opcode != .type_pointer)
            return TranslationError.InvalidInstruction;
        try expectOperandCount(pointer.operands, 3);
        if (pointer.operands[1] != @backingInt(spirv.StorageClass.uniform_constant))
            return TranslationError.InvalidInstruction;
        const pointee = context.type_defs[try context.idIndex(pointer.operands[2])] orelse return TranslationError.MissingDefinition;
        if (pointee.opcode != .type_sampled_image)
            return TranslationError.InvalidInstruction;
        try expectOperandCount(pointee.operands, 2);
        if (pointee.operands[1] != sampled_image.image_type)
            return TranslationError.InvalidInstruction;
        const result_index = try context.idIndex(operands[1]);
        if (context.sampled_images[result_index] != null)
            return TranslationError.DuplicateId;
        context.sampled_images[result_index] = sampled_image;
        return;
    }

    if (try context.descriptorArray(operands[2])) |descriptor_array| {
        if (descriptor_array.resources.len == 0)
            return TranslationError.InvalidInstruction;
        const index_value = try context.resolveValue(operands[3]);
        const index_definition = context.module.values.get(index_value) orelse return TranslationError.InvalidId;
        if (index_definition.definition == .constant) {
            const array_element: usize = try constantIndex(context, operands[3]);
            if (array_element >= descriptor_array.resources.len)
                return TranslationError.InvalidInstruction;
            return translateBufferAccessChain(context, block, operands, .{
                .resource = descriptor_array.resources[array_element],
                .byte_offset = null,
                .pointee_type = descriptor_array.element_type,
            }, 4);
        }
        return translateBufferAccessChain(context, block, operands, .{
            .resource = descriptor_array.resources[0],
            .descriptor_index = try unsignedOffsetValue(context, block, operands[3]),
            .byte_offset = null,
            .pointee_type = descriptor_array.element_type,
        }, 4);
    }

    if (try context.pushConstantAddress(operands[2])) |base|
        return translatePushConstantAccessChain(context, block, operands, base);

    try translateCompositeAccessChain(context, operands);
}

fn translateBufferAccessChain(context: *Context, block: ir.id.BlockId, operands: []const u32, base: BufferAddress, first_index: usize) !void {
    var current_type = base.pointee_type;
    var byte_offset = base.byte_offset;
    var matrix_layout = base.matrix_layout;
    var vector_stride = base.vector_stride;

    for (operands[first_index..]) |index_id| {
        const type_definition = context.type_defs[try context.idIndex(current_type)] orelse return TranslationError.MissingDefinition;
        switch (type_definition.opcode) {
            .type_struct => {
                const member = try constantIndex(context, index_id);
                if (member + 1 >= type_definition.operands.len)
                    return TranslationError.InvalidInstruction;
                const member_offset = try findMemberOffset(context, current_type, member);
                matrix_layout = try findMemberMatrixLayout(context, current_type, member);
                vector_stride = null;

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
                byte_offset = try addByteOffset(context, block, byte_offset, try scaledByteOffset(context, block, index, stride));
                current_type = type_definition.operands[1];
            },
            .type_matrix => {
                const layout = matrix_layout orelse return TranslationError.InvalidInstruction;
                const info = try matrixTypeInfo(context, current_type);
                const stride = if (layout.major == .column) layout.stride else info.element_size;
                byte_offset = try addIndexedByteOffset(context, block, byte_offset, index_id, stride);
                vector_stride = if (layout.major == .row) layout.stride else null;
                matrix_layout = null;
                current_type = type_definition.operands[1];
            },
            .type_vector => {
                try expectOperandCount(type_definition.operands, 3);

                const element_type = type_definition.operands[1];
                const stride = vector_stride orelse try workgroupTypeSize(context, element_type);
                byte_offset = try addIndexedByteOffset(context, block, byte_offset, index_id, stride);
                vector_stride = null;
                matrix_layout = null;
                current_type = element_type;
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
        .descriptor_index = base.descriptor_index,
        .byte_offset = byte_offset,
        .pointee_type = current_type,
        .matrix_layout = matrix_layout,
        .vector_stride = vector_stride,
    };
}

fn translatePushConstantAccessChain(context: *Context, block: ir.id.BlockId, operands: []const u32, base: PushConstantAddress) !void {
    var current_type = base.pointee_type;
    var byte_offset = base.byte_offset;
    var matrix_layout = base.matrix_layout;
    var vector_stride = base.vector_stride;

    for (operands[3..]) |index_id| {
        const type_definition = context.type_defs[try context.idIndex(current_type)] orelse return TranslationError.MissingDefinition;
        switch (type_definition.opcode) {
            .type_struct => {
                const member = try constantIndex(context, index_id);
                if (member + 1 >= type_definition.operands.len)
                    return TranslationError.InvalidInstruction;
                const member_offset = try findMemberOffset(context, current_type, member);
                matrix_layout = try findMemberMatrixLayout(context, current_type, member);
                vector_stride = null;
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
                byte_offset = try addByteOffset(context, block, byte_offset, try scaledByteOffset(context, block, index, stride));
                current_type = type_definition.operands[1];
            },
            .type_matrix => {
                const layout = matrix_layout orelse return TranslationError.InvalidInstruction;
                const info = try matrixTypeInfo(context, current_type);
                const stride = if (layout.major == .column) layout.stride else info.element_size;
                byte_offset = try addIndexedByteOffset(context, block, byte_offset, index_id, stride);
                vector_stride = if (layout.major == .row) layout.stride else null;
                matrix_layout = null;
                current_type = type_definition.operands[1];
            },
            .type_vector => {
                try expectOperandCount(type_definition.operands, 3);
                const element_type = type_definition.operands[1];
                const stride = vector_stride orelse try workgroupTypeSize(context, element_type);
                byte_offset = try addIndexedByteOffset(context, block, byte_offset, index_id, stride);
                vector_stride = null;
                matrix_layout = null;
                current_type = element_type;
            },
            else => return TranslationError.UnsupportedType,
        }
    }

    const result_pointer = context.type_defs[try context.idIndex(operands[0])] orelse return TranslationError.MissingDefinition;
    if (result_pointer.opcode != .type_pointer)
        return TranslationError.InvalidInstruction;
    try expectOperandCount(result_pointer.operands, 3);
    if (result_pointer.operands[1] != @backingInt(spirv.StorageClass.push_constant) or result_pointer.operands[2] != current_type)
        return TranslationError.InvalidInstruction;

    const result_index = try context.idIndex(operands[1]);
    if (context.push_constant_addresses[result_index] != null)
        return TranslationError.DuplicateId;
    context.push_constant_addresses[result_index] = .{
        .byte_offset = byte_offset,
        .pointee_type = current_type,
        .matrix_layout = matrix_layout,
        .vector_stride = vector_stride,
    };
}

fn translateWorkgroupAccessChain(context: *Context, block: ir.id.BlockId, operands: []const u32, base: WorkgroupAddress) !void {
    var current_type = base.pointee_type;
    var byte_offset = base.byte_offset;

    for (operands[3..]) |index_id| {
        const type_definition = context.type_defs[try context.idIndex(current_type)] orelse return TranslationError.MissingDefinition;
        switch (type_definition.opcode) {
            .type_struct => {
                const member = try constantIndex(context, index_id);

                if (member + 1 >= type_definition.operands.len)
                    return TranslationError.InvalidInstruction;

                var member_offset: u32 = 0;
                for (type_definition.operands[1 .. member + 1]) |member_type|
                    member_offset = std.math.add(u32, member_offset, try workgroupTypeSize(context, member_type)) catch return TranslationError.UnsupportedType;

                if (member_offset != 0) {
                    const term = try context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = member_offset });
                    byte_offset = try addByteOffset(context, block, byte_offset, term);
                }
                current_type = type_definition.operands[member + 1];
            },
            .type_array, .type_vector => {
                try expectOperandCount(type_definition.operands, 3);
                const element_type = type_definition.operands[1];
                const stride = try workgroupTypeSize(context, element_type);
                const index = try unsignedOffsetValue(context, block, index_id);
                byte_offset = try addByteOffset(context, block, byte_offset, try scaledByteOffset(context, block, index, stride));
                current_type = element_type;
            },
            else => return TranslationError.UnsupportedType,
        }
    }

    const result_pointer = context.type_defs[try context.idIndex(operands[0])] orelse return TranslationError.MissingDefinition;
    if (result_pointer.opcode != .type_pointer)
        return TranslationError.InvalidInstruction;
    try expectOperandCount(result_pointer.operands, 3);
    if (result_pointer.operands[1] != @backingInt(spirv.StorageClass.workgroup) or result_pointer.operands[2] != current_type)
        return TranslationError.InvalidInstruction;

    const result_index = try context.idIndex(operands[1]);
    if (context.workgroup_addresses[result_index] != null)
        return TranslationError.DuplicateId;
    context.workgroup_addresses[result_index] = .{
        .variable = base.variable,
        .byte_offset = byte_offset,
        .pointee_type = current_type,
    };
}

fn translateCompositeAccessChain(context: *Context, operands: []const u32) !void {
    var first_index: usize = 3;
    var member_address: ?CompositeAddress = null;
    for (context.interface_blocks.items) |interface_block| {
        if (interface_block.variable != operands[2])
            continue;

        const member = try constantIndex(context, operands[3]);
        const structure = context.type_defs[try context.idIndex(interface_block.structure_id)].?;

        if (member >= structure.operands.len - 1)
            return TranslationError.InvalidInstruction;

        const member_type = structure.operands[member + 1];
        const key = (@as(u64, operands[2]) << 32) | member;

        const binding = context.member_bindings.get(key) orelse binding: {
            for (context.member_interfaces.items) |info| {
                if (info.structure_id != interface_block.structure_id or info.member != member)
                    continue;

                const decoration = info.decoration;

                if (decoration.location != null and decoration.builtin != null)
                    return TranslationError.InvalidInstruction;

                const semantic: ir.module.InterfaceSemantic = if (decoration.builtin) |builtin|
                    .{ .builtin = try translateBuiltin(std.enums.fromInt(spirv.Builtin, builtin) orelse return TranslationError.UnsupportedOpcode) }
                else if (decoration.location) |location|
                    .{ .location = .{ .location = location, .component = decoration.component, .index = decoration.index } }
                else
                    return TranslationError.UnsupportedOpcode;

                const variable = try context.builder.addInterfaceVariable(try context.translateType(member_type), interface_block.direction, semantic, null);
                try context.member_bindings.put(context.scratch, key, variable);
                break :binding variable;
            }
            return TranslationError.UnsupportedOpcode;
        };

        member_address = .{ .root = .{ .interface = binding }, .root_type = member_type, .pointee_type = member_type, .indices = &.{} };
        first_index = 4;
        break;
    }

    var address: CompositeAddress = if (member_address) |base|
        base
    else if (try context.compositeAddress(operands[2])) |base|
        base
    else if (try context.localIndex(operands[2])) |local_index| blk: {
        const pointee_type = context.function_parameter_pointees[try context.idIndex(operands[2])] orelse
            try variablePointeeType(context, operands[2]);

        break :blk .{
            .root = .{ .local = local_index },
            .root_type = pointee_type,
            .pointee_type = pointee_type,
            .indices = &.{},
        };
    } else if (context.function_parameter_pointees[try context.idIndex(operands[2])]) |pointee_type| blk: {
        const value = context.values[try context.idIndex(operands[2])] orelse return TranslationError.MissingDefinition;

        if (context.module.typeOf(value) != try context.translateType(pointee_type))
            return TranslationError.InvalidInstruction;

        break :blk .{
            .root = .{ .value = value },
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

    var indices = std.ArrayList(CompositeIndex).empty;
    defer indices.deinit(context.scratch);
    try indices.appendSlice(context.scratch, address.indices);

    for (operands[first_index..]) |index_id| {
        const type_definition = context.type_defs[try context.idIndex(address.pointee_type)] orelse return TranslationError.MissingDefinition;
        const value = try context.resolveValue(index_id);
        const value_type = context.module.types.get(context.module.typeOf(value).?).?;

        if (value_type.* != .integer)
            return TranslationError.InvalidInstruction;

        const is_constant = context.module.values.get(value).?.definition == .constant;
        const index = if (is_constant) try constantIndex(context, index_id) else 0;
        var length: u32 = 0;

        address.pointee_type = switch (type_definition.opcode) {
            .type_struct => blk: {
                if (!is_constant)
                    return TranslationError.InvalidInstruction;

                if (index >= type_definition.operands.len - 1)
                    return TranslationError.InvalidInstruction;

                break :blk type_definition.operands[index + 1];
            },
            .type_vector, .type_matrix => blk: {
                try expectOperandCount(type_definition.operands, 3);
                length = type_definition.operands[2];

                if (index >= length)
                    return TranslationError.InvalidInstruction;

                break :blk type_definition.operands[1];
            },
            .type_array => blk: {
                try expectOperandCount(type_definition.operands, 3);
                length = try constantIndex(context, type_definition.operands[2]);

                if (index >= length)
                    return TranslationError.InvalidInstruction;

                break :blk type_definition.operands[1];
            },
            else => return TranslationError.UnsupportedType,
        };

        try indices.append(context.scratch, if (is_constant) .{ .constant = index } else .{ .dynamic = .{ .value = value, .length = length } });
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

    address.indices = try context.scratch.dupe(CompositeIndex, indices.items);
    context.composite_addresses[result_index] = address;
}

fn loadFunctionLvalue(context: *Context, block: ir.id.BlockId, pointer: u32) !ir.id.ValueId {
    if (try context.localIndex(pointer)) |local_index|
        return context.current_locals[local_index] orelse TranslationError.InvalidInstruction;
    const address = (try context.compositeAddress(pointer)) orelse return unsupportedStoreDestination(context, pointer);
    const local_index = switch (address.root) {
        .local => |index| index,
        else => return unsupportedStoreDestination(context, pointer),
    };
    const composite = context.current_locals[local_index] orelse return TranslationError.InvalidInstruction;
    return extractCompositeAddress(context, block, composite, address.indices, null);
}

fn storeFunctionLvalue(context: *Context, block: ir.id.BlockId, pointer: u32, value: ir.id.ValueId) !void {
    if (try context.localIndex(pointer)) |local_index| {
        if (context.locals.items[local_index].type != context.module.typeOf(value))
            return TranslationError.InvalidInstruction;
        context.current_locals[local_index] = value;
        return;
    }
    const address = (try context.compositeAddress(pointer)) orelse return unsupportedStoreDestination(context, pointer);
    const local_index = switch (address.root) {
        .local => |index| index,
        else => return unsupportedStoreDestination(context, pointer),
    };
    if (context.module.typeOf(value) != try context.translateType(address.pointee_type))
        return TranslationError.InvalidInstruction;
    const composite = context.current_locals[local_index] orelse return TranslationError.InvalidInstruction;
    context.current_locals[local_index] = try insertCompositeAddress(context, block, composite, value, address.indices);
}

fn insertCompositeAddress(context: *Context, block: ir.id.BlockId, composite: ir.id.ValueId, value: ir.id.ValueId, indices: []const CompositeIndex) !ir.id.ValueId {
    if (indices.len == 0) {
        if (context.module.typeOf(composite) != context.module.typeOf(value))
            return TranslationError.InvalidInstruction;
        return value;
    }

    const composite_type = context.module.typeOf(composite) orelse return TranslationError.InvalidId;
    const ty = context.module.types.get(composite_type) orelse return TranslationError.InvalidId;
    const count: usize = switch (ty.*) {
        .vector => |vector| vector.length,
        .matrix => |matrix| matrix.column_count,
        .array => |array| array.length,
        .structure => |structure| structure.members.len,
        else => return TranslationError.UnsupportedType,
    };
    const candidate_count: usize = switch (indices[0]) {
        .constant => 1,
        .dynamic => count,
    };
    var selected = composite;
    for (0..candidate_count) |candidate| {
        const replaced_index: usize = switch (indices[0]) {
            .constant => |index| index,
            .dynamic => candidate,
        };
        if (replaced_index >= count)
            return TranslationError.InvalidInstruction;

        const elements = try context.scratch.alloc(ir.id.ValueId, count);
        for (elements, 0..) |*element, index| {
            const element_type = switch (ty.*) {
                .vector => |vector| vector.element_type,
                .matrix => |matrix| matrix.element_type,
                .array => |array| array.element_type,
                .structure => |structure| structure.members[index],
                else => unreachable,
            };
            const extracted = (try context.builder.appendInstruction(block, element_type, .{
                .composite_extract = .{ .composite = composite, .indices = &.{@intCast(index)} },
            }, null)).?;
            element.* = if (index == replaced_index)
                try insertCompositeAddress(context, block, extracted, value, indices[1..])
            else
                extracted;
        }
        const updated = (try context.builder.appendInstruction(block, composite_type, .{
            .composite_construct = .{ .elements = elements },
        }, null)).?;
        selected = switch (indices[0]) {
            .constant => updated,
            .dynamic => |dynamic| blk: {
                const literal = try context.builder.internConstant(context.module.typeOf(dynamic.value).?, .{ .integer_bits = candidate });
                const condition = (try context.builder.appendInstruction(block, try context.builder.internType(.boolean), .{
                    .compare = .{ .opcode = .equal, .lhs = dynamic.value, .rhs = literal },
                }, null)).?;
                break :blk (try context.builder.appendInstruction(block, composite_type, .{
                    .select = .{ .condition = condition, .true_value = updated, .false_value = selected },
                }, null)).?;
            },
        };
    }
    return selected;
}

fn extractCompositeAddress(context: *Context, block: ir.id.BlockId, composite: ir.id.ValueId, indices: []const CompositeIndex, name: ?[]const u8) !ir.id.ValueId {
    if (indices.len == 0)
        return composite;

    const ty = context.module.types.get(context.module.typeOf(composite).?).?.*;
    const element_type = switch (ty) {
        .vector => |v| v.element_type,
        .matrix => |m| m.element_type,
        .array => |a| a.element_type,
        .structure => |s| s.members[indices[0].constant],
        else => return TranslationError.UnsupportedType,
    };

    var selected: ?ir.id.ValueId = null;
    const count = switch (indices[0]) {
        .constant => @as(u32, 1),
        .dynamic => |d| d.length,
    };

    for (0..count) |i| {
        const index: u32 = switch (indices[0]) {
            .constant => |c| c,
            .dynamic => @intCast(i),
        };

        const path = try context.scratch.dupe(u32, &.{index});
        const element = (try context.builder.appendInstruction(block, element_type, .{ .composite_extract = .{ .composite = composite, .indices = path } }, if (indices.len == 1 and indices[0] == .constant) name else null)).?;
        if (selected) |previous| {
            const dynamic = indices[0].dynamic;
            const literal = try context.builder.internConstant(context.module.typeOf(dynamic.value).?, .{ .integer_bits = i });
            const condition = (try context.builder.appendInstruction(block, try context.builder.internType(.boolean), .{ .compare = .{ .opcode = .equal, .lhs = dynamic.value, .rhs = literal } }, null)).?;
            selected = (try context.builder.appendInstruction(block, element_type, .{ .select = .{ .condition = condition, .true_value = element, .false_value = previous } }, null)).?;
        } else selected = element;
    }

    return extractCompositeAddress(context, block, selected orelse return TranslationError.InvalidInstruction, indices[1..], name);
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
                .descriptor_index = address.descriptor_index,
                .byte_offset = try bufferByteOffset(
                    context,
                    .{
                        .resource = address.resource,
                        .descriptor_index = address.descriptor_index,
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
    if (constantIntegerBits(context, value)) |bits|
        return context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = bits });

    return (try context.builder.appendInstruction(block, try unsigned32Type(context), .{
        .bitcast = value,
    }, null)).?;
}

const MatrixTypeInfo = struct {
    matrix_type: ir.id.TypeId,
    column_type: ir.id.TypeId,
    element_type: ir.id.TypeId,
    rows: u32,
    columns: u32,
    element_size: u32,
};

fn matrixTypeInfo(context: *Context, spv_type: u32) !MatrixTypeInfo {
    const matrix = context.type_defs[try context.idIndex(spv_type)] orelse return TranslationError.MissingDefinition;
    if (matrix.opcode != .type_matrix)
        return TranslationError.InvalidInstruction;
    try expectOperandCount(matrix.operands, 3);

    const column = context.type_defs[try context.idIndex(matrix.operands[1])] orelse return TranslationError.MissingDefinition;
    if (column.opcode != .type_vector)
        return TranslationError.InvalidInstruction;
    try expectOperandCount(column.operands, 3);

    return .{
        .matrix_type = try context.translateType(spv_type),
        .column_type = try context.translateType(matrix.operands[1]),
        .element_type = try context.translateType(column.operands[1]),
        .rows = column.operands[2],
        .columns = matrix.operands[2],
        .element_size = try workgroupTypeSize(context, column.operands[1]),
    };
}

fn matrixElementMemoryOffset(layout: MatrixMemoryLayout, element_size: u32, column: u32, row: u32) !u32 {
    const major_index, const minor_index = switch (layout.major) {
        .column => .{ column, row },
        .row => .{ row, column },
    };
    const major_offset = std.math.mul(u32, major_index, layout.stride) catch return TranslationError.InvalidInstruction;
    const minor_offset = std.math.mul(u32, minor_index, element_size) catch return TranslationError.InvalidInstruction;
    return std.math.add(u32, major_offset, minor_offset) catch return TranslationError.InvalidInstruction;
}

fn addIndexedByteOffset(context: *Context, block: ir.id.BlockId, base: ?ir.id.ValueId, spv_index: u32, stride: u32) !ir.id.ValueId {
    const index = try unsignedOffsetValue(context, block, spv_index);
    return addByteOffset(context, block, base, try scaledByteOffset(context, block, index, stride));
}

fn addConstantByteOffset(context: *Context, block: ir.id.BlockId, base: ?ir.id.ValueId, offset: u32) !ir.id.ValueId {
    if (offset == 0)
        return base orelse context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = 0 });
    const value = try context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = offset });
    return addByteOffset(context, block, base, value);
}

const VectorTypeInfo = struct {
    vector_type: ir.id.TypeId,
    element_type: ir.id.TypeId,
    element_size: u32,
    length: u32,
};

fn vectorTypeInfo(context: *Context, spv_type: u32) !VectorTypeInfo {
    const vector = context.type_defs[try context.idIndex(spv_type)] orelse return TranslationError.MissingDefinition;
    if (vector.opcode != .type_vector)
        return TranslationError.InvalidInstruction;
    try expectOperandCount(vector.operands, 3);
    return .{
        .vector_type = try context.translateType(spv_type),
        .element_type = try context.translateType(vector.operands[1]),
        .element_size = try workgroupTypeSize(context, vector.operands[1]),
        .length = vector.operands[2],
    };
}

fn translateBufferStridedVectorLoad(context: *Context, block: ir.id.BlockId, address: BufferAddress, stride: u32, name: ?[]const u8) !ir.id.ValueId {
    const info = try vectorTypeInfo(context, address.pointee_type);
    if (stride == info.element_size) {
        return (try context.builder.appendInstruction(block, info.vector_type, .{ .load_buffer = .{
            .resource = address.resource,
            .descriptor_index = address.descriptor_index,
            .byte_offset = try bufferByteOffset(context, address),
        } }, name)).?;
    }

    const elements = try context.scratch.alloc(ir.id.ValueId, info.length);
    for (elements, 0..) |*element, index| {
        const relative_offset = std.math.mul(u32, @intCast(index), stride) catch return TranslationError.InvalidInstruction;
        element.* = (try context.builder.appendInstruction(block, info.element_type, .{ .load_buffer = .{
            .resource = address.resource,
            .descriptor_index = address.descriptor_index,
            .byte_offset = try addConstantByteOffset(context, block, address.byte_offset, relative_offset),
        } }, null)).?;
    }
    return (try context.builder.appendInstruction(block, info.vector_type, .{ .composite_construct = .{
        .elements = elements,
    } }, name)).?;
}

fn translatePushConstantStridedVectorLoad(context: *Context, block: ir.id.BlockId, address: PushConstantAddress, stride: u32, name: ?[]const u8) !ir.id.ValueId {
    const info = try vectorTypeInfo(context, address.pointee_type);
    if (stride == info.element_size) {
        return (try context.builder.appendInstruction(block, info.vector_type, .{ .load_push_constant = .{
            .byte_offset = try pushConstantByteOffset(context, address),
        } }, name)).?;
    }

    const elements = try context.scratch.alloc(ir.id.ValueId, info.length);
    for (elements, 0..) |*element, index| {
        const relative_offset = std.math.mul(u32, @intCast(index), stride) catch return TranslationError.InvalidInstruction;
        element.* = (try context.builder.appendInstruction(block, info.element_type, .{ .load_push_constant = .{
            .byte_offset = try addConstantByteOffset(context, block, address.byte_offset, relative_offset),
        } }, null)).?;
    }
    return (try context.builder.appendInstruction(block, info.vector_type, .{ .composite_construct = .{
        .elements = elements,
    } }, name)).?;
}

fn translateBufferStridedVectorStore(context: *Context, block: ir.id.BlockId, address: BufferAddress, stride: u32, value: ir.id.ValueId) !void {
    const info = try vectorTypeInfo(context, address.pointee_type);
    for (0..info.length) |index| {
        const element = (try context.builder.appendInstruction(block, info.element_type, .{ .composite_extract = .{
            .composite = value,
            .indices = &.{@intCast(index)},
        } }, null)).?;
        const relative_offset = std.math.mul(u32, @intCast(index), stride) catch return TranslationError.InvalidInstruction;
        _ = try context.builder.appendInstruction(block, null, .{ .store_buffer = .{
            .resource = address.resource,
            .descriptor_index = address.descriptor_index,
            .byte_offset = try addConstantByteOffset(context, block, address.byte_offset, relative_offset),
            .value = element,
        } }, null);
    }
}

fn translateBufferMatrixLoad(context: *Context, block: ir.id.BlockId, address: BufferAddress, layout: MatrixMemoryLayout, name: ?[]const u8) !ir.id.ValueId {
    const info = try matrixTypeInfo(context, address.pointee_type);
    const column_size = std.math.mul(u32, info.rows, info.element_size) catch return TranslationError.InvalidInstruction;
    if (layout.major == .column and layout.stride == column_size) {
        return (try context.builder.appendInstruction(block, info.matrix_type, .{ .load_buffer = .{
            .resource = address.resource,
            .descriptor_index = address.descriptor_index,
            .byte_offset = try bufferByteOffset(context, address),
        } }, name)).?;
    }

    const columns = try context.scratch.alloc(ir.id.ValueId, info.columns);
    const elements = try context.scratch.alloc(ir.id.ValueId, info.rows);

    for (columns, 0..) |*column, column_index| {
        if (layout.major == .column) {
            const relative_offset = std.math.mul(u32, @intCast(column_index), layout.stride) catch return TranslationError.InvalidInstruction;
            column.* = (try context.builder.appendInstruction(block, info.column_type, .{ .load_buffer = .{
                .resource = address.resource,
                .descriptor_index = address.descriptor_index,
                .byte_offset = try addConstantByteOffset(context, block, address.byte_offset, relative_offset),
            } }, null)).?;
            continue;
        }

        for (elements, 0..) |*element, row_index| {
            const relative_offset = try matrixElementMemoryOffset(layout, info.element_size, @intCast(column_index), @intCast(row_index));
            element.* = (try context.builder.appendInstruction(block, info.element_type, .{ .load_buffer = .{
                .resource = address.resource,
                .descriptor_index = address.descriptor_index,
                .byte_offset = try addConstantByteOffset(context, block, address.byte_offset, relative_offset),
            } }, null)).?;
        }
        column.* = (try context.builder.appendInstruction(block, info.column_type, .{ .composite_construct = .{
            .elements = elements,
        } }, null)).?;
    }

    return (try context.builder.appendInstruction(block, info.matrix_type, .{ .composite_construct = .{
        .elements = columns,
    } }, name)).?;
}

fn translatePushConstantMatrixLoad(context: *Context, block: ir.id.BlockId, address: PushConstantAddress, layout: MatrixMemoryLayout, name: ?[]const u8) !ir.id.ValueId {
    const info = try matrixTypeInfo(context, address.pointee_type);
    const column_size = std.math.mul(u32, info.rows, info.element_size) catch return TranslationError.InvalidInstruction;
    if (layout.major == .column and layout.stride == column_size) {
        return (try context.builder.appendInstruction(block, info.matrix_type, .{ .load_push_constant = .{
            .byte_offset = try pushConstantByteOffset(context, address),
        } }, name)).?;
    }

    const columns = try context.scratch.alloc(ir.id.ValueId, info.columns);
    const elements = try context.scratch.alloc(ir.id.ValueId, info.rows);

    for (columns, 0..) |*column, column_index| {
        if (layout.major == .column) {
            const relative_offset = std.math.mul(u32, @intCast(column_index), layout.stride) catch return TranslationError.InvalidInstruction;
            column.* = (try context.builder.appendInstruction(block, info.column_type, .{ .load_push_constant = .{
                .byte_offset = try addConstantByteOffset(context, block, address.byte_offset, relative_offset),
            } }, null)).?;
            continue;
        }

        for (elements, 0..) |*element, row_index| {
            const relative_offset = try matrixElementMemoryOffset(layout, info.element_size, @intCast(column_index), @intCast(row_index));
            element.* = (try context.builder.appendInstruction(block, info.element_type, .{ .load_push_constant = .{
                .byte_offset = try addConstantByteOffset(context, block, address.byte_offset, relative_offset),
            } }, null)).?;
        }
        column.* = (try context.builder.appendInstruction(block, info.column_type, .{ .composite_construct = .{
            .elements = elements,
        } }, null)).?;
    }

    return (try context.builder.appendInstruction(block, info.matrix_type, .{ .composite_construct = .{
        .elements = columns,
    } }, name)).?;
}

fn translateBufferMatrixStore(context: *Context, block: ir.id.BlockId, address: BufferAddress, layout: MatrixMemoryLayout, value: ir.id.ValueId) !void {
    const info = try matrixTypeInfo(context, address.pointee_type);
    for (0..info.columns) |column_index| {
        for (0..info.rows) |row_index| {
            const element = (try context.builder.appendInstruction(block, info.element_type, .{ .composite_extract = .{
                .composite = value,
                .indices = &.{ @intCast(column_index), @intCast(row_index) },
            } }, null)).?;
            const relative_offset = try matrixElementMemoryOffset(layout, info.element_size, @intCast(column_index), @intCast(row_index));
            _ = try context.builder.appendInstruction(block, null, .{ .store_buffer = .{
                .resource = address.resource,
                .descriptor_index = address.descriptor_index,
                .byte_offset = try addConstantByteOffset(context, block, address.byte_offset, relative_offset),
                .value = element,
            } }, null);
        }
    }
}

fn addByteOffset(context: *Context, block: ir.id.BlockId, current: ?ir.id.ValueId, term: ir.id.ValueId) !ir.id.ValueId {
    const lhs = current orelse return term;
    if (constantIntegerBits(context, lhs)) |lhs_bits| {
        if (constantIntegerBits(context, term)) |term_bits|
            return context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = lhs_bits +% term_bits });
    }
    return (try context.builder.appendInstruction(block, try unsigned32Type(context), .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = lhs,
            .rhs = term,
        },
    }, null)).?;
}

fn scaledByteOffset(context: *Context, block: ir.id.BlockId, index: ir.id.ValueId, stride: u32) !ir.id.ValueId {
    if (constantIntegerBits(context, index)) |bits|
        return context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = bits *% stride });

    const stride_value = try context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = stride });
    return (try context.builder.appendInstruction(block, try unsigned32Type(context), .{
        .binary = .{ .opcode = .integer_multiply, .lhs = index, .rhs = stride_value },
    }, null)).?;
}

fn constantIntegerBits(context: *const Context, value_id: ir.id.ValueId) ?u32 {
    const value = context.module.values.get(value_id) orelse return null;
    if (value.definition != .constant)
        return null;
    const constant = context.module.constants.get(value.definition.constant) orelse return null;
    return switch (constant.value) {
        .integer_bits => |bits| @truncate(bits),
        else => null,
    };
}

fn bufferByteOffset(context: *Context, address: BufferAddress) !ir.id.ValueId {
    return address.byte_offset orelse context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = 0 });
}

fn pushConstantByteOffset(context: *Context, address: PushConstantAddress) !ir.id.ValueId {
    return address.byte_offset orelse context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = 0 });
}

fn workgroupByteOffset(context: *Context, address: WorkgroupAddress) !ir.id.ValueId {
    return address.byte_offset orelse context.builder.internConstant(try unsigned32Type(context), .{ .integer_bits = 0 });
}

fn workgroupTypeSize(context: *Context, spv_type: u32) !u32 {
    const ty = context.type_defs[try context.idIndex(spv_type)] orelse return TranslationError.MissingDefinition;
    return switch (ty.opcode) {
        .type_bool => 4,
        .type_int, .type_float => blk: {
            if (ty.operands.len < 2 or ty.operands[1] != 32)
                return TranslationError.UnsupportedType;
            break :blk 4;
        },
        .type_vector => blk: {
            try expectOperandCount(ty.operands, 3);
            const element_size = try workgroupTypeSize(context, ty.operands[1]);
            break :blk std.math.mul(u32, element_size, ty.operands[2]) catch return TranslationError.UnsupportedType;
        },
        .type_array => blk: {
            try expectOperandCount(ty.operands, 3);
            const element_size = try workgroupTypeSize(context, ty.operands[1]);
            const length = try constantIndex(context, ty.operands[2]);
            break :blk std.math.mul(u32, element_size, length) catch return TranslationError.UnsupportedType;
        },
        .type_struct => blk: {
            var size: u32 = 0;
            for (ty.operands[1..]) |member_type|
                size = std.math.add(u32, size, try workgroupTypeSize(context, member_type)) catch return TranslationError.UnsupportedType;
            break :blk size;
        },
        else => TranslationError.UnsupportedType,
    };
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

fn findMemberMatrixLayout(context: *const Context, structure_id: u32, member: u32) !?MatrixMemoryLayout {
    var found: ?MemberMatrixLayout = null;
    for (context.member_matrix_layouts.items) |entry| {
        if (entry.structure_id != structure_id or entry.member != member)
            continue;
        if (found != null)
            return TranslationError.InvalidInstruction;
        found = entry;
    }

    const entry = found orelse return null;
    return .{
        .stride = entry.stride orelse return TranslationError.InvalidInstruction,
        .major = entry.major orelse return TranslationError.InvalidInstruction,
    };
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

fn loweredReturnValue(context: *Context, spv_function: u32, label: u32, source_value: ?ir.id.ValueId) !?ir.id.ValueId {
    const lowering = context.function_lowerings[try context.idIndex(spv_function)] orelse return TranslationError.MissingFunction;
    if (lowering.pointer_parameters.len == 0)
        return source_value;

    const source_return = context.module.types.get(lowering.source_return_type) orelse return TranslationError.InvalidId;
    const values = try context.scratch.alloc(ir.id.ValueId, lowering.pointer_parameters.len + @intFromBool(source_return.* != .void));
    var output_index: usize = 0;
    if (source_return.* != .void) {
        values[0] = source_value orelse return TranslationError.InvalidInstruction;
        output_index = 1;
    } else if (source_value != null) {
        return TranslationError.InvalidInstruction;
    }

    for (context.locals.items, 0..) |local, local_index| {
        if (!local.pointer_parameter)
            continue;
        if (output_index >= values.len)
            return TranslationError.InvalidFunctionParameter;
        values[output_index] = context.block_local_outputs[try context.blockLocalIndex(label, local_index)] orelse return TranslationError.InvalidInstruction;
        output_index += 1;
    }
    if (output_index != values.len)
        return TranslationError.InvalidFunctionParameter;

    return (try context.builder.appendInstruction(try context.block(label), lowering.lowered_return_type, .{
        .composite_construct = .{ .elements = values },
    }, null)).?;
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
            .@"switch" => try translateSwitch(context, current_label orelse return TranslationError.InvalidBlock, operands),
            .return_ => {
                try expectOperandCount(operands, 0);
                const label = current_label orelse return TranslationError.InvalidBlock;
                const value = try loweredReturnValue(context, spv_function, label, null);
                try context.builder.setTerminator(try context.block(label), if (value) |result|
                    .{ .return_value = result }
                else
                    .return_void);
            },
            .return_value => {
                try expectOperandCount(operands, 1);
                const label = current_label orelse return TranslationError.InvalidBlock;
                const value = (try loweredReturnValue(context, spv_function, label, try context.resolveValue(operands[0]))) orelse return TranslationError.InvalidInstruction;
                try context.builder.setTerminator(try context.block(label), .{ .return_value = value });
            },
            .kill => {
                try expectOperandCount(operands, 0);
                try context.builder.setTerminator(try context.block(current_label orelse return TranslationError.InvalidBlock), .discard);
            },
            .@"unreachable" => {
                try expectOperandCount(operands, 0);
                try context.builder.setTerminator(try context.block(current_label orelse return TranslationError.InvalidBlock), .@"unreachable");
            },
            .function_end => break,

            else => {},
        }
    }
}

fn translateSwitch(context: *Context, predecessor_label: u32, operands: []const u32) !void {
    if (operands.len < 2)
        return TranslationError.InvalidInstruction;

    const selector = try context.resolveValue(operands[0]);
    const selector_type = context.module.typeOf(selector) orelse return TranslationError.InvalidId;
    const selector_type_data = context.module.types.get(selector_type) orelse return TranslationError.InvalidId;
    const integer = switch (selector_type_data.*) {
        .integer => |value| value,
        else => return TranslationError.InvalidInstruction,
    };
    if (integer.bits == 0 or integer.bits > 64)
        return TranslationError.UnsupportedType;

    const literal_words: usize = if (integer.bits > 32) 2 else 1;
    const case_words = literal_words + 1;
    if ((operands.len - 2) % case_words != 0)
        return TranslationError.InvalidInstruction;

    const predecessor_block = try context.block(predecessor_label);
    if (operands.len == 2) {
        try context.builder.setTerminator(predecessor_block, .{
            .branch = try makeEdge(context, predecessor_label, operands[1]),
        });
        return;
    }

    const function = (context.module.blocks.get(predecessor_block) orelse return TranslationError.InvalidBlock).parent_function;
    const bool_type = try context.builder.internType(.boolean);
    const literal_mask = if (integer.bits == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(integer.bits)) - 1;

    var current_block = predecessor_block;
    var cursor: usize = 2;
    while (cursor < operands.len) : (cursor += case_words) {
        var literal_bits: u64 = operands[cursor];
        if (literal_words == 2)
            literal_bits |= @as(u64, operands[cursor + 1]) << 32;
        literal_bits &= literal_mask;

        const case_value = try context.builder.internConstant(selector_type, .{ .integer_bits = literal_bits });
        const condition = (try context.builder.appendInstruction(current_block, bool_type, .{
            .compare = .{
                .opcode = .equal,
                .lhs = selector,
                .rhs = case_value,
            },
        }, null)).?;
        const target_label = operands[cursor + literal_words];
        const next_cursor = cursor + case_words;
        const false_edge = if (next_cursor == operands.len)
            try makeEdge(context, predecessor_label, operands[1])
        else blk: {
            const next_block = try context.builder.addBlock(function, null);
            break :blk try context.builder.edge(next_block, &.{});
        };

        try context.builder.setTerminator(current_block, .{
            .conditional_branch = .{
                .condition = condition,
                .true_edge = try makeEdge(context, predecessor_label, target_label),
                .false_edge = false_edge,
            },
        });
        current_block = false_edge.target;
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
        .device_index => .device_index,
        .frag_coord => .frag_coord,
        .frag_depth => .frag_depth,
        .global_invocation_id => .global_invocation_id,
        .instance_index => .instance_index,
        .local_invocation_id => .local_invocation_id,
        .local_invocation_index => .local_invocation_index,
        .num_workgroups => .num_workgroups,
        .position => .position,
        .point_size => .point_size,
        .vertex_index => .vertex_index,
        .workgroup_id => .workgroup_id,
        .workgroup_size => .workgroup_size,

        else => TranslationError.UnsupportedBuiltin,
    };
}

fn translateBinaryOpcode(opcode: spirv.Opcode) ir.instruction.BinaryOpcode {
    return switch (opcode) {
        .i_add => .integer_add,
        .i_sub => .integer_subtract,
        .i_mul => .integer_multiply,
        .i_add_carry => .integer_add_carry,
        .i_sub_borrow => .integer_subtract_borrow,
        .u_mul_extended => .unsigned_multiply_extended,
        .s_mul_extended => .signed_multiply_extended,
        .u_div => .unsigned_divide,
        .s_div => .signed_divide,
        .u_mod => .unsigned_modulo,
        .s_mod => .signed_modulo,
        .f_add => .float_add,
        .f_sub => .float_subtract,
        .f_mul => .float_multiply,
        .f_div => .float_divide,
        .f_mod => .float_modulo,
        .f_rem => .float_remainder,
        .dot => .dot,
        .outer_product => .outer_product,
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

const ComparisonLowering = struct {
    opcode: ir.instruction.CompareOpcode,
    reverse_operands: bool = false,
    negate_result: bool = false,
};

fn translateComparison(opcode: spirv.Opcode) ComparisonLowering {
    return switch (opcode) {
        .logical_equal, .i_equal => .{ .opcode = .equal },
        .logical_not_equal, .i_not_equal => .{ .opcode = .not_equal },

        .u_less_than => .{ .opcode = .unsigned_less },
        .u_greater_than => .{ .opcode = .unsigned_less, .reverse_operands = true },
        .u_greater_than_equal => .{ .opcode = .unsigned_less, .negate_result = true },
        .u_less_than_equal => .{ .opcode = .unsigned_less, .reverse_operands = true, .negate_result = true },

        .s_less_than => .{ .opcode = .signed_less },
        .s_greater_than => .{ .opcode = .signed_less, .reverse_operands = true },
        .s_greater_than_equal => .{ .opcode = .signed_less, .negate_result = true },
        .s_less_than_equal => .{ .opcode = .signed_less, .reverse_operands = true, .negate_result = true },

        .f_ord_equal => .{ .opcode = .ordered_float_equal },
        .f_unord_equal => .{ .opcode = .unordered_float_equal },
        .f_ord_not_equal => .{ .opcode = .ordered_float_not_equal },
        .f_unord_not_equal => .{ .opcode = .unordered_float_not_equal },
        .f_ord_less_than => .{ .opcode = .ordered_float_less },
        .f_unord_less_than => .{ .opcode = .unordered_float_less },
        .f_ord_greater_than => .{ .opcode = .ordered_float_less, .reverse_operands = true },
        .f_unord_greater_than => .{ .opcode = .unordered_float_less, .reverse_operands = true },
        .f_ord_less_than_equal => .{ .opcode = .ordered_float_less_equal },
        .f_unord_less_than_equal => .{ .opcode = .ordered_float_less, .reverse_operands = true, .negate_result = true },
        .f_ord_greater_than_equal => .{ .opcode = .ordered_float_less_equal, .reverse_operands = true },
        .f_unord_greater_than_equal => .{ .opcode = .ordered_float_less, .negate_result = true },

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

test "SPIR-V: OpSwitch lowers to conditional branches with promoted locals" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%uint = OpTypeInt 32 0
        \\%ptr_function_uint = OpTypePointer Function %uint
        \\%fn_void = OpTypeFunction %void
        \\%one = OpConstant %uint 1
        \\%two = OpConstant %uint 2
        \\%seven = OpConstant %uint 7
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %local = OpVariable %ptr_function_uint Function %seven
        \\    OpSelectionMerge %merge None
        \\    OpSwitch %two %default 1 %case_one 2 %case_two
        \\    %case_one = OpLabel
        \\    OpBranch %merge
        \\    %case_two = OpLabel
        \\    OpBranch %merge
        \\    %default = OpLabel
        \\    OpBranch %merge
        \\    %merge = OpLabel
        \\    %loaded = OpLoad %uint %local
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    try std.testing.expectEqual(@as(usize, 6), function.blocks.items.len);
    const entry = module.blocks.get(function.blocks.items[0]).?;
    const first_branch = entry.terminator.?.conditional_branch;
    try std.testing.expectEqual(function.blocks.items[1], first_branch.true_edge.target);
    try std.testing.expectEqual(function.blocks.items[5], first_branch.false_edge.target);
    try std.testing.expectEqual(@as(usize, 1), first_branch.true_edge.arguments.len);
    try std.testing.expectEqual(@as(usize, 0), first_branch.false_edge.arguments.len);

    const second_test = module.blocks.get(function.blocks.items[5]).?;
    const second_branch = second_test.terminator.?.conditional_branch;
    try std.testing.expectEqual(function.blocks.items[2], second_branch.true_edge.target);
    try std.testing.expectEqual(function.blocks.items[3], second_branch.false_edge.target);
    try std.testing.expectEqual(@as(usize, 1), second_branch.true_edge.arguments.len);
    try std.testing.expectEqual(@as(usize, 1), second_branch.false_edge.arguments.len);
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

test "SPIR-V: function pointer parameters copy modified values back to callers" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%uint = OpTypeInt 32 0
        \\%vec2 = OpTypeVector %uint 2
        \\%ptr_function_uint = OpTypePointer Function %uint
        \\%ptr_function_vec2 = OpTypePointer Function %vec2
        \\%fn_void = OpTypeFunction %void
        \\%fn_write = OpTypeFunction %void %ptr_function_vec2
        \\%zero = OpConstant %uint 0
        \\%one = OpConstant %uint 1
        \\%initial = OpConstantComposite %vec2 %zero %zero
        \\%write = OpFunction %void None %fn_write
        \\    %destination = OpFunctionParameter %ptr_function_vec2
        \\    %write_entry = OpLabel
        \\    OpStore %destination %initial
        \\    %element = OpAccessChain %ptr_function_uint %destination %one
        \\    OpStore %element %one
        \\    OpReturn
        \\OpFunctionEnd
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %local = OpVariable %ptr_function_vec2 Function
        \\    OpStore %local %initial
        \\    %call = OpFunctionCall %void %write %local
        \\    %result = OpLoad %vec2 %local
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();
    try std.testing.expect(module.properties.no_function_calls);

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "composite_extract") != null);
}

test "SPIR-V: vector times scalar" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main" %vector %scalar
        \\OpExecutionMode %main LocalSize 1 1 1
        \\OpName %product "product"
        \\OpDecorate %vector Location 0
        \\OpDecorate %scalar Location 1
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%float = OpTypeFloat 32
        \\%vec3 = OpTypeVector %float 3
        \\%ptr_input_vec3 = OpTypePointer Input %vec3
        \\%ptr_input_float = OpTypePointer Input %float
        \\%vector = OpVariable %ptr_input_vec3 Input
        \\%scalar = OpVariable %ptr_input_float Input
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %vector_value = OpLoad %vec3 %vector
        \\    %scalar_value = OpLoad %float %scalar
        \\    %product = OpVectorTimesScalar %vec3 %vector_value %scalar_value
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "%product: vec3[f32] = vector_times_scalar") != null);
}

test "SPIR-V: function-local promotion preserves initial state across edges" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%uint = OpTypeInt 32 0
        \\%ptr_function_uint = OpTypePointer Function %uint
        \\%zero = OpConstant %uint 0
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %uninitialized = OpVariable %ptr_function_uint Function
        \\    %initialized = OpVariable %ptr_function_uint Function %zero
        \\    OpBranch %exit
        \\    %exit = OpLabel
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    const entry = module.blocks.get(function.blocks.items[0]).?;
    const edge = entry.terminator.?.branch;
    try std.testing.expectEqual(@as(usize, 2), edge.arguments.len);
    try std.testing.expect(module.values.get(edge.arguments[0]).?.definition == .undef);
    const initialized = module.values.get(edge.arguments[1]).?;
    try std.testing.expect(initialized.definition == .constant);
    try std.testing.expectEqual(@as(u64, 0), module.constants.get(initialized.definition.constant).?.value.integer_bits);
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

test "SPIR-V: row-major and column-major matrix memory layouts" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\OpDecorate %Matrices BufferBlock
        \\OpMemberDecorate %Matrices 0 Offset 0
        \\OpMemberDecorate %Matrices 0 RowMajor
        \\OpMemberDecorate %Matrices 0 MatrixStride 16
        \\OpMemberDecorate %Matrices 1 Offset 48
        \\OpMemberDecorate %Matrices 1 ColMajor
        \\OpMemberDecorate %Matrices 1 MatrixStride 16
        \\OpDecorate %source DescriptorSet 0
        \\OpDecorate %source Binding 0
        \\OpDecorate %destination DescriptorSet 0
        \\OpDecorate %destination Binding 1
        \\OpDecorate %Push Block
        \\OpMemberDecorate %Push 0 Offset 0
        \\OpMemberDecorate %Push 0 RowMajor
        \\OpMemberDecorate %Push 0 MatrixStride 16
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%float = OpTypeFloat 32
        \\%int = OpTypeInt 32 1
        \\%vec3 = OpTypeVector %float 3
        \\%mat2x3 = OpTypeMatrix %vec3 2
        \\%Matrices = OpTypeStruct %mat2x3 %mat2x3
        \\%Push = OpTypeStruct %mat2x3
        \\%ptr_uniform_matrices = OpTypePointer Uniform %Matrices
        \\%ptr_uniform_matrix = OpTypePointer Uniform %mat2x3
        \\%ptr_uniform_vec3 = OpTypePointer Uniform %vec3
        \\%ptr_uniform_float = OpTypePointer Uniform %float
        \\%ptr_push_struct = OpTypePointer PushConstant %Push
        \\%ptr_push_matrix = OpTypePointer PushConstant %mat2x3
        \\%ptr_push_vec3 = OpTypePointer PushConstant %vec3
        \\%int_0 = OpConstant %int 0
        \\%int_1 = OpConstant %int 1
        \\%source = OpVariable %ptr_uniform_matrices Uniform
        \\%destination = OpVariable %ptr_uniform_matrices Uniform
        \\%push = OpVariable %ptr_push_struct PushConstant
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %source_row_ptr = OpAccessChain %ptr_uniform_matrix %source %int_0
        \\    %source_row = OpLoad %mat2x3 %source_row_ptr
        \\    %destination_row_ptr = OpAccessChain %ptr_uniform_matrix %destination %int_0
        \\    OpStore %destination_row_ptr %source_row
        \\    %source_column_ptr = OpAccessChain %ptr_uniform_matrix %source %int_1
        \\    %source_column = OpLoad %mat2x3 %source_column_ptr
        \\    %destination_column_ptr = OpAccessChain %ptr_uniform_matrix %destination %int_1
        \\    OpStore %destination_column_ptr %source_column
        \\    %push_ptr = OpAccessChain %ptr_push_matrix %push %int_0
        \\    %push_value = OpLoad %mat2x3 %push_ptr
        \\    %source_row_column_ptr = OpAccessChain %ptr_uniform_vec3 %source %int_0 %int_1
        \\    %source_row_column = OpLoad %vec3 %source_row_column_ptr
        \\    %destination_row_column_ptr = OpAccessChain %ptr_uniform_vec3 %destination %int_0 %int_1
        \\    OpStore %destination_row_column_ptr %source_row_column
        \\    %source_row_scalar_ptr = OpAccessChain %ptr_uniform_float %source %int_0 %int_1 %int_1
        \\    %source_row_scalar = OpLoad %float %source_row_scalar_ptr
        \\    %destination_row_scalar_ptr = OpAccessChain %ptr_uniform_float %destination %int_0 %int_1 %int_1
        \\    OpStore %destination_row_scalar_ptr %source_row_scalar
        \\    %source_column_vector_ptr = OpAccessChain %ptr_uniform_vec3 %source %int_1 %int_1
        \\    %source_column_vector = OpLoad %vec3 %source_column_vector_ptr
        \\    %destination_column_vector_ptr = OpAccessChain %ptr_uniform_vec3 %destination %int_1 %int_1
        \\    OpStore %destination_column_vector_ptr %source_column_vector
        \\    %push_column_ptr = OpAccessChain %ptr_push_vec3 %push %int_0 %int_1
        \\    %push_column = OpLoad %vec3 %push_column_ptr
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    var buffer_loads: usize = 0;
    var buffer_stores: usize = 0;
    var push_loads: usize = 0;
    const function = module.functions.get(module.entry_point.?).?;
    for (function.blocks.items) |block_id| {
        const block = module.blocks.get(block_id).?;
        for (block.instructions.items) |instruction_id| {
            const instruction = module.instructions.get(instruction_id).?;
            switch (instruction.operation) {
                .load_buffer => buffer_loads += 1,
                .store_buffer => buffer_stores += 1,
                .load_push_constant => push_loads += 1,
                else => {},
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 13), buffer_loads);
    try std.testing.expectEqual(@as(usize, 17), buffer_stores);
    try std.testing.expectEqual(@as(usize, 9), push_loads);
    try std.testing.expectEqual(@as(u32, 36), try matrixElementMemoryOffset(.{ .stride = 16, .major = .row }, 4, 1, 2));
    try std.testing.expectEqual(@as(u32, 24), try matrixElementMemoryOffset(.{ .stride = 16, .major = .column }, 4, 1, 2));

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    var parsed = try ir.parser.parseString(std.testing.allocator, text);
    defer parsed.deinit();
}

test "SPIR-V: storage buffer descriptor arrays" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\OpName %buffers "buffers"
        \\OpDecorate %Buffer BufferBlock
        \\OpMemberDecorate %Buffer 0 Offset 0
        \\OpDecorate %buffers Binding 0
        \\OpDecorate %buffers DescriptorSet 0
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%uint = OpTypeInt 32 0
        \\%uint_0 = OpConstant %uint 0
        \\%uint_1 = OpConstant %uint 1
        \\%uint_2 = OpConstant %uint 2
        \\%Buffer = OpTypeStruct %uint
        \\%buffers_array = OpTypeArray %Buffer %uint_2
        \\%ptr_uniform_buffers = OpTypePointer Uniform %buffers_array
        \\%ptr_uniform_uint = OpTypePointer Uniform %uint
        \\%buffers = OpVariable %ptr_uniform_buffers Uniform
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %first = OpAccessChain %ptr_uniform_uint %buffers %uint_0 %uint_0
        \\    OpStore %first %uint_1
        \\    %second = OpAccessChain %ptr_uniform_uint %buffers %uint_1 %uint_0
        \\    OpStore %second %uint_2
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), module.resources.entries.items.len);
    const first = module.resources.get(ir.id.ResourceId.fromIndex(0)).?;
    const second = module.resources.get(ir.id.ResourceId.fromIndex(1)).?;
    try std.testing.expectEqual(ir.types.ResourceKind.storage_buffer, first.kind);
    try std.testing.expectEqual(@as(u32, 0), first.array_element);
    try std.testing.expectEqual(@as(u32, 1), second.array_element);
    try std.testing.expectEqual(first.set, second.set);
    try std.testing.expectEqual(first.binding, second.binding);

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "@buffers: struct[u32] = storage_buffer[set(0), binding(0)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@resource1: struct[u32] = storage_buffer[set(0), binding(0), array_element(1)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_buffer @buffers") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_buffer @resource1") != null);

    var parsed = try ir.parser.parseString(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.resources.get(ir.id.ResourceId.fromIndex(1)).?.array_element);
}

test "SPIR-V: lowers 32-bit storage-buffer atomic add conservatively" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\OpName %previous "previous"
        \\OpName %buffer "buffer"
        \\OpDecorate %Buffer BufferBlock
        \\OpMemberDecorate %Buffer 0 Offset 0
        \\OpDecorate %buffer Binding 0
        \\OpDecorate %buffer DescriptorSet 0
        \\%void = OpTypeVoid
        \\%fn_void = OpTypeFunction %void
        \\%uint = OpTypeInt 32 0
        \\%zero = OpConstant %uint 0
        \\%one = OpConstant %uint 1
        \\%Buffer = OpTypeStruct %uint
        \\%ptr_uniform_buffer = OpTypePointer Uniform %Buffer
        \\%ptr_uniform_uint = OpTypePointer Uniform %uint
        \\%buffer = OpVariable %ptr_uniform_buffer Uniform
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %pointer = OpAccessChain %ptr_uniform_uint %buffer %zero
        \\    %previous = OpAtomicIAdd %uint %pointer %one %zero %one
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    try std.testing.expect(module.properties.uses_atomics);
    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "%previous: u32 = load_buffer @buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "integer_add %previous") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_buffer @buffer") != null);
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
        \\OpName %mode "mode"
        \\OpName %gather "gather"
        \\OpName %shifted "shifted"
        \\OpName %masked "masked"
        \\OpDecorate %number SpecId 7
        \\OpDecorate %enabled SpecId 8
        \\OpDecorate %mode SpecId 9
        \\%void = OpTypeVoid
        \\%bool = OpTypeBool
        \\%u32 = OpTypeInt 32 0
        \\%vec2_u32 = OpTypeVector %u32 2
        \\%fn_void = OpTypeFunction %void
        \\%number = OpSpecConstant %u32 12
        \\%enabled = OpSpecConstantFalse %bool
        \\%mode = OpSpecConstant %u32 0
        \\%zero = OpConstant %u32 0
        \\%one = OpConstant %u32 1
        \\%ten = OpConstant %u32 10
        \\%gather = OpSpecConstantOp %bool INotEqual %mode %zero
        \\%shifted = OpSpecConstantOp %u32 ShiftRightLogical %number %one
        \\%masked = OpSpecConstantOp %u32 BitwiseAnd %shifted %ten
        \\%masked_is_zero = OpSpecConstantOp %bool IEqual %masked %zero
        \\%pair = OpSpecConstantComposite %vec2_u32 %number %number
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %sum = OpIAdd %u32 %number %number
        \\    %selected = OpSelect %u32 %enabled %sum %number
        \\    %gather_selected = OpSelect %u32 %gather %sum %number
        \\    %first = OpCompositeExtract %u32 %pair 0
        \\    %masked_sum = OpIAdd %u32 %masked %first
        \\    %masked_selected = OpSelect %u32 %masked_is_zero %sum %number
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
    try expectNamedIntegerConstant(&defaults, "number", 12);
    try expectNamedIntegerConstant(&defaults, "shifted", 6);
    try expectNamedIntegerConstant(&defaults, "masked", 2);
    try expectNamedBooleanConstant(&defaults, "enabled", false);
    try expectSelectCondition(&defaults, 2, false);
    try expectSelectCondition(&defaults, 5, false);

    const number_override: u32 = 42;
    const enabled_override: u32 = 1;
    const mode_override: u32 = 1;
    const specializations = [_]SpecializationValue{
        .{ .constant_id = 7, .data = std.mem.asBytes(&number_override) },
        .{ .constant_id = 8, .data = std.mem.asBytes(&enabled_override) },
        .{ .constant_id = 9, .data = std.mem.asBytes(&mode_override) },
    };
    var specialized = try instantiate(std.testing.allocator, &source, .{
        .entry_point = "main",
        .stage = .compute,
        .specializations = &specializations,
    });
    defer specialized.deinit();
    try expectNamedIntegerConstant(&specialized, "number", 42);
    try expectNamedIntegerConstant(&specialized, "shifted", 21);
    try expectNamedIntegerConstant(&specialized, "masked", 0);
    try expectNamedBooleanConstant(&specialized, "enabled", true);
    try expectSelectCondition(&specialized, 2, true);
    try expectSelectCondition(&specialized, 5, true);

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
        \\%int = OpTypeInt 32 1
        \\%float = OpTypeFloat 32
        \\%vec2 = OpTypeVector %uint 2
        \\%fn_void = OpTypeFunction %void
        \\%true = OpConstantTrue %bool
        \\%one = OpConstant %uint 1
        \\%two = OpConstant %uint 2
        \\%negative_one = OpConstant %int -1
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %not = OpLogicalNot %bool %true
        \\    %sum = OpIAdd %uint %one %two
        \\    %less = OpULessThan %bool %one %two
        \\    %selected = OpSelect %uint %less %one %two
        \\    %cast = OpBitcast %float %one
        \\    %unsigned_float = OpConvertUToF %float %one
        \\    %signed_float = OpConvertSToF %float %negative_one
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
    try std.testing.expectEqual(@as(usize, 9), block.instructions.items.len);

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

    const unsigned_float = module.instructions.get(block.instructions.items[5]).?;
    try std.testing.expectEqual(ir.instruction.ConvertOpcode.unsigned_to_float, unsigned_float.operation.convert.opcode);

    const signed_float = module.instructions.get(block.instructions.items[6]).?;
    try std.testing.expectEqual(ir.instruction.ConvertOpcode.signed_to_float, signed_float.operation.convert.opcode);

    const construct = module.instructions.get(block.instructions.items[7]).?;
    try std.testing.expectEqual(@as(usize, 2), construct.operation.composite_construct.elements.len);

    const extract = module.instructions.get(block.instructions.items[8]).?;
    try std.testing.expectEqualSlices(u32, &.{1}, extract.operation.composite_extract.indices);
}

test "SPIR-V: core floating, matrix, and conversion operation mappings" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%bool = OpTypeBool
        \\%int = OpTypeInt 32 1
        \\%uint = OpTypeInt 32 0
        \\%float = OpTypeFloat 32
        \\%bvec3 = OpTypeVector %bool 3
        \\%ivec3 = OpTypeVector %int 3
        \\%uvec2 = OpTypeVector %uint 2
        \\%vec2 = OpTypeVector %float 2
        \\%vec3 = OpTypeVector %float 3
        \\%mat2x3 = OpTypeMatrix %vec3 2
        \\%mat3x2 = OpTypeMatrix %vec2 3
        \\%fn_void = OpTypeFunction %void
        \\%one = OpConstant %float 1
        \\%two = OpConstant %float 2
        \\%vector2 = OpConstantComposite %vec2 %one %two
        \\%vector3 = OpConstantComposite %vec3 %one %two %one
        \\%matrix2x3 = OpConstantComposite %mat2x3 %vector3 %vector3
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %infinite = OpIsInf %bvec3 %vector3
        \\    %nan = OpIsNan %bool %one
        \\    %transposed = OpTranspose %mat3x2 %matrix2x3
        \\    %remainder = OpFRem %vec3 %vector3 %vector3
        \\    %dot = OpDot %float %vector3 %vector3
        \\    %outer = OpOuterProduct %mat2x3 %vector3 %vector2
        \\    %signed = OpConvertFToS %ivec3 %vector3
        \\    %unsigned = OpConvertFToU %uvec2 %vector2
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    const block = module.blocks.get(function.entry_block.?).?;
    try std.testing.expectEqual(@as(usize, 8), block.instructions.items.len);

    const infinite = module.instructions.get(block.instructions.items[0]).?;
    try std.testing.expectEqual(ir.instruction.UnaryOpcode.is_inf, infinite.operation.unary.opcode);
    try expectVectorLength(&module, infinite.operation.unary.operand, 3);
    try expectVectorLength(&module, infinite.result.?, 3);

    const nan = module.instructions.get(block.instructions.items[1]).?;
    try std.testing.expectEqual(ir.instruction.UnaryOpcode.is_nan, nan.operation.unary.opcode);

    const transposed = module.instructions.get(block.instructions.items[2]).?;
    try std.testing.expectEqual(ir.instruction.UnaryOpcode.transpose, transposed.operation.unary.opcode);
    try expectMatrixShape(&module, transposed.operation.unary.operand, 2, 3);
    try expectMatrixShape(&module, transposed.result.?, 3, 2);

    const remainder = module.instructions.get(block.instructions.items[3]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.float_remainder, remainder.operation.binary.opcode);
    try expectVectorLength(&module, remainder.operation.binary.lhs, 3);
    try expectVectorLength(&module, remainder.operation.binary.rhs, 3);
    try expectVectorLength(&module, remainder.result.?, 3);

    const dot = module.instructions.get(block.instructions.items[4]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.dot, dot.operation.binary.opcode);
    try expectVectorLength(&module, dot.operation.binary.lhs, 3);
    try expectVectorLength(&module, dot.operation.binary.rhs, 3);
    try std.testing.expect(module.types.get(module.typeOf(dot.result.?).?).?.* == .floating);

    const outer = module.instructions.get(block.instructions.items[5]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.outer_product, outer.operation.binary.opcode);
    try expectVectorLength(&module, outer.operation.binary.lhs, 3);
    try expectVectorLength(&module, outer.operation.binary.rhs, 2);
    try expectMatrixShape(&module, outer.result.?, 2, 3);

    const signed = module.instructions.get(block.instructions.items[6]).?;
    try std.testing.expectEqual(ir.instruction.ConvertOpcode.float_to_signed, signed.operation.convert.opcode);
    try expectVectorLength(&module, signed.operation.convert.operand, 3);
    try expectVectorLength(&module, signed.result.?, 3);

    const unsigned = module.instructions.get(block.instructions.items[7]).?;
    try std.testing.expectEqual(ir.instruction.ConvertOpcode.float_to_unsigned, unsigned.operation.convert.opcode);
    try expectVectorLength(&module, unsigned.operation.convert.operand, 2);
    try expectVectorLength(&module, unsigned.result.?, 2);
}

fn expectVectorLength(module: *const ir.module.Module, value: ir.id.ValueId, expected_length: u8) !void {
    const value_type = module.typeOf(value) orelse return error.MissingValueType;
    const type_data = module.types.get(value_type) orelse return error.MissingValueType;
    try std.testing.expect(type_data.* == .vector);
    try std.testing.expectEqual(expected_length, type_data.vector.length);
}

fn expectMatrixShape(module: *const ir.module.Module, value: ir.id.ValueId, expected_columns: u8, expected_rows: u8) !void {
    const value_type = module.typeOf(value) orelse return error.MissingValueType;
    const type_data = module.types.get(value_type) orelse return error.MissingValueType;
    try std.testing.expect(type_data.* == .matrix);
    try std.testing.expectEqual(expected_columns, type_data.matrix.column_count);

    const column_type = module.types.get(type_data.matrix.element_type) orelse return error.MissingValueType;
    try std.testing.expect(column_type.* == .vector);
    try std.testing.expectEqual(expected_rows, column_type.vector.length);
}

test "SPIR-V: core integer extended and bit-field operations" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%uint = OpTypeInt 32 0
        \\%int = OpTypeInt 32 1
        \\%uint_pair = OpTypeStruct %uint %uint
        \\%int_pair = OpTypeStruct %int %int
        \\%fn_void = OpTypeFunction %void
        \\%one = OpConstant %uint 1
        \\%two = OpConstant %uint 2
        \\%offset = OpConstant %uint 4
        \\%count = OpConstant %uint 8
        \\%signed_two = OpConstant %int 2
        \\%signed_three = OpConstant %int 3
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %add_carry = OpIAddCarry %uint_pair %one %two
        \\    %add_value = OpCompositeExtract %uint %add_carry 0
        \\    %carry = OpCompositeExtract %uint %add_carry 1
        \\    %subtract_borrow = OpISubBorrow %uint_pair %two %one
        \\    %subtract_value = OpCompositeExtract %uint %subtract_borrow 0
        \\    %borrow = OpCompositeExtract %uint %subtract_borrow 1
        \\    %unsigned_extended = OpUMulExtended %uint_pair %one %two
        \\    %unsigned_low = OpCompositeExtract %uint %unsigned_extended 0
        \\    %unsigned_high = OpCompositeExtract %uint %unsigned_extended 1
        \\    %signed_extended = OpSMulExtended %int_pair %signed_two %signed_three
        \\    %signed_low = OpCompositeExtract %int %signed_extended 0
        \\    %signed_high = OpCompositeExtract %int %signed_extended 1
        \\    %signed_extract = OpBitFieldSExtract %int %signed_three %offset %count
        \\    %unsigned_extract = OpBitFieldUExtract %uint %two %offset %count
        \\    %insert = OpBitFieldInsert %uint %one %two %offset %count
        \\    %reverse = OpBitReverse %uint %one
        \\    %population = OpBitCount %uint %two
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    const block = module.blocks.get(function.entry_block.?).?;
    try std.testing.expectEqual(@as(usize, 17), block.instructions.items.len);

    try expectExtendedIntegerOperation(&module, block.instructions.items, 0, .integer_add_carry, 1, 2);
    try expectExtendedIntegerOperation(&module, block.instructions.items, 3, .integer_subtract_borrow, 2, 1);
    try expectExtendedIntegerOperation(&module, block.instructions.items, 6, .unsigned_multiply_extended, 1, 2);
    try expectExtendedIntegerOperation(&module, block.instructions.items, 9, .signed_multiply_extended, 2, 3);

    const signed_extract = module.instructions.get(block.instructions.items[12]).?;
    try std.testing.expect(signed_extract.operation == .bit_field_extract);
    try std.testing.expect(signed_extract.operation.bit_field_extract.opcode == .signed);
    try expectIntegerValue(&module, signed_extract.operation.bit_field_extract.base, 3);
    try expectIntegerValue(&module, signed_extract.operation.bit_field_extract.offset, 4);
    try expectIntegerValue(&module, signed_extract.operation.bit_field_extract.count, 8);

    const unsigned_extract = module.instructions.get(block.instructions.items[13]).?;
    try std.testing.expect(unsigned_extract.operation == .bit_field_extract);
    try std.testing.expect(unsigned_extract.operation.bit_field_extract.opcode == .unsigned);
    try expectIntegerValue(&module, unsigned_extract.operation.bit_field_extract.base, 2);
    try expectIntegerValue(&module, unsigned_extract.operation.bit_field_extract.offset, 4);
    try expectIntegerValue(&module, unsigned_extract.operation.bit_field_extract.count, 8);

    const insert = module.instructions.get(block.instructions.items[14]).?;
    try std.testing.expect(insert.operation == .bit_field_insert);
    try expectIntegerValue(&module, insert.operation.bit_field_insert.base, 1);
    try expectIntegerValue(&module, insert.operation.bit_field_insert.insert, 2);
    try expectIntegerValue(&module, insert.operation.bit_field_insert.offset, 4);
    try expectIntegerValue(&module, insert.operation.bit_field_insert.count, 8);

    const reverse = module.instructions.get(block.instructions.items[15]).?;
    try std.testing.expect(reverse.operation == .unary);
    try std.testing.expect(reverse.operation.unary.opcode == .bit_reverse);
    try expectIntegerValue(&module, reverse.operation.unary.operand, 1);

    const population = module.instructions.get(block.instructions.items[16]).?;
    try std.testing.expect(population.operation == .unary);
    try std.testing.expect(population.operation.unary.opcode == .bit_count);
    try expectIntegerValue(&module, population.operation.unary.operand, 2);
}

fn expectExtendedIntegerOperation(
    module: *const ir.module.Module,
    instructions: []const ir.id.InstructionId,
    instruction_index: usize,
    expected_opcode: ir.instruction.BinaryOpcode,
    expected_lhs: u64,
    expected_rhs: u64,
) !void {
    const instruction = module.instructions.get(instructions[instruction_index]).?;
    try std.testing.expect(instruction.operation == .binary);
    try std.testing.expectEqual(expected_opcode, instruction.operation.binary.opcode);
    try expectIntegerValue(module, instruction.operation.binary.lhs, expected_lhs);
    try expectIntegerValue(module, instruction.operation.binary.rhs, expected_rhs);

    const result = instruction.result orelse return error.MissingInstructionResult;
    const result_type = module.typeOf(result) orelse return error.MissingResultType;
    const result_type_data = module.types.get(result_type) orelse return error.MissingResultType;
    try std.testing.expect(result_type_data.* == .structure);
    try std.testing.expectEqual(@as(usize, 2), result_type_data.structure.members.len);
    try std.testing.expectEqual(result_type_data.structure.members[0], module.typeOf(instruction.operation.binary.lhs).?);
    try std.testing.expectEqual(result_type_data.structure.members[1], module.typeOf(instruction.operation.binary.rhs).?);

    for (0..2) |index| {
        const extract = module.instructions.get(instructions[instruction_index + index + 1]).?;
        try std.testing.expect(extract.operation == .composite_extract);
        try std.testing.expectEqual(result, extract.operation.composite_extract.composite);
        try std.testing.expectEqualSlices(u32, &.{@as(u32, @intCast(index))}, extract.operation.composite_extract.indices);
        try std.testing.expectEqual(result_type_data.structure.members[index], module.typeOf(extract.result.?).?);
    }
}

fn expectIntegerValue(module: *const ir.module.Module, value_id: ir.id.ValueId, expected: u64) !void {
    const value = module.values.get(value_id) orelse return error.MissingValue;
    try std.testing.expect(value.definition == .constant);
    const constant = module.constants.get(value.definition.constant) orelse return error.MissingConstant;
    try std.testing.expect(constant.value == .integer_bits);
    try std.testing.expectEqual(expected, constant.value.integer_bits);
}

test "SPIR-V: extended instruction imports are classified before use" {
    const unused_assembly =
        \\OpCapability Shader
        \\%opencl = OpExtInstImport "OpenCL.std"
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
    const unused_words = try assembleSpirv(std.testing.allocator, unused_assembly);
    defer std.testing.allocator.free(unused_words);
    var unused_module = try translate(std.testing.allocator, unused_words, .{ .entry_point = "main" });
    unused_module.deinit();

    const used_assembly =
        \\OpCapability Shader
        \\%opencl = OpExtInstImport "OpenCL.std"
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%float = OpTypeFloat 32
        \\%fn_void = OpTypeFunction %void
        \\%one = OpConstant %float 1
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %result = OpExtInst %float %opencl acos %one
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const used_words = try assembleSpirv(std.testing.allocator, used_assembly);
    defer std.testing.allocator.free(used_words);
    try std.testing.expectError(
        TranslationError.UnsupportedExtendedInstructionSet,
        translate(std.testing.allocator, used_words, .{ .entry_point = "main" }),
    );
}

test "SPIR-V: unsupported GLSL extended instruction reports its own error" {
    const assembly =
        \\OpCapability Shader
        \\%glsl = OpExtInstImport "GLSL.std.450"
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%float = OpTypeFloat 32
        \\%fn_void = OpTypeFunction %void
        \\%one = OpConstant %float 1
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %result = OpExtInst %float %glsl Trunc %one
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);
    try std.testing.expectError(
        TranslationError.UnsupportedExtendedInstruction,
        translate(std.testing.allocator, words, .{ .entry_point = "main" }),
    );
}

test "SPIR-V: translates common GLSL extended floating instructions" {
    const assembly =
        \\OpCapability Shader
        \\%glsl = OpExtInstImport "GLSL.std.450"
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint GLCompute %main "main"
        \\OpExecutionMode %main LocalSize 1 1 1
        \\%void = OpTypeVoid
        \\%float = OpTypeFloat 32
        \\%vec2 = OpTypeVector %float 2
        \\%fn_void = OpTypeFunction %void
        \\%zero = OpConstant %float 0
        \\%one = OpConstant %float 1
        \\%negative = OpConstant %float -2
        \\%vector = OpConstantComposite %vec2 %negative %one
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %absolute = OpExtInst %float %glsl FAbs %negative
        \\    %sign = OpExtInst %vec2 %glsl FSign %vector
        \\    %floored = OpExtInst %vec2 %glsl Floor %vector
        \\    %normalized = OpExtInst %vec2 %glsl Normalize %vector
        \\    %smooth = OpExtInst %float %glsl SmoothStep %zero %one %negative
        \\    %angle = OpExtInst %float %glsl Atan2 %one %one
        \\    %powered = OpExtInst %float %glsl Pow %one %negative
        \\    %maximum = OpExtInst %vec2 %glsl FMax %vector %vector
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    const block = module.blocks.get(function.entry_block.?).?;
    try std.testing.expectEqual(@as(usize, 8), block.instructions.items.len);

    const absolute = module.instructions.get(block.instructions.items[0]).?;
    try std.testing.expectEqual(ir.instruction.UnaryOpcode.absolute, absolute.operation.unary.opcode);

    const sign = module.instructions.get(block.instructions.items[1]).?;
    try std.testing.expectEqual(ir.instruction.UnaryOpcode.sign, sign.operation.unary.opcode);

    const floored = module.instructions.get(block.instructions.items[2]).?;
    try std.testing.expectEqual(ir.instruction.UnaryOpcode.floor, floored.operation.unary.opcode);

    const normalized = module.instructions.get(block.instructions.items[3]).?;
    try std.testing.expectEqual(ir.instruction.UnaryOpcode.normalize, normalized.operation.unary.opcode);

    const smooth = module.instructions.get(block.instructions.items[4]).?;
    try std.testing.expectEqual(ir.instruction.TernaryOpcode.smooth_step, smooth.operation.ternary.opcode);

    const angle = module.instructions.get(block.instructions.items[5]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.atan2, angle.operation.binary.opcode);

    const powered = module.instructions.get(block.instructions.items[6]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.pow, powered.operation.binary.opcode);

    const maximum = module.instructions.get(block.instructions.items[7]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.float_max, maximum.operation.binary.opcode);
}

test "SPIR-V: combined sampled-image descriptor arrays select matching elements" {
    for ([_][]const u8{ "%zero", "%two", "%three", "%dynamic" }, 0..) |index_name, case| {
        const assembly = try std.fmt.allocPrint(std.testing.allocator,
            \\OpCapability Shader
            \\OpCapability SampledImageArrayDynamicIndexing
            \\OpMemoryModel Logical GLSL450
            \\OpEntryPoint Fragment %main "main"
            \\OpExecutionMode %main OriginUpperLeft
            \\OpDecorate %textures DescriptorSet 1
            \\OpDecorate %textures Binding 4
            \\%void = OpTypeVoid
            \\%float = OpTypeFloat 32
            \\%uint = OpTypeInt 32 0
            \\%vec2 = OpTypeVector %float 2
            \\%vec4 = OpTypeVector %float 4
            \\%image = OpTypeImage %float 2D 0 0 0 1 Unknown
            \\%sampled_image = OpTypeSampledImage %image
            \\%zero = OpConstant %uint 0
            \\%two = OpConstant %uint 2
            \\%three = OpConstant %uint 3
            \\%array = OpTypeArray %sampled_image %three
            \\%array_ptr = OpTypePointer UniformConstant %array
            \\%element_ptr = OpTypePointer UniformConstant %sampled_image
            \\%fn = OpTypeFunction %void
            \\%coordinate = OpConstantNull %vec2
            \\%textures = OpVariable %array_ptr UniformConstant
            \\%main = OpFunction %void None %fn
            \\%entry = OpLabel
            \\%dynamic = OpIAdd %uint %zero %two
            \\%address = OpAccessChain %element_ptr %textures {s}
            \\%loaded = OpLoad %sampled_image %address
            \\%copied = OpCopyObject %sampled_image %loaded
            \\%result = OpImageSampleImplicitLod %vec4 %copied %coordinate
            \\OpReturn
            \\OpFunctionEnd
        , .{index_name});
        defer std.testing.allocator.free(assembly);
        const words = try assembleSpirv(std.testing.allocator, assembly);
        defer std.testing.allocator.free(words);
        if (case >= 2) {
            try std.testing.expectError(if (case == 2) error.InvalidInstruction else error.UnsupportedOpcode, translate(std.testing.allocator, words, .{ .entry_point = "main" }));
            continue;
        }
        var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
        defer module.deinit();
        try std.testing.expectEqual(@as(usize, 6), module.resources.entries.items.len);
        const function = module.functions.get(module.entry_point.?).?;
        const block = module.blocks.get(function.entry_block.?).?;
        const sample = module.instructions.get(block.instructions.items[block.instructions.items.len - 1]).?.operation.image_sample_implicit_lod;
        const image = module.resources.get(sample.image).?;
        const sampler = module.resources.get(sample.sampler).?;
        try std.testing.expectEqual(ir.types.ResourceKind.sampled_image, image.kind);
        try std.testing.expectEqual(ir.types.ResourceKind.sampler, sampler.kind);
        for ([_]*const ir.module.Resource{ image, sampler }) |resource| {
            try std.testing.expectEqual(@as(u32, 1), resource.set);
            try std.testing.expectEqual(@as(u32, 4), resource.binding);
            try std.testing.expectEqual(@as(u32, if (case == 0) 0 else 2), resource.array_element);
        }
    }
}

test "SPIR-V: combined cube-array descriptor and implicit-LOD sampling" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint Fragment %main "main"
        \\OpExecutionMode %main OriginUpperLeft
        \\OpName %descriptor "texture"
        \\OpDecorate %descriptor DescriptorSet 2
        \\OpDecorate %descriptor Binding 3
        \\%void = OpTypeVoid
        \\%float = OpTypeFloat 32
        \\%vec4 = OpTypeVector %float 4
        \\%image = OpTypeImage %float Cube 0 1 0 1 Unknown
        \\%sampled_image = OpTypeSampledImage %image
        \\%ptr_sampled_image = OpTypePointer UniformConstant %sampled_image
        \\%fn_void = OpTypeFunction %void
        \\%zero = OpConstant %float 0
        \\%coordinate = OpConstantComposite %vec4 %zero %zero %zero %zero
        \\%descriptor = OpVariable %ptr_sampled_image UniformConstant
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %loaded = OpLoad %sampled_image %descriptor
        \\    %implicit = OpImageSampleImplicitLod %vec4 %loaded %coordinate
        \\    %explicit = OpImageSampleExplicitLod %vec4 %loaded %coordinate Lod %zero
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), module.resources.entries.items.len);
    const image = module.resources.get(ir.id.ResourceId.fromIndex(0)).?;
    const sampler = module.resources.get(ir.id.ResourceId.fromIndex(1)).?;
    try std.testing.expectEqual(ir.types.ResourceKind.sampled_image, image.kind);
    try std.testing.expectEqual(ir.types.ResourceKind.sampler, sampler.kind);
    try std.testing.expectEqual(image.set, sampler.set);
    try std.testing.expectEqual(image.binding, sampler.binding);
    try std.testing.expectEqual(@as(u32, 2), image.set);
    try std.testing.expectEqual(@as(u32, 3), image.binding);

    const function = module.functions.get(module.entry_point.?).?;
    const block = module.blocks.get(function.entry_block.?).?;
    try std.testing.expectEqual(@as(usize, 2), block.instructions.items.len);
    const implicit = module.instructions.get(block.instructions.items[0]).?.operation.image_sample_implicit_lod;
    try std.testing.expectEqual(ir.types.ImageDimension.cube, implicit.dimension);
    try std.testing.expect(implicit.arrayed);
    try std.testing.expectEqual(ir.id.ResourceId.fromIndex(0), implicit.image);
    try std.testing.expectEqual(ir.id.ResourceId.fromIndex(1), implicit.sampler);

    const explicit = module.instructions.get(block.instructions.items[1]).?.operation.image_sample_explicit_lod;
    try std.testing.expectEqual(ir.types.ImageDimension.cube, explicit.dimension);
    try std.testing.expect(explicit.arrayed);
}

test "SPIR-V: translate 2D image gather" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint Fragment %main "main"
        \\OpExecutionMode %main OriginUpperLeft
        \\OpDecorate %descriptor DescriptorSet 0
        \\OpDecorate %descriptor Binding 0
        \\%void = OpTypeVoid
        \\%int = OpTypeInt 32 1
        \\%float = OpTypeFloat 32
        \\%vec2 = OpTypeVector %float 2
        \\%vec4 = OpTypeVector %float 4
        \\%image = OpTypeImage %float 2D 0 0 0 1 Unknown
        \\%sampled_image = OpTypeSampledImage %image
        \\%ptr_sampled_image = OpTypePointer UniformConstant %sampled_image
        \\%fn_void = OpTypeFunction %void
        \\%zero = OpConstant %float 0
        \\%component = OpConstant %int 2
        \\%coordinate = OpConstantComposite %vec2 %zero %zero
        \\%descriptor = OpVariable %ptr_sampled_image UniformConstant
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %loaded = OpLoad %sampled_image %descriptor
        \\    %gather = OpImageGather %vec4 %loaded %coordinate %component
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    const block = module.blocks.get(function.entry_block.?).?;
    try std.testing.expectEqual(@as(usize, 1), block.instructions.items.len);
    const gather = module.instructions.get(block.instructions.items[0]).?.operation.image_gather;
    try std.testing.expectEqual(ir.types.ImageDimension.two_d, gather.dimension);
    try std.testing.expect(!gather.arrayed);
    try std.testing.expectEqual(ir.id.ResourceId.fromIndex(0), gather.image);
    try std.testing.expectEqual(ir.id.ResourceId.fromIndex(1), gather.sampler);
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

    const nop_word: u32 = (@as(u32, 1) << 16) | @backingInt(spirv.Opcode.nop);
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

test "SPIR-V: translates used PointSize and ignores unused clip and cull block members" {
    const assembly =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\OpEntryPoint Vertex %main "main" %outputs
        \\OpDecorate %output_block Block
        \\OpMemberDecorate %output_block 0 BuiltIn Position
        \\OpMemberDecorate %output_block 1 BuiltIn PointSize
        \\OpMemberDecorate %output_block 2 BuiltIn ClipDistance
        \\OpMemberDecorate %output_block 3 BuiltIn CullDistance
        \\%void = OpTypeVoid
        \\%float = OpTypeFloat 32
        \\%vec4 = OpTypeVector %float 4
        \\%uint = OpTypeInt 32 0
        \\%one = OpConstant %uint 1
        \\%float_array = OpTypeArray %float %one
        \\%output_block = OpTypeStruct %vec4 %float %float_array %float_array
        \\%output_block_ptr = OpTypePointer Output %output_block
        \\%float_ptr = OpTypePointer Output %float
        \\%fn_void = OpTypeFunction %void
        \\%point_size_member = OpConstant %uint 1
        \\%point_size = OpConstant %float 1
        \\%outputs = OpVariable %output_block_ptr Output
        \\%main = OpFunction %void None %fn_void
        \\    %entry = OpLabel
        \\    %point_size_address = OpAccessChain %float_ptr %outputs %point_size_member
        \\    OpStore %point_size_address %point_size
        \\    OpReturn
        \\OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.interface_variables.entries.items.len);
    const point_size = module.interface_variables.get(ir.id.InterfaceVariableId.fromIndex(0)).?;
    try std.testing.expectEqual(ir.module.InterfaceDirection.output, point_size.direction);
    try std.testing.expect(point_size.semantic == .builtin);
    try std.testing.expectEqual(ir.module.Builtin.point_size, point_size.semantic.builtin);
}

fn expectSelectCondition(module: *const ir.module.Module, instruction_index: usize, expected: bool) !void {
    const function = module.functions.get(module.entry_point.?).?;
    const block = module.blocks.get(function.entry_block.?).?;
    const instruction = module.instructions.get(block.instructions.items[instruction_index]).?;
    try std.testing.expect(instruction.operation == .select);

    const condition = module.values.get(instruction.operation.select.condition).?;
    try std.testing.expect(condition.definition == .constant);
    const constant = module.constants.get(condition.definition.constant).?;
    try std.testing.expect(constant.value == .boolean);
    try std.testing.expectEqual(expected, constant.value.boolean);
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

test "SPIR-V: reject Private memory with helper functions" {
    // A shared read must not see a fresh undef/initializer in the helper.
    // Repeated calls to a sole owning helper must not reset its globals either.
    for ([_][]const u8{ "OpStore %global %initial\n", "" }) |main_store| {
        const assembly = try std.fmt.allocPrint(std.testing.allocator,
            \\OpCapability Shader
            \\OpMemoryModel Logical GLSL450
            \\OpEntryPoint Vertex %main "main"
            \\%void = OpTypeVoid
            \\%fn = OpTypeFunction %void
            \\%uint = OpTypeInt 32 0
            \\%one = OpConstant %uint 1
            \\%array = OpTypeArray %uint %one
            \\%initial = OpConstantComposite %array %one
            \\%ptr = OpTypePointer Private %array
            \\%global = OpVariable %ptr Private %initial
            \\%main = OpFunction %void None %fn
            \\%entry = OpLabel
            \\{s}%call1 = OpFunctionCall %void %helper
            \\%call2 = OpFunctionCall %void %helper
            \\OpReturn
            \\OpFunctionEnd
            \\%helper = OpFunction %void None %fn
            \\%helper_entry = OpLabel
            \\%read = OpLoad %array %global
            \\OpStore %global %read
            \\OpReturn
            \\OpFunctionEnd
            \\
        , .{main_store});
        defer std.testing.allocator.free(assembly);
        const words = try assembleSpirv(std.testing.allocator, assembly);
        defer std.testing.allocator.free(words);
        try std.testing.expectError(TranslationError.UnsupportedPrivateCrossFunction, translate(std.testing.allocator, words, .{ .entry_point = "main" }));
    }
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
