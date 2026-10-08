const std = @import("std");
const shader_ir = @import("shader_ir");
const bc = @import("bytecode.zig");

const ir = shader_ir.ir;
const ids = ir.id;
const inst_ir = ir.instruction;
const module_ir = ir.module;

pub const CompileError = error{
    InvalidConstant,
    InvalidControlFlow,
    InvalidInterface,
    InvalidOperation,
    InvalidValue,
    TooManyInstructions,
    TooManyRegisters,
    TooMuchWorkgroupMemory,
    UnsupportedOperation,
    UnsupportedType,
};

pub const InterfaceBinding = struct {
    direction: module_ir.InterfaceDirection,
    semantic: module_ir.InterfaceSemantic,
    span: bc.Span,
};

pub const ResourceBinding = struct {
    kind: ir.types.ResourceKind,
    set: u32,
    binding: u32,
    array_element: u32,
};

pub const WorkgroupBinding = struct {
    byte_offset: u32,
    byte_size: u32,
};

pub const RegisterInit = struct {
    register: bc.Register,
    value: u32,
};

pub const ImageDimension = ir.types.ImageDimension;

pub const ImageSamplerPair = struct {
    image: ids.ResourceId,
    sampler: ids.ResourceId,
    dimension: ImageDimension,
    arrayed: bool,
    destination_kind: bc.ValueKind,
};

pub const DescriptorCandidate = struct {
    array_element: u32,
    resource: ids.ResourceId,
};

pub const DescriptorArray = struct {
    candidates: []const DescriptorCandidate,
};

const Self = @This();

arena: std.heap.ArenaAllocator,
stage: module_ir.Stage,
uses_atomics: bool,
uses_control_barriers: bool,
workgroup_memory_size: usize,
entry_pc: u32,
register_count: usize,
scratch_count: usize,
array_lengths: []const bc.ArrayLength,
descriptor_arrays: []const DescriptorArray,
image_sampler_pairs: []const ImageSamplerPair,
code: []const bc.Instruction,
edges: []const bc.Edge,
copies: []const bc.Copy,
branches: []const bc.Branch,
initializers: []const RegisterInit,
interfaces: []const ?InterfaceBinding,
resources: []const ?ResourceBinding,
workgroup_variables: []const ?WorkgroupBinding,

