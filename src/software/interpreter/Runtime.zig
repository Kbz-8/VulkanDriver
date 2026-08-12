const std = @import("std");
const shader_ir = @import("shader_ir");
const bc = @import("bytecode.zig");
const Program = @import("Program.zig");

const ids = shader_ir.ir.id;

pub const RuntimeError = error{
    BufferOutOfBounds,
    DivisionByZero,
    IntegerOverflow,
    InvalidBytecode,
    InvalidInterface,
    InvalidResource,
    ResourceNotBound,
    ShiftOutOfRange,
    StepLimitExceeded,
    UnreachableExecuted,
    WrongInterfaceDirection,
    WrongInterfaceType,
};

pub const Outcome = enum {
    returned,
    discarded,
};

pub const RunOptions = struct {
    max_steps: usize = 1_000_000,
    resource_buffers: []const ?[]u8 = &.{},
};

const Self = @This();

allocator: std.mem.Allocator,
registers: []u32,
scratch: []u32,

pub fn init(allocator: std.mem.Allocator, program: *const Program) !Self {
    const registers = try allocator.alloc(u32, program.register_count);
    errdefer allocator.free(registers);
    const scratch = try allocator.alloc(u32, program.scratch_count);
    errdefer allocator.free(scratch);
    @memset(registers, 0);
    @memset(scratch, 0);
    for (program.initializers) |initializer|
        registers[initializer.register] = initializer.value;
    return .{ .allocator = allocator, .registers = registers, .scratch = scratch };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.registers);
    self.allocator.free(self.scratch);
    self.* = undefined;
}

pub fn writeInput(self: *Self, program: *const Program, variable: ids.InterfaceVariableId, values: []const u32) RuntimeError!void {
    const binding = program.interfaceBinding(variable) orelse return RuntimeError.InvalidInterface;

    if (binding.direction != .input)
        return RuntimeError.WrongInterfaceDirection;

    if (binding.span.components != values.len)
        return RuntimeError.WrongInterfaceType;

    @memcpy(self.registers[binding.span.base..][0..values.len], values);
}

pub fn readOutput(self: *const Self, program: *const Program, variable: ids.InterfaceVariableId, values: []u32) RuntimeError!void {
    const binding = program.interfaceBinding(variable) orelse return RuntimeError.InvalidInterface;

    if (binding.direction != .output)
        return RuntimeError.WrongInterfaceDirection;

    if (binding.span.components != values.len)
        return RuntimeError.WrongInterfaceType;

    @memcpy(values, self.registers[binding.span.base..][0..values.len]);
}

