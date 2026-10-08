const std = @import("std");
const ids = @import("id.zig");
const type_ir = @import("type.zig");

pub const TypeId = ids.TypeId;
pub const ValueId = ids.ValueId;
pub const BlockId = ids.BlockId;
pub const FunctionId = ids.FunctionId;
pub const InterfaceVariableId = ids.InterfaceVariableId;
pub const ResourceId = ids.ResourceId;
pub const WorkgroupVariableId = ids.WorkgroupVariableId;

pub const SourceLocation = struct {
    file: ?[]const u8 = null,
    line: u32,
    column: u32,
};

pub const UnaryOpcode = enum {
    absolute,
    all,
    bit_count,
    bit_reverse,
    bitwise_not,
    is_inf,
    is_nan,
    logical_not,
    negate,
    normalize,
    transpose,
};

pub const BinaryOpcode = enum {
    arithmetic_shift_right,
    atan2,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    float_add,
    float_divide,
    float_modulo,
    float_multiply,
    float_remainder,
    float_subtract,
    integer_add,
    integer_add_carry,
    integer_multiply,
    integer_subtract,
    integer_subtract_borrow,
    logical_and,
    logical_or,
    logical_shift_right,
    dot,
    matrix_times_matrix,
    matrix_times_scalar,
    matrix_times_vector,
    outer_product,
    shift_left,
    signed_divide,
    signed_modulo,
    signed_multiply_extended,
    unsigned_divide,
    unsigned_modulo,
    unsigned_multiply_extended,
    vector_times_matrix,
    vector_times_scalar,
};

pub const TernaryOpcode = enum {
    smooth_step,
};

pub const BitFieldExtractOpcode = enum {
    signed,
    unsigned,
};

pub const ConvertOpcode = enum {
    float_to_signed,
    float_to_unsigned,
    signed_to_float,
    unsigned_to_float,
};

pub const CompareOpcode = enum {
    equal,
    not_equal,
    ordered_float_equal,
    ordered_float_less,
    ordered_float_less_equal,
    ordered_float_not_equal,
    signed_less,
    unordered_float_equal,
    unordered_float_less,
    unordered_float_not_equal,
    unsigned_less,
};

pub const Unary = struct {
    opcode: UnaryOpcode,
    operand: ValueId,
};

pub const Binary = struct {
    opcode: BinaryOpcode,
    lhs: ValueId,
    rhs: ValueId,
};

pub const Ternary = struct {
    opcode: TernaryOpcode,
    first: ValueId,
    second: ValueId,
    third: ValueId,
};

pub const BitFieldExtract = struct {
    opcode: BitFieldExtractOpcode,
    base: ValueId,
    offset: ValueId,
    count: ValueId,
};

pub const BitFieldInsert = struct {
    base: ValueId,
    insert: ValueId,
    offset: ValueId,
    count: ValueId,
};

pub const Compare = struct {
    opcode: CompareOpcode,
    lhs: ValueId,
    rhs: ValueId,
};

pub const Convert = struct {
    opcode: ConvertOpcode,
    operand: ValueId,
};

pub const Select = struct {
    condition: ValueId,
    true_value: ValueId,
    false_value: ValueId,
};

pub const CompositeConstruct = struct {
    elements: []const ValueId,
};

pub const CompositeExtract = struct {
    composite: ValueId,
    indices: []const u32,
};

pub const LoadInterface = struct {
    variable: InterfaceVariableId,
    element_index: ?ValueId = null,
};

pub const StoreInterface = struct {
    variable: InterfaceVariableId,
    value: ValueId,
    element_index: ?ValueId = null,
};

pub const LoadPushConstant = struct {
    byte_offset: ValueId,
};

pub const LoadBuffer = struct {
    resource: ResourceId,
    byte_offset: ValueId,
    descriptor_index: ?ValueId = null,
};

pub const StoreBuffer = struct {
    resource: ResourceId,
    byte_offset: ValueId,
    value: ValueId,
    descriptor_index: ?ValueId = null,
};

pub const LoadWorkgroup = struct {
    variable: WorkgroupVariableId,
    byte_offset: ValueId,
};

pub const ImageRead = struct {
    resource: ResourceId,
    coordinate: ValueId,
};

pub const ImageSampleExplicitLod = struct {
    image: ResourceId,
    sampler: ResourceId,
    coordinate: ValueId,
    lod: ValueId,
    dimension: type_ir.ImageDimension = .two_d,
    arrayed: bool = false,
};

pub const ImageSampleImplicitLod = struct {
    image: ResourceId,
    sampler: ResourceId,
    coordinate: ValueId,
    dimension: type_ir.ImageDimension,
    arrayed: bool,
};