pub fn compile(backing_allocator: std.mem.Allocator, module: *const module_ir.Module) !Self {
    if (!module.properties.valid_cfg or !module.properties.valid_ssa)
        try ir.validator.validate(module);

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();

    var lowerer = try Lowerer.init(arena.allocator(), module);
    try lowerer.lower();

    return .{
        .arena = arena,
        .stage = module.stage,
        .uses_atomics = module.properties.uses_atomics,
        .uses_control_barriers = module.properties.uses_control_barriers,
        .workgroup_memory_size = lowerer.workgroup_memory_size,
        .entry_pc = lowerer.entry_pc,
        .register_count = lowerer.register_count,
        .scratch_count = lowerer.scratch_count,
        .array_lengths = lowerer.array_lengths.items,
        .descriptor_arrays = lowerer.descriptor_arrays.items,
        .image_sampler_pairs = lowerer.image_sampler_pairs.items,
        .code = lowerer.code.items,
        .edges = lowerer.edges.items,
        .copies = lowerer.copies.items,
        .branches = lowerer.branches.items,
        .initializers = lowerer.initializers.items,
        .interfaces = lowerer.interfaces,
        .resources = lowerer.resources,
        .workgroup_variables = lowerer.workgroup_variables,
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn interfaceBinding(self: *const Self, variable: ids.InterfaceVariableId) ?InterfaceBinding {
    if (variable.index() >= self.interfaces.len)
        return null;
    return self.interfaces[variable.index()];
}

pub fn resourceBinding(self: *const Self, resource: ids.ResourceId) ?ResourceBinding {
    if (resource.index() >= self.resources.len)
        return null;

    return self.resources[resource.index()];
}

pub fn workgroupBinding(self: *const Self, variable: ids.WorkgroupVariableId) ?WorkgroupBinding {
    if (variable.index() >= self.workgroup_variables.len)
        return null;

    return self.workgroup_variables[variable.index()];
}

const Lowerer = struct {
    allocator: std.mem.Allocator,
    module: *const module_ir.Module,
    function: *const module_ir.Function,
    entry_block: ids.BlockId,
    values: []?bc.Span,
    interfaces: []?InterfaceBinding,
    resources: []?ResourceBinding,
    workgroup_variables: []?WorkgroupBinding,
    block_pcs: []?u32,
    register_count: usize = 0,
    scratch_count: usize = 0,
    entry_pc: u32 = 0,
    workgroup_memory_size: usize = 0,
    array_lengths: std.ArrayList(bc.ArrayLength) = .empty,
    descriptor_arrays: std.ArrayList(DescriptorArray) = .empty,
    image_sampler_pairs: std.ArrayList(ImageSamplerPair) = .empty,
    code: std.ArrayList(bc.Instruction) = .empty,
    edges: std.ArrayList(bc.Edge) = .empty,
    copies: std.ArrayList(bc.Copy) = .empty,
    branches: std.ArrayList(bc.Branch) = .empty,
    initializers: std.ArrayList(RegisterInit) = .empty,

    fn init(allocator: std.mem.Allocator, module: *const module_ir.Module) !Lowerer {
        const entry_id = module.entry_point orelse return CompileError.InvalidControlFlow;
        const function = module.functions.get(entry_id) orelse return CompileError.InvalidControlFlow;
        const entry_block = function.entry_block orelse return CompileError.InvalidControlFlow;

        if (function.parameters.items.len != 0)
            return CompileError.UnsupportedOperation;

        const values = try allocator.alloc(?bc.Span, module.values.entries.items.len);
        @memset(values, null);

        const interfaces = try allocator.alloc(?InterfaceBinding, module.interface_variables.entries.items.len);
        @memset(interfaces, null);

        const resources = try allocator.alloc(?ResourceBinding, module.resources.entries.items.len);
        for (module.resources.entries.items, resources) |entry, *binding| {
            binding.* = if (entry) |resource| .{
                .kind = resource.kind,
                .set = resource.set,
                .binding = resource.binding,
                .array_element = resource.array_element,
            } else null;
        }

        const workgroup_variables = try allocator.alloc(?WorkgroupBinding, module.workgroup_variables.entries.items.len);
        @memset(workgroup_variables, null);

        var workgroup_memory_size: usize = 0;
        for (module.workgroup_variables.entries.items, workgroup_variables) |entry, *binding| {
            const variable = entry orelse continue;
            const byte_size = try typeByteSize(module, variable.type);

            if (byte_size == 0)
                return CompileError.UnsupportedType;

            if (workgroup_memory_size > std.math.maxInt(u32) or byte_size > std.math.maxInt(u32))
                return CompileError.TooMuchWorkgroupMemory;

            binding.* = .{ .byte_offset = @intCast(workgroup_memory_size), .byte_size = @intCast(byte_size) };
            workgroup_memory_size = std.math.add(usize, workgroup_memory_size, byte_size) catch return CompileError.TooMuchWorkgroupMemory;
        }

        const block_pcs = try allocator.alloc(?u32, module.blocks.entries.items.len);
        @memset(block_pcs, null);

        return .{
            .allocator = allocator,
            .module = module,
            .function = function,
            .entry_block = entry_block,
            .values = values,
            .interfaces = interfaces,
            .resources = resources,
            .workgroup_variables = workgroup_variables,
            .workgroup_memory_size = workgroup_memory_size,
            .block_pcs = block_pcs,
        };
    }

    fn lower(self: *Lowerer) !void {
        for (self.module.values.entries.items, 0..) |entry, index| {
            const value = entry orelse continue;
            self.values[index] = try self.allocate(value.type);
        }
        for (self.module.interface_variables.entries.items, 0..) |entry, index| {
            const variable = entry orelse continue;
            self.interfaces[index] = .{
                .direction = variable.direction,
                .semantic = variable.semantic,
                .span = try self.allocate(variable.type),
            };
        }
        try self.initializeConstants();

        for (self.function.blocks.items) |block_id| {
            const block = self.module.blocks.get(block_id) orelse return CompileError.InvalidControlFlow;
            self.block_pcs[block_id.index()] = try u32Index(self.code.items.len);
            for (block.instructions.items) |instruction_id| {
                const instruction = self.module.instructions.get(instruction_id) orelse return CompileError.InvalidOperation;
                try self.lowerInstruction(instruction);
            }
            try self.lowerTerminator(block.terminator orelse return CompileError.InvalidControlFlow);
        }

        for (self.edges.items) |*edge| {
            if (edge.target_block >= self.block_pcs.len)
                return CompileError.InvalidControlFlow;

            edge.target_pc = self.block_pcs[edge.target_block] orelse return CompileError.InvalidControlFlow;
        }
        self.entry_pc = self.block_pcs[self.entry_block.index()] orelse return CompileError.InvalidControlFlow;
    }

    fn shape(self: *Lowerer, type_id: ids.TypeId) CompileError!bc.Span {
        const ty = self.module.types.get(type_id) orelse return CompileError.UnsupportedType;
        var components: u8 = 1;
        const kind: bc.ValueKind = switch (ty.*) {
            .boolean => .boolean,
            .integer => |integer| if (integer.bits == 32)
                if (integer.signedness == .signed) .signed_integer else .unsigned_integer
            else
                return CompileError.UnsupportedType,
            .floating => |floating| if (floating.bits == 32)
                .floating
            else
                return CompileError.UnsupportedType,
            .vector => |vector| blk: {
                const element = self.module.types.get(vector.element_type) orelse return CompileError.UnsupportedType;
                components = vector.length;
                break :blk switch (element.*) {
                    .boolean => .boolean,
                    .integer => |integer| if (integer.bits == 32)
                        if (integer.signedness == .signed) .signed_integer else .unsigned_integer
                    else
                        return CompileError.UnsupportedType,
                    .floating => |floating| if (floating.bits == 32) .floating else return CompileError.UnsupportedType,
                    else => return CompileError.UnsupportedType,
                };
            },
            .matrix => |matrix| blk: {
                const column = try self.shape(matrix.element_type);
                components = std.math.mul(u8, column.components, matrix.column_count) catch return CompileError.UnsupportedType;
                break :blk column.kind;
            },
            .array => |array| blk: {
                const element = try self.shape(array.element_type);
                const length = std.math.cast(u8, array.length) orelse return CompileError.UnsupportedType;
                components = std.math.mul(u8, element.components, length) catch return CompileError.UnsupportedType;
                if (components == 0) return CompileError.UnsupportedType;
                break :blk element.kind;
            },
            .structure => |structure| blk: {
                if (structure.members.len == 0)
                    return CompileError.UnsupportedType;

                const first = try self.shape(structure.members[0]);
                components = first.components;
                for (structure.members[1..]) |member_type| {
                    const member = try self.shape(member_type);
                    if (member.kind != first.kind)
                        return CompileError.UnsupportedType;
                    components = std.math.add(u8, components, member.components) catch return CompileError.UnsupportedType;
                }
                break :blk first.kind;
            },
            else => return CompileError.UnsupportedType,
        };
        return .{ .base = .invalid_register, .components = components, .kind = kind };
    }

    const MatrixLayout = struct {
        rows: u8,
        columns: u8,
    };

    fn matrixLayout(self: *const Lowerer, type_id: ids.TypeId) CompileError!MatrixLayout {
        const ty = self.module.types.get(type_id) orelse return CompileError.UnsupportedType;
        const matrix = switch (ty.*) {
            .matrix => |matrix| matrix,
            else => return CompileError.UnsupportedType,
        };
        const column_type = self.module.types.get(matrix.element_type) orelse return CompileError.UnsupportedType;
        const column = switch (column_type.*) {
            .vector => |vector| vector,
            else => return CompileError.UnsupportedType,
        };
        return .{ .rows = column.length, .columns = matrix.column_count };
    }

    fn allocate(self: *Lowerer, type_id: ids.TypeId) !bc.Span {
        const layout = try self.shape(type_id);
        const components = layout.components;
        const kind = layout.kind;
        const end = std.math.add(usize, self.register_count, components) catch return CompileError.TooManyRegisters;

        if (end > @as(usize, @backingInt(bc.Register.invalid_register)) + 1)
            return CompileError.TooManyRegisters;

        const allocated: bc.Span = .{ .base = @fromBackingInt(@intCast(self.register_count)), .components = components, .kind = kind };
        self.register_count = end;
        return allocated;
    }

    fn initializeConstants(self: *Lowerer) !void {
        for (self.module.values.entries.items, self.values) |entry, destination| {
            const value = entry orelse continue;
            if (value.definition == .constant)
                try self.initializeConstant(destination orelse return CompileError.InvalidValue, value.definition.constant);
        }
    }

    fn initializeConstant(self: *Lowerer, destination: bc.Span, constant_id: ids.ConstantId) !void {
        const constant = self.module.constants.get(constant_id) orelse return CompileError.InvalidConstant;
        switch (constant.value) {
            .boolean => |value| {
                if (destination.components != 1 or destination.kind != .boolean)
                    return CompileError.InvalidConstant;

                try self.initializers.append(self.allocator, .{ .register = destination.base, .value = @intFromBool(value) });
            },
            .integer_bits, .float_bits => |value| {
                if (destination.components != 1)
                    return CompileError.InvalidConstant;

                try self.initializers.append(self.allocator, .{ .register = destination.base, .value = @truncate(value) });
            },
            .null, .undef => for (0..destination.components) |component|
                try self.initializers.append(self.allocator, .{ .register = try offset(destination.base, component), .value = 0 }),
            .composite => |elements| {
                var component: usize = 0;
                for (elements) |element| {
                    const child = self.module.constants.get(element) orelse return CompileError.InvalidConstant;
                    var layout = try self.shape(child.type);
                    if (layout.kind != destination.kind or component + layout.components > destination.components)
                        return CompileError.InvalidConstant;
                    layout.base = try offset(destination.base, component);
                    try self.initializeConstant(layout, element);
                    component += layout.components;
                }
                if (component != destination.components) return CompileError.InvalidConstant;
            },
        }
    }

    fn lowerInstruction(self: *Lowerer, instruction: *const inst_ir.Instruction) !void {
        const result = if (instruction.result) |id| try self.span(id) else null;
        switch (instruction.operation) {
            .unary => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const src = try self.span(op.operand);

                if (op.opcode == .is_inf or op.opcode == .is_nan) {
                    if (dst.kind != .boolean or src.kind != .floating or dst.components != src.components)
                        return CompileError.InvalidOperation;
                    try self.emit(if (op.opcode == .is_inf) .is_inf else .is_nan, dst.components, dst.base, src.base, .invalid_register, .invalid_register, 0);
                    return;
                }

                if (op.opcode == .transpose) {
                    const result_id = instruction.result orelse return CompileError.InvalidOperation;
                    const src_layout = try self.matrixLayout(self.module.typeOf(op.operand) orelse return CompileError.InvalidValue);
                    const dst_layout = try self.matrixLayout(self.module.typeOf(result_id) orelse return CompileError.InvalidValue);
                    if (src.kind != .floating or dst.kind != .floating or
                        dst_layout.rows != src_layout.columns or dst_layout.columns != src_layout.rows or
                        src.components != try componentProduct(src_layout.rows, src_layout.columns) or
                        dst.components != try componentProduct(dst_layout.rows, dst_layout.columns))
                        return CompileError.InvalidOperation;

                    try self.emit(.transpose, dst.components, dst.base, src.base, .invalid_register, .invalid_register, (bc.MatrixDimensions{
                        .rows = src_layout.rows,
                        .inner = 0,
                        .columns = src_layout.columns,
                    }).encode());
                    return;
                }

                const opcode: bc.Opcode = switch (op.opcode) {
                    .absolute => if (dst.kind == .floating) .absolute else return CompileError.InvalidOperation,
                    .all => {
                        if (dst.kind != .boolean or dst.components != 1 or src.kind != .boolean)
                            return CompileError.InvalidOperation;
                        try self.emit(.all, src.components, dst.base, src.base, .invalid_register, .invalid_register, 0);
                        return;
                    },
                    .negate => switch (dst.kind) {
                        .signed_integer => .negate_i32,
                        .floating => .negate_f32,
                        else => return CompileError.InvalidOperation,
                    },
                    .normalize => if (dst.kind == .floating) .normalize else return CompileError.InvalidOperation,
                    .logical_not => if (dst.kind == .boolean) .logical_not else return CompileError.InvalidOperation,
                    .bitwise_not => switch (dst.kind) {
                        .signed_integer, .unsigned_integer => .bitwise_not,
                        else => return CompileError.InvalidOperation,
                    },
                    .bit_count => .bit_count,
                    .bit_reverse => .bit_reverse,
                    else => return CompileError.UnsupportedOperation,
                };
                if (!dst.sameShape(src))
                    return CompileError.InvalidOperation;
                try self.emit(opcode, dst.components, dst.base, src.base, .invalid_register, .invalid_register, 0);
            },
            .binary => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const lhs = try self.span(op.lhs);
                const rhs = try self.span(op.rhs);
                const opcode = try binaryOpcode(op.opcode, dst.kind);

                if (op.opcode == .dot) {
                    if (dst.kind != .floating or dst.components != 1 or lhs.kind != .floating or
                        lhs.components < 2 or !lhs.sameShape(rhs))
                        return CompileError.InvalidOperation;
                    try self.emit(opcode, lhs.components, dst.base, lhs.base, rhs.base, .invalid_register, 0);
                    return;
                }

                if (op.opcode == .outer_product) {
                    const result_id = instruction.result orelse return CompileError.InvalidOperation;
                    const layout = try self.matrixLayout(self.module.typeOf(result_id) orelse return CompileError.InvalidValue);
                    if (dst.kind != .floating or lhs.kind != .floating or rhs.kind != .floating or
                        lhs.components != layout.rows or rhs.components != layout.columns or
                        dst.components != try componentProduct(layout.rows, layout.columns))
                        return CompileError.InvalidOperation;
                    try self.emit(opcode, dst.components, dst.base, lhs.base, rhs.base, .invalid_register, (bc.MatrixDimensions{
                        .rows = layout.rows,
                        .inner = 0,
                        .columns = layout.columns,
                    }).encode());
                    return;
                }

                if (isExtendedBinaryOpcode(op.opcode)) {
                    const result_components = std.math.mul(u8, lhs.components, 2) catch return CompileError.InvalidOperation;
                    if (!lhs.sameShape(rhs) or lhs.kind != dst.kind or dst.components != result_components)
                        return CompileError.InvalidOperation;
                    try self.emit(opcode, lhs.components, dst.base, lhs.base, rhs.base, .invalid_register, 0);
                    return;
                }

                switch (op.opcode) {
                    .matrix_times_matrix => {
                        const lhs_layout = try self.matrixLayout(self.module.typeOf(op.lhs) orelse return CompileError.InvalidValue);
                        const rhs_layout = try self.matrixLayout(self.module.typeOf(op.rhs) orelse return CompileError.InvalidValue);
                        if (lhs.kind != .floating or rhs.kind != .floating or dst.kind != .floating or
                            lhs_layout.columns != rhs_layout.rows or
                            lhs.components != try componentProduct(lhs_layout.rows, lhs_layout.columns) or
                            rhs.components != try componentProduct(rhs_layout.rows, rhs_layout.columns) or
                            dst.components != try componentProduct(lhs_layout.rows, rhs_layout.columns))
                            return CompileError.InvalidOperation;

                        try self.emit(opcode, dst.components, dst.base, lhs.base, rhs.base, .invalid_register, (bc.MatrixDimensions{
                            .rows = lhs_layout.rows,
                            .inner = lhs_layout.columns,
                            .columns = rhs_layout.columns,
                        }).encode());
                    },
                    .matrix_times_scalar => {
                        if (!dst.sameShape(lhs) or rhs.kind != .floating or rhs.components != 1)
                            return CompileError.InvalidOperation;
                        try self.emit(opcode, dst.components, dst.base, lhs.base, rhs.base, .invalid_register, 0);
                    },
                    .matrix_times_vector => {
                        const layout = try self.matrixLayout(self.module.typeOf(op.lhs) orelse return CompileError.InvalidValue);
                        if (lhs.kind != .floating or rhs.kind != .floating or dst.kind != .floating or
                            lhs.components != try componentProduct(layout.rows, layout.columns) or
                            rhs.components != layout.columns or dst.components != layout.rows)
                            return CompileError.InvalidOperation;

                        try self.emit(opcode, dst.components, dst.base, lhs.base, rhs.base, .invalid_register, (bc.MatrixDimensions{
                            .rows = layout.rows,
                            .inner = layout.columns,
                            .columns = 1,
                        }).encode());
                    },
                    .vector_times_matrix => {
                        const layout = try self.matrixLayout(self.module.typeOf(op.rhs) orelse return CompileError.InvalidValue);
                        if (lhs.kind != .floating or rhs.kind != .floating or dst.kind != .floating or
                            lhs.components != layout.rows or
                            rhs.components != try componentProduct(layout.rows, layout.columns) or
                            dst.components != layout.columns)
                            return CompileError.InvalidOperation;

                        try self.emit(opcode, dst.components, dst.base, lhs.base, rhs.base, .invalid_register, (bc.MatrixDimensions{
                            .rows = 1,
                            .inner = layout.rows,
                            .columns = layout.columns,
                        }).encode());
                    },
                    .vector_times_scalar => {
                        if (!dst.sameShape(lhs) or rhs.kind != .floating or rhs.components != 1)
                            return CompileError.InvalidOperation;
                        try self.emit(opcode, dst.components, dst.base, lhs.base, rhs.base, .invalid_register, 0);
                    },
                    else => {
                        if (!dst.sameShape(lhs) or !dst.sameShape(rhs))
                            return CompileError.InvalidOperation;
                        try self.emit(opcode, dst.components, dst.base, lhs.base, rhs.base, .invalid_register, 0);
                    },
                }
            },
            .ternary => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const first = try self.span(op.first);
                const second = try self.span(op.second);
                const third = try self.span(op.third);
                if (dst.kind != .floating or !dst.sameShape(first) or !dst.sameShape(second) or !dst.sameShape(third))
                    return CompileError.InvalidOperation;

                const opcode: bc.Opcode = switch (op.opcode) {
                    .smooth_step => .smooth_step,
                };
                try self.emit(opcode, dst.components, dst.base, first.base, second.base, third.base, 0);
            },
            .bit_field_extract => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const base = try self.span(op.base);
                const bit_offset = try self.span(op.offset);
                const count = try self.span(op.count);
                if (!dst.sameShape(base) or !isIntegerKind(dst.kind) or
                    !isScalarInteger(bit_offset) or !isScalarInteger(count))
                    return CompileError.InvalidOperation;

                const opcode: bc.Opcode = switch (op.opcode) {
                    .signed => .bit_field_extract_signed,
                    .unsigned => .bit_field_extract_unsigned,
                };
                try self.emit(opcode, dst.components, dst.base, base.base, bit_offset.base, count.base, 0);
            },
            .bit_field_insert => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const base = try self.span(op.base);
                const insert = try self.span(op.insert);
                const bit_offset = try self.span(op.offset);
                const count = try self.span(op.count);
                if (!dst.sameShape(base) or !dst.sameShape(insert) or !isIntegerKind(dst.kind) or
                    !isScalarInteger(bit_offset) or !isScalarInteger(count))
                    return CompileError.InvalidOperation;

                try self.emit(.bit_field_insert, dst.components, dst.base, base.base, insert.base, bit_offset.base, @backingInt(count.base));
            },
            .compare => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const lhs = try self.span(op.lhs);
                const rhs = try self.span(op.rhs);

                //if (dst.kind != .boolean or dst.components != 1 or lhs.components != 1 or !lhs.sameShape(rhs))
                //    return CompileError.UnsupportedOperation;

                try self.emit(try compareOpcode(op.opcode, lhs.kind), dst.components, dst.base, lhs.base, rhs.base, .invalid_register, 0);
            },
            .select => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const condition = try self.span(op.condition);
                const yes = try self.span(op.true_value);
                const no = try self.span(op.false_value);

                if (condition.kind != .boolean or
                    (condition.components != 1 and condition.components != dst.components) or
                    !dst.sameShape(yes) or !dst.sameShape(no))
                    return CompileError.InvalidOperation;

                const component_wise_condition = condition.components != 1;
                try self.emit(.select, dst.components, dst.base, condition.base, yes.base, no.base, @intFromBool(component_wise_condition));
            },
            .bitcast => |id| {
                const dst = result orelse return CompileError.InvalidOperation;
                const src = try self.span(id);

                if (dst.components != src.components)
                    return CompileError.UnsupportedOperation;

                try self.emitCopy(dst, src);
            },
            .convert => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const src = try self.span(op.operand);
                if (dst.components != src.components)
                    return CompileError.InvalidOperation;

                const opcode: bc.Opcode = switch (op.opcode) {
                    .float_to_signed => if (dst.kind == .signed_integer and src.kind == .floating) .float_to_signed else return CompileError.InvalidOperation,
                    .float_to_unsigned => if (dst.kind == .unsigned_integer and src.kind == .floating) .float_to_unsigned else return CompileError.InvalidOperation,
                    .signed_to_float => if (dst.kind == .floating and src.kind == .signed_integer) .signed_to_float else return CompileError.InvalidOperation,
                    .unsigned_to_float => if (dst.kind == .floating and src.kind == .unsigned_integer) .unsigned_to_float else return CompileError.InvalidOperation,
                };
                try self.emit(opcode, dst.components, dst.base, src.base, .invalid_register, .invalid_register, 0);
            },
            .composite_construct => |op| {
                const dst = result orelse return CompileError.InvalidOperation;

                var component: usize = 0;
                for (op.elements) |id| {
                    const src = try self.span(id);
                    if (src.kind != dst.kind or component + src.components > dst.components)
                        return CompileError.InvalidOperation;
                    try self.emit(.copy, src.components, try offset(dst.base, component), src.base, .invalid_register, .invalid_register, 0);
                    component += src.components;
                }
                if (component != dst.components) return CompileError.InvalidOperation;
            },
            .composite_extract => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const src = try self.span(op.composite);

                var type_id = self.module.typeOf(op.composite) orelse return CompileError.InvalidValue;
                var component: usize = 0;
                for (op.indices) |index| {
                    const ty = self.module.types.get(type_id) orelse return CompileError.UnsupportedType;
                    switch (ty.*) {
                        .vector => |vector| {
                            if (index >= vector.length) return CompileError.InvalidOperation;
                            const layout = try self.shape(vector.element_type);
                            component += @as(usize, index) * layout.components;
                            type_id = vector.element_type;
                        },
                        .matrix => |matrix| {
                            if (index >= matrix.column_count) return CompileError.InvalidOperation;
                            const layout = try self.shape(matrix.element_type);
                            component += @as(usize, index) * layout.components;
                            type_id = matrix.element_type;
                        },
                        .array => |array| {
                            if (index >= array.length) return CompileError.InvalidOperation;
                            const layout = try self.shape(array.element_type);
                            component += @as(usize, index) * layout.components;
                            type_id = array.element_type;
                        },
                        .structure => |structure| {
                            if (index >= structure.members.len) return CompileError.InvalidOperation;
                            for (structure.members[0..index]) |member_type|
                                component += (try self.shape(member_type)).components;
                            type_id = structure.members[index];
                        },
                        else => return CompileError.UnsupportedType,
                    }
                }
                const layout = try self.shape(type_id);
                if (!dst.sameShape(layout) or component + dst.components > src.components)
                    return CompileError.InvalidOperation;
                try self.emit(.copy, dst.components, dst.base, try offset(src.base, component), .invalid_register, .invalid_register, 0);
            },
            .load_interface => |op| {
                if (op.element_index != null)
                    return CompileError.UnsupportedOperation;

                const dst = result orelse return CompileError.InvalidOperation;
                const binding = self.interfaceFor(op.variable) orelse return CompileError.InvalidInterface;

                if (binding.direction != .input or !dst.sameShape(binding.span))
                    return CompileError.InvalidInterface;

                try self.emitCopy(dst, binding.span);
            },
            .store_interface => |op| {
                if (op.element_index != null)
                    return CompileError.UnsupportedOperation;

                const binding = self.interfaceFor(op.variable) orelse return CompileError.InvalidInterface;
                const src = try self.span(op.value);

                if (binding.direction != .output or !binding.span.sameShape(src))
                    return CompileError.InvalidInterface;

                try self.emitCopy(binding.span, src);
            },
            .load_buffer => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const byte_offset = try self.bufferOffset(op.byte_offset);
                const descriptor_index, const resource = try self.bufferAccess(op.resource, op.descriptor_index, false);
                try self.emit(.load_buffer, dst.components, dst.base, byte_offset, descriptor_index, .invalid_register, resource);
            },
            .load_push_constant => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const byte_offset = try self.bufferOffset(op.byte_offset);
                try self.emit(.load_push_constant, dst.components, dst.base, byte_offset, .invalid_register, .invalid_register, 0);
            },
            .store_buffer => |op| {
                if (result != null)
                    return CompileError.InvalidOperation;

                const src = try self.span(op.value);
                const byte_offset = try self.bufferOffset(op.byte_offset);
                const descriptor_index, const resource = try self.bufferAccess(op.resource, op.descriptor_index, true);
                try self.emit(.store_buffer, src.components, src.base, byte_offset, descriptor_index, .invalid_register, resource);
            },
            .load_workgroup => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const byte_offset = try self.bufferOffset(op.byte_offset);
                _ = try self.workgroupVariable(op.variable);
                try self.emit(.load_workgroup, dst.components, dst.base, byte_offset, .invalid_register, .invalid_register, @backingInt(op.variable));
            },
            .store_workgroup => |op| {
                if (result != null)
                    return CompileError.InvalidOperation;

                const src = try self.span(op.value);
                const byte_offset = try self.bufferOffset(op.byte_offset);
                _ = try self.workgroupVariable(op.variable);
                try self.emit(.store_workgroup, src.components, src.base, byte_offset, .invalid_register, .invalid_register, @backingInt(op.variable));
            },
            .image_read => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const coordinate = try self.span(op.coordinate);
                _ = try self.storageImage(op.resource);

                if ((dst.kind != .floating and dst.kind != .signed_integer and dst.kind != .unsigned_integer) or
                    dst.components != 4 or coordinate.kind != .signed_integer or coordinate.components != 2)
                    return CompileError.InvalidOperation;

                try self.emit(if (dst.kind == .floating) .image_read_float else .image_read, 4, dst.base, coordinate.base, .invalid_register, .invalid_register, @backingInt(op.resource));
            },
            .image_gather => |op| {
                try self.lowerImageGather(
                    result orelse return CompileError.InvalidOperation,
                    op.image,
                    op.sampler,
                    op.coordinate,
                    op.component,
                    op.dimension,
                    op.arrayed,
                );
            },
            .image_sample_explicit_lod => |op| {
                try self.lowerImageSample(
                    result orelse return CompileError.InvalidOperation,
                    op.image,
                    op.sampler,
                    op.coordinate,
                    op.lod,
                    op.dimension,
                    op.arrayed,
                    .image_sample_explicit_lod,
                );
            },
            .image_sample_implicit_lod => |op| {
                try self.lowerImageSample(
                    result orelse return CompileError.InvalidOperation,
                    op.image,
                    op.sampler,
                    op.coordinate,
                    null,
                    op.dimension,
                    op.arrayed,
                    .image_sample_implicit_lod,
                );
            },
            .image_write => |op| {
                if (result != null)
                    return CompileError.InvalidOperation;

                const coordinate = try self.span(op.coordinate);
                const value = try self.span(op.value);
                _ = try self.storageImage(op.resource);

                if ((value.kind != .floating and value.kind != .signed_integer and value.kind != .unsigned_integer) or
                    value.components != 4 or coordinate.kind != .signed_integer or coordinate.components != 2)
                    return CompileError.InvalidOperation;

                try self.emit(if (value.kind == .floating) .image_write_float else .image_write, 4, value.base, coordinate.base, .invalid_register, .invalid_register, @backingInt(op.resource));
            },
            .control_barrier => {
                if (result != null)
                    return CompileError.InvalidOperation;
                try self.emit(.control_barrier, 1, .invalid_register, .invalid_register, .invalid_register, .invalid_register, 0);
            },
            .call => return CompileError.UnsupportedOperation,
            .array_length => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const byte_offset = try self.bufferOffset(op.byte_offset);
                _ = try self.bufferResource(op.resource, true);
                if (op.descriptor_index != null)
                    return CompileError.UnsupportedOperation;

                if (dst.components != 1 or dst.kind != .unsigned_integer)
                    return CompileError.InvalidOperation;

                const metadata_index = try u32Index(self.array_lengths.items.len);
                try self.array_lengths.append(self.allocator, .{
                    .resource = @backingInt(op.resource),
                    .stride = op.stride,
                });

                try self.emit(.array_length, 1, dst.base, byte_offset, .invalid_register, .invalid_register, metadata_index);
            },
        }
    }

    fn lowerImageGather(
        self: *Lowerer,
        dst: bc.Span,
        image: ids.ResourceId,
        sampler_id: ids.ResourceId,
        coordinate_id: ids.ValueId,
        component_id: ids.ValueId,
        dimension: ImageDimension,
        arrayed: bool,
    ) !void {
        if (dimension != .two_d or arrayed)
            return CompileError.UnsupportedOperation;

        const coordinate = try self.span(coordinate_id);
        const component = try self.span(component_id);
        _ = try self.sampledImage(image);
        _ = try self.sampler(sampler_id);

        if ((dst.kind != .floating and dst.kind != .signed_integer and dst.kind != .unsigned_integer) or
            dst.components != 4 or coordinate.kind != .floating or coordinate.components != 2 or
            (component.kind != .signed_integer and component.kind != .unsigned_integer) or component.components != 1)
            return CompileError.InvalidOperation;

        const pair_index = try u32Index(self.image_sampler_pairs.items.len);
        try self.image_sampler_pairs.append(self.allocator, .{
            .image = image,
            .sampler = sampler_id,
            .dimension = dimension,
            .arrayed = arrayed,
            .destination_kind = dst.kind,
        });
        try self.emit(.image_gather, 4, dst.base, coordinate.base, component.base, .invalid_register, pair_index);
    }

    fn lowerImageSample(
        self: *Lowerer,
        dst: bc.Span,
        image: ids.ResourceId,
        sampler_id: ids.ResourceId,
        coordinate_id: ids.ValueId,
        lod_id: ?ids.ValueId,
        dimension: ImageDimension,
        arrayed: bool,
        opcode: bc.Opcode,
    ) !void {
        if (dimension == .cube and arrayed)
            return CompileError.UnsupportedOperation;

        const coordinate = try self.span(coordinate_id);
        _ = try self.sampledImage(image);
        _ = try self.sampler(sampler_id);

        if ((dst.kind != .floating and dst.kind != .signed_integer and dst.kind != .unsigned_integer) or
            dst.components != 4 or coordinate.kind != .floating or
            coordinate.components != imageCoordinateComponents(dimension, arrayed))
            return CompileError.InvalidOperation;

        const lod = if (lod_id) |id| try self.span(id) else null;
        if (lod) |lod_span| {
            if (lod_span.kind != .floating or lod_span.components != 1)
                return CompileError.InvalidOperation;
        }

        const pair_index = try u32Index(self.image_sampler_pairs.items.len);
        try self.image_sampler_pairs.append(self.allocator, .{
            .image = image,
            .sampler = sampler_id,
            .dimension = dimension,
            .arrayed = arrayed,
            .destination_kind = dst.kind,
        });
        try self.emit(opcode, 4, dst.base, coordinate.base, if (lod) |lod_span| lod_span.base else .invalid_register, .invalid_register, pair_index);
    }

    fn bufferOffset(self: *const Lowerer, id: ids.ValueId) !bc.Register {
        const byte_offset = try self.span(id);
        if (byte_offset.components != 1 or byte_offset.kind != .unsigned_integer)
            return CompileError.InvalidOperation;
        return byte_offset.base;
    }

    fn workgroupVariable(self: *const Lowerer, id: ids.WorkgroupVariableId) !WorkgroupBinding {
        if (id.index() >= self.workgroup_variables.len)
            return CompileError.InvalidOperation;
        return self.workgroup_variables[id.index()] orelse CompileError.InvalidOperation;
    }

    fn bufferResource(self: *const Lowerer, id: ids.ResourceId, writable: bool) !ResourceBinding {
        if (id.index() >= self.resources.len)
            return CompileError.InvalidOperation;

        const resource = self.resources[id.index()] orelse return CompileError.InvalidOperation;
        if (resource.kind != .storage_buffer and (writable or resource.kind != .uniform_buffer))
            return CompileError.InvalidOperation;

        return resource;
    }

    fn bufferAccess(self: *Lowerer, resource_id: ids.ResourceId, optional_descriptor_index: ?ids.ValueId, writable: bool) !struct { bc.Register, u32 } {
        const resource = try self.bufferResource(resource_id, writable);
        if (optional_descriptor_index) |descriptor_index_id| {
            const descriptor_index = try self.span(descriptor_index_id);
            if (descriptor_index.components != 1 or descriptor_index.kind != .unsigned_integer)
                return CompileError.InvalidOperation;

            return .{ descriptor_index.base, try self.addDescriptorArray(resource) };
        }

        return .{ .invalid_register, @backingInt(resource_id) };
    }

    fn addDescriptorArray(self: *Lowerer, base: ResourceBinding) !u32 {
        var candidate_count: usize = 0;
        for (self.resources) |optional_candidate| {
            const candidate = optional_candidate orelse continue;
            if (sameDescriptorArray(base, candidate))
                candidate_count += 1;
        }

        const candidates = try self.allocator.alloc(DescriptorCandidate, candidate_count);
        var next: usize = 0;
        for (self.resources, 0..) |optional_candidate, resource_index| {
            const candidate = optional_candidate orelse continue;
            if (!sameDescriptorArray(base, candidate))
                continue;

            candidates[next] = .{
                .array_element = candidate.array_element,
                .resource = ids.ResourceId.fromIndex(resource_index),
            };
            next += 1;
        }

        std.mem.sort(DescriptorCandidate, candidates, {}, descriptorCandidateLessThan);
        if (candidates.len > 1) {
            for (candidates[1..], candidates[0 .. candidates.len - 1]) |candidate, previous| {
                if (candidate.array_element == previous.array_element)
                    return CompileError.InvalidOperation;
            }
        }

        const metadata_index = try u32Index(self.descriptor_arrays.items.len);
        try self.descriptor_arrays.append(self.allocator, .{ .candidates = candidates });
        return metadata_index;
    }

    fn storageImage(self: *const Lowerer, id: ids.ResourceId) !ResourceBinding {
        if (id.index() >= self.resources.len)
            return CompileError.InvalidOperation;

        const resource = self.resources[id.index()] orelse return CompileError.InvalidOperation;
        if (resource.kind != .storage_image)
            return CompileError.InvalidOperation;

        return resource;
    }

    fn sampledImage(self: *const Lowerer, id: ids.ResourceId) !ResourceBinding {
        if (id.index() >= self.resources.len)
            return CompileError.InvalidOperation;

        const resource = self.resources[id.index()] orelse return CompileError.InvalidOperation;
        if (resource.kind != .sampled_image)
            return CompileError.InvalidOperation;

        return resource;
    }

    fn sampler(self: *const Lowerer, id: ids.ResourceId) !ResourceBinding {
        if (id.index() >= self.resources.len)
            return CompileError.InvalidOperation;

        const resource = self.resources[id.index()] orelse return CompileError.InvalidOperation;
        if (resource.kind != .sampler)
            return CompileError.InvalidOperation;

        return resource;
    }

    fn lowerTerminator(self: *Lowerer, terminator: module_ir.Terminator) !void {
        switch (terminator) {
            .branch => |edge| try self.emit(.jump_edge, 1, .invalid_register, .invalid_register, .invalid_register, .invalid_register, try self.addEdge(edge)),
            .conditional_branch => |branch| {
                const condition = try self.span(branch.condition);

                if (condition.kind != .boolean or condition.components != 1)
                    return CompileError.InvalidControlFlow;

                const index = try u32Index(self.branches.items.len);
                try self.branches.append(self.allocator, .{
                    .true_edge = try self.addEdge(branch.true_edge),
                    .false_edge = try self.addEdge(branch.false_edge),
                });

                try self.emit(.branch, 1, condition.base, .invalid_register, .invalid_register, .invalid_register, index);
            },
            .return_void => try self.emit(.return_void, 1, .invalid_register, .invalid_register, .invalid_register, .invalid_register, 0),
            .return_value => return CompileError.UnsupportedOperation,
            .discard => try self.emit(.discard, 1, .invalid_register, .invalid_register, .invalid_register, .invalid_register, 0),
            .@"unreachable" => try self.emit(.@"unreachable", 1, .invalid_register, .invalid_register, .invalid_register, .invalid_register, 0),
        }
    }

    fn addEdge(self: *Lowerer, edge: module_ir.Edge) !u32 {
        const target = self.module.blocks.get(edge.target) orelse return CompileError.InvalidControlFlow;

        if (target.parameters.items.len != edge.arguments.len)
            return CompileError.InvalidControlFlow;

        const first = try u32Index(self.copies.items.len);
        var scratch: usize = 0;
        for (edge.arguments, target.parameters.items) |source_id, destination_id| {
            const source = try self.span(source_id);
            const destination = try self.span(destination_id);

            if (!source.sameShape(destination))
                return CompileError.InvalidControlFlow;

            if (source.base == destination.base)
                continue;

            try self.copies.append(self.allocator, .{
                .destination = destination.base,
                .source = source.base,
                .components = source.components,
                .scratch_base = @fromBackingInt(@intCast(scratch)),
            });
            scratch += source.components;
        }

        if (scratch > @backingInt(bc.Register.invalid_register))
            return CompileError.TooManyRegisters;

        self.scratch_count = @max(self.scratch_count, scratch);
        const copy_count = self.copies.items.len - first;

        if (copy_count > std.math.maxInt(u16))
            return CompileError.TooManyInstructions;

        const index = try u32Index(self.edges.items.len);
        try self.edges.append(self.allocator, .{
            .target_block = @backingInt(edge.target),
            .first_copy = first,
            .copy_count = @intCast(copy_count),
        });
        return index;
    }

    fn emitCopy(self: *Lowerer, dst: bc.Span, src: bc.Span) !void {
        if (dst.components != src.components)
            return CompileError.InvalidOperation;
        try self.emit(.copy, dst.components, dst.base, src.base, .invalid_register, .invalid_register, 0);
    }

    fn emit(self: *Lowerer, opcode: bc.Opcode, components: u16, a: bc.Register, b: bc.Register, c: bc.Register, d: bc.Register, immediate: u32) !void {
        if (self.code.items.len >= std.math.maxInt(u32))
            return CompileError.TooManyInstructions;
        try self.code.append(self.allocator, .{ .opcode = opcode, .components = components, .a = a, .b = b, .c = c, .d = d, .immediate = immediate });
    }

    fn span(self: *const Lowerer, id: ids.ValueId) !bc.Span {
        if (id.index() >= self.values.len)
            return CompileError.InvalidValue;
        return self.values[id.index()] orelse CompileError.InvalidValue;
    }

    fn interfaceFor(self: *const Lowerer, id: ids.InterfaceVariableId) ?InterfaceBinding {
        if (id.index() >= self.interfaces.len)
            return null;
        return self.interfaces[id.index()];
    }
};