pub fn run(self: *Self, program: *const Program, options: RunOptions) RuntimeError!Outcome {
    var pc = program.entry_pc;
    var steps: usize = 0;
    while (true) {
        if (steps >= options.max_steps)
            return RuntimeError.StepLimitExceeded;

        steps += 1;

        if (pc >= program.code.len)
            return RuntimeError.InvalidBytecode;

        const instruction = program.code[pc];
        pc += 1;

        switch (instruction.opcode) {
            .copy => self.copy(instruction),
            .negate_i32 => self.unaryInt(instruction, .negate),
            .negate_f32 => self.unaryFloat(instruction),
            .logical_not => self.unaryInt(instruction, .logical_not),
            .bitwise_not => self.unaryInt(instruction, .bitwise_not),
            .integer_add => try self.binaryInt(instruction, .add),
            .integer_subtract => try self.binaryInt(instruction, .subtract),
            .integer_multiply => try self.binaryInt(instruction, .multiply),
            .unsigned_divide => try self.binaryInt(instruction, .unsigned_divide),
            .signed_divide => try self.binaryInt(instruction, .signed_divide),
            .unsigned_modulo => try self.binaryInt(instruction, .unsigned_modulo),
            .signed_modulo => try self.binaryInt(instruction, .signed_modulo),
            .shift_left => try self.binaryInt(instruction, .shift_left),
            .logical_shift_right => try self.binaryInt(instruction, .logical_shift_right),
            .arithmetic_shift_right => try self.binaryInt(instruction, .arithmetic_shift_right),
            .bitwise_and => try self.binaryInt(instruction, .bitwise_and),
            .bitwise_or => try self.binaryInt(instruction, .bitwise_or),
            .bitwise_xor => try self.binaryInt(instruction, .bitwise_xor),
            .logical_and => try self.binaryInt(instruction, .logical_and),
            .logical_or => try self.binaryInt(instruction, .logical_or),
            .float_add => self.binaryFloat(instruction, .add),
            .float_subtract => self.binaryFloat(instruction, .subtract),
            .float_multiply => self.binaryFloat(instruction, .multiply),
            .float_divide => self.binaryFloat(instruction, .divide),
            .float_modulo => self.binaryFloat(instruction, .modulo),
            .compare_equal => self.compareInt(instruction, .equal),
            .compare_not_equal => self.compareInt(instruction, .not_equal),
            .compare_unsigned_less => self.compareInt(instruction, .unsigned_less),
            .compare_signed_less => self.compareInt(instruction, .signed_less),
            .compare_ordered_float_equal => self.compareFloat(instruction, .ordered_equal),
            .compare_unordered_float_equal => self.compareFloat(instruction, .unordered_equal),
            .compare_ordered_float_not_equal => self.compareFloat(instruction, .ordered_not_equal),
            .compare_unordered_float_not_equal => self.compareFloat(instruction, .unordered_not_equal),
            .compare_ordered_float_less => self.compareFloat(instruction, .ordered_less),
            .compare_unordered_float_less => self.compareFloat(instruction, .unordered_less),
            .select => self.select(instruction),
            .load_buffer => try self.loadBuffer(program, options.resource_buffers, instruction),
            .store_buffer => try self.storeBuffer(program, options.resource_buffers, instruction),
            .jump_edge => pc = try self.applyEdge(program, instruction.immediate),
            .branch => {
                if (instruction.immediate >= program.branches.len)
                    return RuntimeError.InvalidBytecode;

                const branch = program.branches[instruction.immediate];
                pc = try self.applyEdge(program, if (self.registers[instruction.a] != 0) branch.true_edge else branch.false_edge);
            },
            .return_void => return .returned,
            .discard => return .discarded,
            .@"unreachable" => return RuntimeError.UnreachableExecuted,
        }
    }
}

const UnaryInt = enum { negate, logical_not, bitwise_not };
const BinaryInt = enum {
    add,
    subtract,
    multiply,
    unsigned_divide,
    signed_divide,
    unsigned_modulo,
    signed_modulo,
    shift_left,
    logical_shift_right,
    arithmetic_shift_right,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    logical_and,
    logical_or,
};
const BinaryFloat = enum { add, subtract, multiply, divide, modulo };
const CompareInt = enum { equal, not_equal, unsigned_less, signed_less };
const CompareFloat = enum { ordered_equal, unordered_equal, ordered_not_equal, unordered_not_equal, ordered_less, unordered_less };

fn copy(self: *Self, instruction: bc.Instruction) void {
    for (0..instruction.components) |component|
        self.registers[@as(usize, instruction.a) + component] = self.registers[@as(usize, instruction.b) + component];
}

fn unaryInt(self: *Self, instruction: bc.Instruction, comptime operation: UnaryInt) void {
    for (0..instruction.components) |component| {
        const value = self.registers[@as(usize, instruction.b) + component];
        self.registers[@as(usize, instruction.a) + component] = switch (operation) {
            .negate => 0 -% value,
            .logical_not => @intFromBool(value == 0),
            .bitwise_not => ~value,
        };
    }
}

fn unaryFloat(self: *Self, instruction: bc.Instruction) void {
    for (0..instruction.components) |component| {
        const value: f32 = @bitCast(self.registers[@as(usize, instruction.b) + component]);
        self.registers[@as(usize, instruction.a) + component] = @bitCast(-value);
    }
}