pub const ImageGather = struct {
    image: ResourceId,
    sampler: ResourceId,
    coordinate: ValueId,
    component: ValueId,
    dimension: type_ir.ImageDimension,
    arrayed: bool,
};

pub const ImageWrite = struct {
    resource: ResourceId,
    coordinate: ValueId,
    value: ValueId,
};

pub const StoreWorkgroup = struct {
    variable: WorkgroupVariableId,
    byte_offset: ValueId,
    value: ValueId,
};

pub const Call = struct {
    function: FunctionId,
    arguments: []const ValueId,
};

pub const ArrayLength = struct {
    resource: ResourceId,
    byte_offset: ValueId,
    stride: u32,
    descriptor_index: ?ValueId = null,
};

pub const Operation = union(enum) {
    unary: Unary,
    binary: Binary,
    ternary: Ternary,
    bit_field_extract: BitFieldExtract,
    bit_field_insert: BitFieldInsert,
    compare: Compare,
    select: Select,
    bitcast: ValueId,
    convert: Convert,
    composite_construct: CompositeConstruct,
    composite_extract: CompositeExtract,
    load_interface: LoadInterface,
    store_interface: StoreInterface,
    load_push_constant: LoadPushConstant,
    load_buffer: LoadBuffer,
    store_buffer: StoreBuffer,
    load_workgroup: LoadWorkgroup,
    store_workgroup: StoreWorkgroup,
    image_read: ImageRead,
    image_sample_explicit_lod: ImageSampleExplicitLod,
    image_sample_implicit_lod: ImageSampleImplicitLod,
    image_gather: ImageGather,
    image_write: ImageWrite,
    control_barrier,
    call: Call,
    array_length: ArrayLength,

    pub fn visitValueUses(self: Operation, context: anytype, comptime visitor: anytype) void {
        switch (self) {
            .unary => |op| visitor(context, op.operand),
            .binary => |op| {
                visitor(context, op.lhs);
                visitor(context, op.rhs);
            },
            .ternary => |op| {
                visitor(context, op.first);
                visitor(context, op.second);
                visitor(context, op.third);
            },
            .bit_field_extract => |op| {
                visitor(context, op.base);
                visitor(context, op.offset);
                visitor(context, op.count);
            },
            .bit_field_insert => |op| {
                visitor(context, op.base);
                visitor(context, op.insert);
                visitor(context, op.offset);
                visitor(context, op.count);
            },
            .compare => |op| {
                visitor(context, op.lhs);
                visitor(context, op.rhs);
            },
            .select => |op| {
                visitor(context, op.condition);
                visitor(context, op.true_value);
                visitor(context, op.false_value);
            },
            .bitcast => |operand| visitor(context, operand),
            .convert => |op| visitor(context, op.operand),
            .composite_construct => |op| for (op.elements) |element| visitor(context, element),
            .composite_extract => |op| visitor(context, op.composite),
            .load_interface => |op| if (op.element_index) |index| visitor(context, index),
            .store_interface => |op| {
                visitor(context, op.value);
                if (op.element_index) |index|
                    visitor(context, index);
            },
            .load_push_constant => |op| visitor(context, op.byte_offset),
            .load_buffer => |op| {
                visitor(context, op.byte_offset);
                if (op.descriptor_index) |index|
                    visitor(context, index);
            },
            .store_buffer => |op| {
                visitor(context, op.byte_offset);
                visitor(context, op.value);
                if (op.descriptor_index) |index|
                    visitor(context, index);
            },
            .load_workgroup => |op| visitor(context, op.byte_offset),
            .store_workgroup => |op| {
                visitor(context, op.byte_offset);
                visitor(context, op.value);
            },
            .image_read => |op| visitor(context, op.coordinate),
            .image_sample_explicit_lod => |op| {
                visitor(context, op.coordinate);
                visitor(context, op.lod);
            },
            .image_sample_implicit_lod => |op| visitor(context, op.coordinate),
            .image_gather => |op| {
                visitor(context, op.coordinate);
                visitor(context, op.component);
            },
            .image_write => |op| {
                visitor(context, op.coordinate);
                visitor(context, op.value);
            },
            .control_barrier => {},
            .call => |op| {
                for (op.arguments) |argument|
                    visitor(context, argument);
            },
            .array_length => |op| {
                visitor(context, op.byte_offset);
                if (op.descriptor_index) |index|
                    visitor(context, index);
            },
        }
    }

    pub fn replaceValueUses(self: *Operation, allocator: std.mem.Allocator, old: ValueId, replacement: ValueId) !usize {
        var count: usize = 0;
        switch (self.*) {
            .unary => |*op| replaceOne(&op.operand, old, replacement, &count),
            .binary => |*op| {
                replaceOne(&op.lhs, old, replacement, &count);
                replaceOne(&op.rhs, old, replacement, &count);
            },
            .ternary => |*op| {
                replaceOne(&op.first, old, replacement, &count);
                replaceOne(&op.second, old, replacement, &count);
                replaceOne(&op.third, old, replacement, &count);
            },
            .bit_field_extract => |*op| {
                replaceOne(&op.base, old, replacement, &count);
                replaceOne(&op.offset, old, replacement, &count);
                replaceOne(&op.count, old, replacement, &count);
            },
            .bit_field_insert => |*op| {
                replaceOne(&op.base, old, replacement, &count);
                replaceOne(&op.insert, old, replacement, &count);
                replaceOne(&op.offset, old, replacement, &count);
                replaceOne(&op.count, old, replacement, &count);
            },
            .compare => |*op| {
                replaceOne(&op.lhs, old, replacement, &count);
                replaceOne(&op.rhs, old, replacement, &count);
            },
            .select => |*op| {
                replaceOne(&op.condition, old, replacement, &count);
                replaceOne(&op.true_value, old, replacement, &count);
                replaceOne(&op.false_value, old, replacement, &count);
            },
            .bitcast => |*operand| replaceOne(operand, old, replacement, &count),
            .convert => |*op| replaceOne(&op.operand, old, replacement, &count),
            .composite_construct => |*op| op.elements = try replaceSlice(allocator, op.elements, old, replacement, &count),
            .composite_extract => |*op| replaceOne(&op.composite, old, replacement, &count),
            .load_interface => |*op| {
                if (op.element_index) |*index|
                    replaceOne(index, old, replacement, &count);
            },
            .store_interface => |*op| {
                replaceOne(&op.value, old, replacement, &count);
                if (op.element_index) |*index|
                    replaceOne(index, old, replacement, &count);
            },
            .load_push_constant => |*op| replaceOne(&op.byte_offset, old, replacement, &count),
            .load_buffer => |*op| {
                replaceOne(&op.byte_offset, old, replacement, &count);
                if (op.descriptor_index) |*index|
                    replaceOne(index, old, replacement, &count);
            },
            .store_buffer => |*op| {
                replaceOne(&op.byte_offset, old, replacement, &count);
                replaceOne(&op.value, old, replacement, &count);
                if (op.descriptor_index) |*index|
                    replaceOne(index, old, replacement, &count);
            },
            .load_workgroup => |*op| replaceOne(&op.byte_offset, old, replacement, &count),
            .store_workgroup => |*op| {
                replaceOne(&op.byte_offset, old, replacement, &count);
                replaceOne(&op.value, old, replacement, &count);
            },
            .image_read => |*op| replaceOne(&op.coordinate, old, replacement, &count),
            .image_sample_explicit_lod => |*op| {
                replaceOne(&op.coordinate, old, replacement, &count);
                replaceOne(&op.lod, old, replacement, &count);
            },
            .image_sample_implicit_lod => |*op| replaceOne(&op.coordinate, old, replacement, &count),
            .image_gather => |*op| {
                replaceOne(&op.coordinate, old, replacement, &count);
                replaceOne(&op.component, old, replacement, &count);
            },
            .image_write => |*op| {
                replaceOne(&op.coordinate, old, replacement, &count);
                replaceOne(&op.value, old, replacement, &count);
            },
            .control_barrier => {},
            .call => |*op| op.arguments = try replaceSlice(allocator, op.arguments, old, replacement, &count),
            .array_length => |*op| {
                replaceOne(&op.byte_offset, old, replacement, &count);
                if (op.descriptor_index) |*index|
                    replaceOne(index, old, replacement, &count);
            },
        }
        return count;
    }

    pub fn hasSideEffects(self: Operation) bool {
        return switch (self) {
            .store_interface,
            .store_buffer,
            .store_workgroup,
            .image_write,
            .control_barrier,
            .call,
            => true,

            else => false,
        };
    }
};

pub const Instruction = struct {
    parent_block: BlockId,
    result: ?ValueId,
    operation: Operation,
    source: ?SourceLocation = null,
};

fn replaceOne(operand: *ValueId, old: ValueId, replacement: ValueId, count: *usize) void {
    if (operand.* != old) return;
    operand.* = replacement;
    count.* += 1;
}

fn replaceSlice(
    allocator: std.mem.Allocator,
    operands: []const ValueId,
    old: ValueId,
    replacement: ValueId,
    count: *usize,
) ![]const ValueId {
    var occurrences: usize = 0;
    for (operands) |operand| if (operand == old) {
        occurrences += 1;
    };

    if (occurrences == 0)
        return operands;

    const copy = try allocator.dupe(ValueId, operands);
    for (copy) |*operand| {
        if (operand.* == old)
            operand.* = replacement;
    }

    count.* += occurrences;
    return copy;
}