pub fn imageCoordinateComponents(dimension: ImageDimension, arrayed: bool) u8 {
    const dimension_components: u8 = switch (dimension) {
        .one_d => 1,
        .two_d => 2,
        .three_d, .cube => 3,
    };
    return dimension_components + @intFromBool(arrayed);
}

fn sameDescriptorArray(a: ResourceBinding, b: ResourceBinding) bool {
    return a.kind == b.kind and a.set == b.set and a.binding == b.binding;
}

fn descriptorCandidateLessThan(_: void, a: DescriptorCandidate, b: DescriptorCandidate) bool {
    return a.array_element < b.array_element;
}

fn typeByteSize(module: *const module_ir.Module, type_id: ids.TypeId) !usize {
    const ty = module.types.get(type_id) orelse return CompileError.UnsupportedType;
    return switch (ty.*) {
        .boolean => 4,
        .integer => |integer| if (integer.bits == 32) 4 else CompileError.UnsupportedType,
        .floating => |floating| if (floating.bits == 32) 4 else CompileError.UnsupportedType,
        .vector => |vector| std.math.mul(usize, try typeByteSize(module, vector.element_type), vector.length) catch return CompileError.TooMuchWorkgroupMemory,
        .matrix => |matrix| std.math.mul(usize, try typeByteSize(module, matrix.element_type), matrix.column_count) catch return CompileError.TooMuchWorkgroupMemory,
        .array => |array| std.math.mul(usize, try typeByteSize(module, array.element_type), array.length) catch return CompileError.TooMuchWorkgroupMemory,
        .structure => |structure| blk: {
            var size: usize = 0;
            for (structure.members) |member|
                size = std.math.add(usize, size, try typeByteSize(module, member)) catch return CompileError.TooMuchWorkgroupMemory;
            break :blk size;
        },
        else => CompileError.UnsupportedType,
    };
}