fn binaryInt(self: *Self, instruction: bc.Instruction, comptime operation: BinaryInt) RuntimeError!void {
    for (0..instruction.components) |component| {
        const lhs = self.registers[@as(usize, instruction.b) + component];
        const rhs = self.registers[@as(usize, instruction.c) + component];
        self.registers[@as(usize, instruction.a) + component] = switch (operation) {
            .add => lhs +% rhs,
            .subtract => lhs -% rhs,
            .multiply => lhs *% rhs,
            .unsigned_divide => if (rhs == 0) return RuntimeError.DivisionByZero else lhs / rhs,
            .unsigned_modulo => if (rhs == 0) return RuntimeError.DivisionByZero else lhs % rhs,
            .signed_divide => blk: {
                const signed_lhs: i32 = @bitCast(lhs);
                const signed_rhs: i32 = @bitCast(rhs);

                if (signed_rhs == 0)
                    return RuntimeError.DivisionByZero;

                if (signed_lhs == std.math.minInt(i32) and signed_rhs == -1)
                    return RuntimeError.IntegerOverflow;

                break :blk @bitCast(@divTrunc(signed_lhs, signed_rhs));
            },
            .signed_modulo => blk: {
                const signed_lhs: i32 = @bitCast(lhs);
                const signed_rhs: i32 = @bitCast(rhs);

                if (signed_rhs == 0)
                    return RuntimeError.DivisionByZero;

                if (signed_lhs == std.math.minInt(i32) and signed_rhs == -1)
                    break :blk 0;

                break :blk @bitCast(@mod(signed_lhs, signed_rhs));
            },
            .shift_left => if (rhs >= 32) return RuntimeError.ShiftOutOfRange else lhs << @intCast(rhs),
            .logical_shift_right => if (rhs >= 32) return RuntimeError.ShiftOutOfRange else lhs >> @intCast(rhs),
            .arithmetic_shift_right => if (rhs >= 32) return RuntimeError.ShiftOutOfRange else @bitCast(@as(i32, @bitCast(lhs)) >> @intCast(rhs)),
            .bitwise_and => lhs & rhs,
            .bitwise_or => lhs | rhs,
            .bitwise_xor => lhs ^ rhs,
            .logical_and => @intFromBool(lhs != 0 and rhs != 0),
            .logical_or => @intFromBool(lhs != 0 or rhs != 0),
        };
    }
}

fn binaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: BinaryFloat) void {
    for (0..instruction.components) |component| {
        const lhs: f32 = @bitCast(self.registers[@as(usize, instruction.b) + component]);
        const rhs: f32 = @bitCast(self.registers[@as(usize, instruction.c) + component]);
        const result = switch (operation) {
            .add => lhs + rhs,
            .subtract => lhs - rhs,
            .multiply => lhs * rhs,
            .divide => lhs / rhs,
            .modulo => lhs - rhs * @floor(lhs / rhs),
        };
        self.registers[@as(usize, instruction.a) + component] = @bitCast(result);
    }
}

fn compareInt(self: *Self, instruction: bc.Instruction, comptime operation: CompareInt) void {
    const lhs = self.registers[instruction.b];
    const rhs = self.registers[instruction.c];
    self.registers[instruction.a] = @intFromBool(switch (operation) {
        .equal => lhs == rhs,
        .not_equal => lhs != rhs,
        .unsigned_less => lhs < rhs,
        .signed_less => @as(i32, @bitCast(lhs)) < @as(i32, @bitCast(rhs)),
    });
}

