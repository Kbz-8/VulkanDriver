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
    UnsupportedOperation,
    UnsupportedType,
};

pub const InterfaceBinding = struct {
    direction: module_ir.InterfaceDirection,
    semantic: module_ir.InterfaceSemantic,
    span: bc.Span,
};

pub const RegisterInit = struct {
    register: bc.Register,
    value: u32,
};

const Self = @This();

arena: std.heap.ArenaAllocator,
stage: module_ir.Stage,
entry_pc: u32,
register_count: usize,
scratch_count: usize,
code: []const bc.Instruction,
edges: []const bc.Edge,
copies: []const bc.Copy,
branches: []const bc.Branch,
initializers: []const RegisterInit,
interfaces: []const ?InterfaceBinding,

pub fn compile(backing_allocator: std.mem.Allocator, module: *const module_ir.Module) !Self {
    try ir.validator.validate(module);

    var result: Self = undefined;
    result.arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer result.arena.deinit();

    var lowerer = try Lowerer.init(result.arena.allocator(), module);
    try lowerer.lower();

    result.stage = module.stage;
    result.entry_pc = lowerer.entry_pc;
    result.register_count = lowerer.register_count;
    result.scratch_count = lowerer.scratch_count;
    result.code = lowerer.code.items;
    result.edges = lowerer.edges.items;
    result.copies = lowerer.copies.items;
    result.branches = lowerer.branches.items;
    result.initializers = lowerer.initializers.items;
    result.interfaces = lowerer.interfaces;
    return result;
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

const Lowerer = struct {
    allocator: std.mem.Allocator,
    module: *const module_ir.Module,
    function: *const module_ir.Function,
    entry_block: ids.BlockId,
    values: []?bc.Span,
    interfaces: []?InterfaceBinding,
    block_pcs: []?u32,
    register_count: usize = 0,
    scratch_count: usize = 0,
    entry_pc: u32 = 0,
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
        const block_pcs = try allocator.alloc(?u32, module.blocks.entries.items.len);
        @memset(block_pcs, null);

        return .{
            .allocator = allocator,
            .module = module,
            .function = function,
            .entry_block = entry_block,
            .values = values,
            .interfaces = interfaces,
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

    fn allocate(self: *Lowerer, type_id: ids.TypeId) !bc.Span {
        const ty = self.module.types.get(type_id) orelse return CompileError.UnsupportedType;
        var kind: bc.ValueKind = undefined;
        var components: u8 = 1;

        switch (ty.*) {
            .boolean => kind = .boolean,
            .integer => |integer| {
                if (integer.bits != 32)
                    return CompileError.UnsupportedType;

                kind = if (integer.signedness == .signed) .signed_integer else .unsigned_integer;
            },
            .floating => |floating| {
                if (floating.bits != 32)
                    return CompileError.UnsupportedType;

                kind = .floating;
            },
            .vector => |vector| {
                const element = self.module.types.get(vector.element_type) orelse return CompileError.UnsupportedType;
                components = vector.length;

                kind = switch (element.*) {
                    .boolean => .boolean,
                    .integer => |integer| blk: {
                        if (integer.bits != 32)
                            return CompileError.UnsupportedType;

                        break :blk if (integer.signedness == .signed) .signed_integer else .unsigned_integer;
                    },
                    .floating => |floating| if (floating.bits == 32) .floating else return CompileError.UnsupportedType,
                    else => return CompileError.UnsupportedType,
                };
            },
            else => return CompileError.UnsupportedType,
        }
        const end = std.math.add(usize, self.register_count, components) catch return CompileError.TooManyRegisters;

        if (end > @as(usize, std.math.maxInt(bc.Register)) + 1)
            return CompileError.TooManyRegisters;

        const allocated: bc.Span = .{ .base = @intCast(self.register_count), .components = components, .kind = kind };
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
                if (elements.len != destination.components)
                    return CompileError.InvalidConstant;

                for (elements, 0..) |element, component| {
                    try self.initializeConstant(.{
                        .base = try offset(destination.base, component),
                        .components = 1,
                        .kind = destination.kind,
                    }, element);
                }
            },
        }
    }

    fn lowerInstruction(self: *Lowerer, instruction: *const inst_ir.Instruction) !void {
        const result = if (instruction.result) |id| try self.span(id) else null;
        switch (instruction.operation) {
            .unary => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const src = try self.span(op.operand);

                if (!dst.sameShape(src))
                    return CompileError.InvalidOperation;

                const opcode: bc.Opcode = switch (op.opcode) {
                    .negate => switch (dst.kind) {
                        .signed_integer => .negate_i32,
                        .floating => .negate_f32,
                        else => return CompileError.InvalidOperation,
                    },
                    .logical_not => if (dst.kind == .boolean) .logical_not else return CompileError.InvalidOperation,
                    .bitwise_not => switch (dst.kind) {
                        .signed_integer, .unsigned_integer => .bitwise_not,
                        else => return CompileError.InvalidOperation,
                    },
                };
                try self.emit(opcode, dst.components, dst.base, src.base, bc.invalid_register, bc.invalid_register, 0);
            },
            .binary => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const lhs = try self.span(op.lhs);
                const rhs = try self.span(op.rhs);

                if (!dst.sameShape(lhs) or !dst.sameShape(rhs))
                    return CompileError.InvalidOperation;

                try self.emit(try binaryOpcode(op.opcode, dst.kind), dst.components, dst.base, lhs.base, rhs.base, bc.invalid_register, 0);
            },
            .compare => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const lhs = try self.span(op.lhs);
                const rhs = try self.span(op.rhs);

                if (dst.kind != .boolean or dst.components != 1 or lhs.components != 1 or !lhs.sameShape(rhs))
                    return CompileError.UnsupportedOperation;

                try self.emit(try compareOpcode(op.opcode, lhs.kind), 1, dst.base, lhs.base, rhs.base, bc.invalid_register, 0);
            },
            .select => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const condition = try self.span(op.condition);
                const yes = try self.span(op.true_value);
                const no = try self.span(op.false_value);

                if (condition.kind != .boolean or condition.components != 1 or !dst.sameShape(yes) or !dst.sameShape(no))
                    return CompileError.InvalidOperation;

                try self.emit(.select, dst.components, dst.base, condition.base, yes.base, no.base, 0);
            },
            .bitcast => |id| {
                const dst = result orelse return CompileError.InvalidOperation;
                const src = try self.span(id);

                if (dst.components != src.components)
                    return CompileError.UnsupportedOperation;

                try self.emitCopy(dst, src);
            },
            .composite_construct => |op| {
                const dst = result orelse return CompileError.InvalidOperation;

                if (dst.components != op.elements.len)
                    return CompileError.UnsupportedOperation;

                for (op.elements, 0..) |id, component| {
                    const src = try self.span(id);

                    if (src.components != 1)
                        return CompileError.UnsupportedOperation;

                    try self.emit(.copy, 1, try offset(dst.base, component), src.base, bc.invalid_register, bc.invalid_register, 0);
                }
            },
            .composite_extract => |op| {
                const dst = result orelse return CompileError.InvalidOperation;
                const src = try self.span(op.composite);

                if (dst.components != 1 or op.indices.len != 1 or op.indices[0] >= src.components)
                    return CompileError.UnsupportedOperation;

                try self.emit(.copy, 1, dst.base, try offset(src.base, op.indices[0]), bc.invalid_register, bc.invalid_register, 0);
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
            .call => return CompileError.UnsupportedOperation,
        }
    }

    fn lowerTerminator(self: *Lowerer, terminator: module_ir.Terminator) !void {
        switch (terminator) {
            .branch => |edge| try self.emit(.jump_edge, 1, bc.invalid_register, bc.invalid_register, bc.invalid_register, bc.invalid_register, try self.addEdge(edge)),
            .conditional_branch => |branch| {
                const condition = try self.span(branch.condition);
                if (condition.kind != .boolean or condition.components != 1) return CompileError.InvalidControlFlow;
                const index = try u32Index(self.branches.items.len);
                try self.branches.append(self.allocator, .{
                    .true_edge = try self.addEdge(branch.true_edge),
                    .false_edge = try self.addEdge(branch.false_edge),
                });
                try self.emit(.branch, 1, condition.base, bc.invalid_register, bc.invalid_register, bc.invalid_register, index);
            },
            .return_void => try self.emit(.return_void, 1, bc.invalid_register, bc.invalid_register, bc.invalid_register, bc.invalid_register, 0),
            .return_value => return CompileError.UnsupportedOperation,
            .discard => try self.emit(.discard, 1, bc.invalid_register, bc.invalid_register, bc.invalid_register, bc.invalid_register, 0),
            .@"unreachable" => try self.emit(.@"unreachable", 1, bc.invalid_register, bc.invalid_register, bc.invalid_register, bc.invalid_register, 0),
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
            if (!source.sameShape(destination)) return CompileError.InvalidControlFlow;
            if (source.base == destination.base) continue;
            try self.copies.append(self.allocator, .{
                .destination = destination.base,
                .source = source.base,
                .components = source.components,
                .scratch_base = @intCast(scratch),
            });
            scratch += source.components;
        }

        if (scratch > std.math.maxInt(bc.Register))
            return CompileError.TooManyRegisters;

        self.scratch_count = @max(self.scratch_count, scratch);
        const copy_count = self.copies.items.len - first;

        if (copy_count > std.math.maxInt(u16))
            return CompileError.TooManyInstructions;

        const index = try u32Index(self.edges.items.len);
        try self.edges.append(self.allocator, .{
            .target_block = @intFromEnum(edge.target),
            .first_copy = first,
            .copy_count = @intCast(copy_count),
        });
        return index;
    }

    fn emitCopy(self: *Lowerer, dst: bc.Span, src: bc.Span) !void {
        if (dst.components != src.components)
            return CompileError.InvalidOperation;
        try self.emit(.copy, dst.components, dst.base, src.base, bc.invalid_register, bc.invalid_register, 0);
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

fn binaryOpcode(op: inst_ir.BinaryOpcode, kind: bc.ValueKind) !bc.Opcode {
    return switch (op) {
        .integer_add => if (kind == .signed_integer or kind == .unsigned_integer) .integer_add else CompileError.InvalidOperation,
        .integer_subtract => if (kind == .signed_integer or kind == .unsigned_integer) .integer_subtract else CompileError.InvalidOperation,
        .integer_multiply => if (kind == .signed_integer or kind == .unsigned_integer) .integer_multiply else CompileError.InvalidOperation,
        .unsigned_divide => if (kind == .unsigned_integer) .unsigned_divide else CompileError.InvalidOperation,
        .signed_divide => if (kind == .signed_integer) .signed_divide else CompileError.InvalidOperation,
        .unsigned_modulo => if (kind == .unsigned_integer) .unsigned_modulo else CompileError.InvalidOperation,
        .signed_modulo => if (kind == .signed_integer) .signed_modulo else CompileError.InvalidOperation,
        .float_add => if (kind == .floating) .float_add else CompileError.InvalidOperation,
        .float_subtract => if (kind == .floating) .float_subtract else CompileError.InvalidOperation,
        .float_multiply => if (kind == .floating) .float_multiply else CompileError.InvalidOperation,
        .float_divide => if (kind == .floating) .float_divide else CompileError.InvalidOperation,
        .float_modulo => if (kind == .floating) .float_modulo else CompileError.InvalidOperation,
        .shift_left => if (kind == .signed_integer or kind == .unsigned_integer) .shift_left else CompileError.InvalidOperation,
        .logical_shift_right => if (kind == .signed_integer or kind == .unsigned_integer) .logical_shift_right else CompileError.InvalidOperation,
        .arithmetic_shift_right => if (kind == .signed_integer) .arithmetic_shift_right else CompileError.InvalidOperation,
        .bitwise_and => if (kind == .signed_integer or kind == .unsigned_integer) .bitwise_and else CompileError.InvalidOperation,
        .bitwise_or => if (kind == .signed_integer or kind == .unsigned_integer) .bitwise_or else CompileError.InvalidOperation,
        .bitwise_xor => if (kind == .signed_integer or kind == .unsigned_integer) .bitwise_xor else CompileError.InvalidOperation,
        .logical_and => if (kind == .boolean) .logical_and else CompileError.InvalidOperation,
        .logical_or => if (kind == .boolean) .logical_or else CompileError.InvalidOperation,
    };
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
        .unordered_float_less => if (kind == .floating) .compare_unordered_float_less else CompileError.InvalidOperation,
    };
}

fn offset(base: bc.Register, component: usize) !bc.Register {
    const value = @as(usize, base) + component;
    if (value > std.math.maxInt(bc.Register))
        return CompileError.TooManyRegisters;
    return @intCast(value);
}

fn u32Index(value: usize) !u32 {
    if (value > std.math.maxInt(u32))
        return CompileError.TooManyInstructions;
    return @intCast(value);
}