fn binaryOpcode(op: inst_ir.BinaryOpcode, kind: bc.ValueKind) !bc.Opcode {
    return switch (op) {
        .arithmetic_shift_right => if (kind == .signed_integer) .arithmetic_shift_right else CompileError.InvalidOperation,
        .bitwise_and => if (kind == .signed_integer or kind == .unsigned_integer) .bitwise_and else CompileError.InvalidOperation,
        .bitwise_or => if (kind == .signed_integer or kind == .unsigned_integer) .bitwise_or else CompileError.InvalidOperation,
        .bitwise_xor => if (kind == .signed_integer or kind == .unsigned_integer) .bitwise_xor else CompileError.InvalidOperation,
        .atan2 => if (kind == .floating) .atan2 else CompileError.InvalidOperation,
        .dot => if (kind == .floating) .dot else CompileError.InvalidOperation,
        .float_add => if (kind == .floating) .float_add else CompileError.InvalidOperation,
        .float_divide => if (kind == .floating) .float_divide else CompileError.InvalidOperation,
        .float_modulo => if (kind == .floating) .float_modulo else CompileError.InvalidOperation,
        .float_multiply => if (kind == .floating) .float_multiply else CompileError.InvalidOperation,
        .float_remainder => if (kind == .floating) .float_remainder else CompileError.InvalidOperation,
        .float_subtract => if (kind == .floating) .float_subtract else CompileError.InvalidOperation,
        .integer_add => if (kind == .signed_integer or kind == .unsigned_integer) .integer_add else CompileError.InvalidOperation,
        .integer_add_carry => if (kind == .unsigned_integer) .integer_add_carry else CompileError.InvalidOperation,
        .integer_multiply => if (kind == .signed_integer or kind == .unsigned_integer) .integer_multiply else CompileError.InvalidOperation,
        .integer_subtract => if (kind == .signed_integer or kind == .unsigned_integer) .integer_subtract else CompileError.InvalidOperation,
        .integer_subtract_borrow => if (kind == .unsigned_integer) .integer_subtract_borrow else CompileError.InvalidOperation,
        .logical_and => if (kind == .boolean) .logical_and else CompileError.InvalidOperation,
        .logical_or => if (kind == .boolean) .logical_or else CompileError.InvalidOperation,
        .logical_shift_right => if (kind == .signed_integer or kind == .unsigned_integer) .logical_shift_right else CompileError.InvalidOperation,
        .matrix_times_matrix => if (kind == .floating) .matrix_times_matrix else CompileError.InvalidOperation,
        .matrix_times_scalar => if (kind == .floating) .matrix_times_scalar else CompileError.InvalidOperation,
        .matrix_times_vector => if (kind == .floating) .matrix_times_vector else CompileError.InvalidOperation,
        .outer_product => if (kind == .floating) .outer_product else CompileError.InvalidOperation,
        .shift_left => if (kind == .signed_integer or kind == .unsigned_integer) .shift_left else CompileError.InvalidOperation,
        .signed_divide => if (kind == .signed_integer) .signed_divide else CompileError.InvalidOperation,
        .signed_modulo => if (kind == .signed_integer) .signed_modulo else CompileError.InvalidOperation,
        .signed_multiply_extended => if (kind == .signed_integer) .signed_multiply_extended else CompileError.InvalidOperation,
        .unsigned_divide => if (kind == .unsigned_integer) .unsigned_divide else CompileError.InvalidOperation,
        .unsigned_modulo => if (kind == .unsigned_integer) .unsigned_modulo else CompileError.InvalidOperation,
        .unsigned_multiply_extended => if (kind == .unsigned_integer) .unsigned_multiply_extended else CompileError.InvalidOperation,
        .vector_times_matrix => if (kind == .floating) .vector_times_matrix else CompileError.InvalidOperation,
        .vector_times_scalar => if (kind == .floating) .vector_times_scalar else CompileError.InvalidOperation,
    };
}