fn compareFloat(self: *Self, instruction: bc.Instruction, comptime operation: CompareFloat) void {
    const lhs: f32 = @bitCast(self.registers[instruction.b]);
    const rhs: f32 = @bitCast(self.registers[instruction.c]);
    const unordered = std.math.isNan(lhs) or std.math.isNan(rhs);
    self.registers[instruction.a] = @intFromBool(switch (operation) {
        .ordered_equal => !unordered and lhs == rhs,
        .unordered_equal => unordered or lhs == rhs,
        .ordered_not_equal => !unordered and lhs != rhs,
        .unordered_not_equal => unordered or lhs != rhs,
        .ordered_less => !unordered and lhs < rhs,
        .unordered_less => unordered or lhs < rhs,
    });
}

fn select(self: *Self, instruction: bc.Instruction) void {
    const selected = if (self.registers[instruction.b] != 0) instruction.c else instruction.d;
    for (0..instruction.components) |component|
        self.registers[@as(usize, instruction.a) + component] = self.registers[@as(usize, selected) + component];
}

fn loadBuffer(self: *Self, program: *const Program, resource_buffers: []const ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const buffer = try resourceBuffer(program, resource_buffers, instruction.immediate);
    const bytes = try self.bufferRange(buffer, instruction);
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(u32);
        self.registers[@as(usize, instruction.a) + component] = std.mem.readInt(u32, bytes[offset..][0..@sizeOf(u32)], .little);
    }
}

fn storeBuffer(self: *const Self, program: *const Program, resource_buffers: []const ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const buffer = try resourceBuffer(program, resource_buffers, instruction.immediate);
    const bytes = try self.bufferRange(buffer, instruction);
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(u32);
        std.mem.writeInt(u32, bytes[offset..][0..@sizeOf(u32)], self.registers[@as(usize, instruction.a) + component], .little);
    }
}

fn validateRegisterSpan(self: *const Self, instruction: bc.Instruction) RuntimeError!void {
    const register_end = std.math.add(usize, instruction.a, instruction.components) catch return RuntimeError.InvalidBytecode;
    if (register_end > self.registers.len)
        return RuntimeError.InvalidBytecode;
}

fn bufferRange(self: *const Self, buffer: []u8, instruction: bc.Instruction) RuntimeError![]u8 {
    if (instruction.b >= self.registers.len)
        return RuntimeError.InvalidBytecode;

    const byte_offset: usize = self.registers[instruction.b];
    const byte_count = std.math.mul(usize, instruction.components, @sizeOf(u32)) catch return RuntimeError.BufferOutOfBounds;
    const end = std.math.add(usize, byte_offset, byte_count) catch return RuntimeError.BufferOutOfBounds;
    if (end > buffer.len)
        return RuntimeError.BufferOutOfBounds;
    return buffer[byte_offset..end];
}

fn resourceBuffer(program: *const Program, resource_buffers: []const ?[]u8, resource_index: u32) RuntimeError![]u8 {
    const resource = ids.ResourceId.fromIndex(resource_index);
    _ = program.resourceBinding(resource) orelse return RuntimeError.InvalidResource;
    if (resource.index() >= resource_buffers.len)
        return RuntimeError.ResourceNotBound;
    return resource_buffers[resource.index()] orelse RuntimeError.ResourceNotBound;
}

fn applyEdge(self: *Self, program: *const Program, edge_index: u32) RuntimeError!u32 {
    if (edge_index >= program.edges.len)
        return RuntimeError.InvalidBytecode;

    const edge = program.edges[edge_index];
    const end = @as(usize, edge.first_copy) + edge.copy_count;

    if (end > program.copies.len)
        return RuntimeError.InvalidBytecode;

    const copies = program.copies[edge.first_copy..end];
    for (copies) |item| {
        for (0..item.components) |component| {
            self.scratch[@as(usize, item.scratch_base) + component] = self.registers[@as(usize, item.source) + component];
        }
    }
    for (copies) |item| {
        for (0..item.components) |component| {
            self.registers[@as(usize, item.destination) + component] = self.scratch[@as(usize, item.scratch_base) + component];
        }
    }

    if (edge.target_pc >= program.code.len)
        return RuntimeError.InvalidBytecode;

    return edge.target_pc;
}