fn isExtendedBinaryOpcode(op: inst_ir.BinaryOpcode) bool {
    return switch (op) {
        .integer_add_carry,
        .integer_subtract_borrow,
        .signed_multiply_extended,
        .unsigned_multiply_extended,
        => true,
        else => false,
    };
}

fn isIntegerKind(kind: bc.ValueKind) bool {
    return kind == .signed_integer or kind == .unsigned_integer;
}

fn isScalarInteger(span_value: bc.Span) bool {
    return span_value.components == 1 and isIntegerKind(span_value.kind);
}

fn compareOpcode(op: inst_ir.CompareOpcode, kind: bc.ValueKind) !bc.Opcode {
    return switch (op) {
        .equal => if (kind == .signed_integer or kind == .unsigned_integer or kind == .boolean) .compare_equal else CompileError.InvalidOperation,
        .not_equal => if (kind == .signed_integer or kind == .unsigned_integer or kind == .boolean) .compare_not_equal else CompileError.InvalidOperation,
        .unsigned_less => if (kind == .unsigned_integer) .compare_unsigned_less else CompileError.InvalidOperation,
        .signed_less => if (kind == .signed_integer) .compare_signed_less else CompileError.InvalidOperation,
        .ordered_float_equal => if (kind == .floating) .compare_ordered_float_equal else CompileError.InvalidOperation,
        .unordered_float_equal => if (kind == .floating) .compare_unordered_float_equal else CompileError.InvalidOperation,
        .ordered_float_not_equal => if (kind == .floating) .compare_ordered_float_not_equal else CompileError.InvalidOperation,
        .unordered_float_not_equal => if (kind == .floating) .compare_unordered_float_not_equal else CompileError.InvalidOperation,
        .ordered_float_less => if (kind == .floating) .compare_ordered_float_less else CompileError.InvalidOperation,
        .ordered_float_less_equal => if (kind == .floating) .compare_ordered_float_less_equal else CompileError.InvalidOperation,
        .unordered_float_less => if (kind == .floating) .compare_unordered_float_less else CompileError.InvalidOperation,
    };
}

fn componentProduct(lhs: u8, rhs: u8) CompileError!u8 {
    return std.math.mul(u8, lhs, rhs) catch CompileError.UnsupportedType;
}

fn offset(base: bc.Register, component: usize) !bc.Register {
    const value = @as(usize, @backingInt(base)) + component;
    if (value > @backingInt(bc.Register.invalid_register))
        return CompileError.TooManyRegisters;
    return @fromBackingInt(@intCast(value));
}

fn u32Index(value: usize) !u32 {
    if (value > std.math.maxInt(u32))
        return CompileError.TooManyInstructions;
    return @intCast(value);
}
