const std = @import("std");
const vk = @import("vulkan");
const spv = @import("spv");
const shader_ir = @import("shader_ir");
const bc = @import("bytecode.zig");
const Program = @import("Program.zig");
const simd = @import("simd.zig");
const SoftImage = @import("../SoftImage.zig");
const SoftImageView = @import("../SoftImageView.zig");
const SoftSampler = @import("../SoftSampler.zig");

const ids = shader_ir.ir.id;

pub const RuntimeError = error{
    BarrierDivergence,
    DerivativeUnavailable,
    BufferOutOfBounds,
    DivisionByZero,
    IntegerOverflow,
    InvalidBytecode,
    InvalidInterface,
    InvalidLane,
    InvalidResource,
    InvalidResume,
    ResourceNotBound,
    ShiftOutOfRange,
    StepLimitExceeded,
    UnreachableExecuted,
    WrongInterfaceDirection,
    WrongInterfaceType,
    WorkgroupMemoryUnavailable,
};

const UnaryInt = enum {
    negate,
    logical_not,
    bitwise_not,
    bit_count,
    bit_reverse,
};

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

const ExtendedInt = enum {
    add_carry,
    subtract_borrow,
    signed_multiply,
    unsigned_multiply,
};

const FloatClassification = enum {
    infinite,
    nan,
};

const UnaryFloat = enum {
    absolute,
    ceil,
    exp,
    floor,
    negate,
    round,
    sign,
};

const BinaryFloat = enum {
    add,
    subtract,
    multiply,
    divide,
    max,
    min,
    modulo,
    remainder,
    atan2,
    pow,
};

const CompareInt = enum {
    equal,
    not_equal,
    unsigned_less,
    signed_less,
};

const CompareFloat = enum {
    ordered_equal,
    unordered_equal,
    ordered_not_equal,
    unordered_not_equal,
    ordered_less,
    ordered_less_equal,
    unordered_less,
};

pub const lane_count = simd.lane_count;
pub const Lane = simd.Lane;
pub const LaneMask = simd.LaneMask;
pub const full_lane_mask = simd.full_lane_mask;

pub const WaveResult = struct {
    returned_mask: LaneMask,
    discarded_mask: LaneMask,
    barrier_mask: LaneMask,
};

pub const Outcome = enum {
    returned,
    discarded,
    barrier,
};

const LaneOutcome = enum { returned, discarded, barrier };

pub const RunOptions = struct {
    max_steps: usize = 1_000_000,
    push_constants: []const u8 = &.{},
    resource_buffers: []const ?[]u8 = &.{},
    resource_images: []const ?*SoftImageView = &.{},
    resource_samplers: []const ?*SoftSampler = &.{},
    workgroup_memory: ?[]u8 = null,
};

const Self = @This();

allocator: std.mem.Allocator,
register_backing: []u32,
scratch_backing: []u32,
register_count: usize,
scratch_count: usize,
registers: []u32,
scratch: []u32,
pcs: [lane_count]usize = @splat(0),
execution_mask: LaneMask = 0,
observable_mask: LaneMask = 0,
active_mask: LaneMask = 0,
returned_mask: LaneMask = 0,
discarded_mask: LaneMask = 0,
barrier_mask: LaneMask = 0,
current_lane: Lane = 0,
steps: usize = 0,
lane_steps: usize = 0,
fast_path_lane_steps: usize = 0,
state: enum { ready, running, barrier, completed } = .ready,

pub fn init(allocator: std.mem.Allocator, program: *const Program) !Self {
    const register_words = try std.math.mul(usize, program.register_count, lane_count);
    const scratch_words = try std.math.mul(usize, program.scratch_count, lane_count);
    const register_backing = try allocator.alloc(u32, register_words);
    errdefer allocator.free(register_backing);
    const scratch_backing = try allocator.alloc(u32, scratch_words);
    errdefer allocator.free(scratch_backing);

    @memset(register_backing, 0);
    @memset(scratch_backing, 0);

    for (0..lane_count) |lane| {
        const lane_registers = register_backing[lane * program.register_count ..][0..program.register_count];
        for (program.initializers) |initializer|
            lane_registers[@backingInt(initializer.register)] = initializer.value;
    }

    var self: Self = .{
        .allocator = allocator,
        .register_backing = register_backing,
        .scratch_backing = scratch_backing,
        .register_count = program.register_count,
        .scratch_count = program.scratch_count,
        .registers = register_backing[0..program.register_count],
        .scratch = scratch_backing[0..program.scratch_count],
    };
    self.resetWave(program, full_lane_mask, full_lane_mask);
    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.register_backing);
    self.allocator.free(self.scratch_backing);
    self.* = undefined;
}

pub fn resetWave(self: *Self, program: *const Program, execution_mask: LaneMask, observable_mask: LaneMask) void {
    std.debug.assert(program.register_count == self.register_count);
    std.debug.assert(program.scratch_count == self.scratch_count);
    for (0..lane_count) |lane| {
        const lane_registers = self.laneRegisters(@intCast(lane));
        for (program.interfaces) |optional_binding| {
            const binding = optional_binding orelse continue;
            const start: usize = @backingInt(binding.span.base);
            @memset(lane_registers[start..][0..binding.span.components], 0);
        }
        self.pcs[lane] = program.entry_pc;
    }
    self.execution_mask = execution_mask;
    self.observable_mask = observable_mask & execution_mask;
    self.active_mask = execution_mask;
    self.returned_mask = 0;
    self.discarded_mask = 0;
    self.barrier_mask = 0;
    self.steps = 0;
    self.lane_steps = 0;
    self.fast_path_lane_steps = 0;
    self.state = .ready;
    self.selectLane(0);
}

pub fn resetInvocation(self: *Self, program: *const Program) void {
    self.resetWave(program, 0b0001, 0b0001);
}

pub fn writeInput(self: *Self, program: *const Program, variable: ids.InterfaceVariableId, values: []const u32) RuntimeError!void {
    return self.writeInputLane(program, 0, variable, values);
}

pub fn readOutput(self: *const Self, program: *const Program, variable: ids.InterfaceVariableId, values: []u32) RuntimeError!void {
    return self.readOutputLane(program, 0, variable, values);
}

pub fn run(self: *Self, program: *const Program, options: RunOptions) RuntimeError!Outcome {
    self.pcs[0] = program.entry_pc;
    self.execution_mask = 0b0001;
    self.observable_mask = 0b0001;
    self.active_mask = 0b0001;
    self.returned_mask = 0;
    self.discarded_mask = 0;
    self.barrier_mask = 0;
    self.steps = 0;
    self.lane_steps = 0;
    self.fast_path_lane_steps = 0;
    self.state = .ready;
    self.selectLane(0);
    return scalarOutcome(try self.runWave(program, options));
}

pub fn continueExecution(self: *Self, program: *const Program, options: RunOptions) RuntimeError!Outcome {
    return scalarOutcome(try self.runWave(program, options));
}

fn scalarOutcome(result: WaveResult) RuntimeError!Outcome {
    if (result.returned_mask == 0b0001)
        return .returned;
    if (result.discarded_mask == 0b0001)
        return .discarded;
    if (result.barrier_mask == 0b0001)
        return .barrier;
    return RuntimeError.InvalidBytecode;
}

pub fn writeInputLane(self: *Self, program: *const Program, lane: usize, variable: ids.InterfaceVariableId, values: []const u32) RuntimeError!void {
    if (lane >= lane_count)
        return RuntimeError.InvalidLane;
    const binding = program.interfaceBinding(variable) orelse return RuntimeError.InvalidInterface;
    if (binding.direction != .input)
        return RuntimeError.WrongInterfaceDirection;
    if (binding.span.components != values.len)
        return RuntimeError.WrongInterfaceType;

    const lane_registers = self.laneRegisters(@intCast(lane));
    @memcpy(lane_registers[@backingInt(binding.span.base)..][0..values.len], values);
}

pub fn readOutputLane(self: *const Self, program: *const Program, lane: usize, variable: ids.InterfaceVariableId, values: []u32) RuntimeError!void {
    if (lane >= lane_count)
        return RuntimeError.InvalidLane;
    const binding = program.interfaceBinding(variable) orelse return RuntimeError.InvalidInterface;
    if (binding.direction != .output)
        return RuntimeError.WrongInterfaceDirection;
    if (binding.span.components != values.len)
        return RuntimeError.WrongInterfaceType;

    const lane_registers = self.laneRegistersConst(@intCast(lane));
    @memcpy(values, lane_registers[@backingInt(binding.span.base)..][0..values.len]);
}

pub fn readOutputVector(self: *const Self, program: *const Program, variable: ids.InterfaceVariableId, component: usize) RuntimeError!@Vector(lane_count, u32) {
    const binding = program.interfaceBinding(variable) orelse return RuntimeError.InvalidInterface;
    if (binding.direction != .output)
        return RuntimeError.WrongInterfaceDirection;
    if (component >= binding.span.components)
        return RuntimeError.WrongInterfaceType;
    const register_index = std.math.add(usize, @backingInt(binding.span.base), component) catch return RuntimeError.InvalidBytecode;
    if (register_index >= self.register_count)
        return RuntimeError.InvalidBytecode;
    return self.loadRegisterVector(@fromBackingInt(@intCast(register_index)));
}

pub fn runWave(self: *Self, program: *const Program, options: RunOptions) RuntimeError!WaveResult {
    switch (self.state) {
        .ready => self.state = .running,
        .barrier => {
            self.active_mask = self.barrier_mask;
            self.barrier_mask = 0;
            self.state = .running;
        },
        .running, .completed => return RuntimeError.InvalidResume,
    }

    while (self.active_mask != 0) {
        if (self.steps >= options.max_steps)
            return RuntimeError.StepLimitExceeded;

        const group = try self.nextExecutionGroup(program);
        const group_mask = group.mask;
        const instruction = program.code[group.pc];
        self.steps += 1;
        self.lane_steps += @popCount(group_mask);

        // Derivatives must sample operands before any lane advances or writes its result
        if (instruction.opcode == .fwidth) {
            try self.groupFwidth(instruction, group_mask);
            self.advanceGroupPcs(group_mask);
            continue;
        }

        if (@popCount(group_mask) >= 2) {
            if (try self.executeVectorGroup(program, options, instruction, group_mask)) |result| {
                self.fast_path_lane_steps += @popCount(group_mask);
                if (result == .advance)
                    self.advanceGroupPcs(group_mask);
                continue;
            }
        }

        for (0..lane_count) |lane_index| {
            const lane: Lane = @intCast(lane_index);
            const lane_bit = laneBit(lane);
            if ((group_mask & lane_bit) == 0)
                continue;

            self.selectLane(lane);
            self.pcs[lane_index] += 1;
            const outcome = try self.executeInstruction(program, options, instruction);
            if (outcome) |finished| switch (finished) {
                .returned => {
                    self.returned_mask |= lane_bit;
                    self.active_mask &= ~lane_bit;
                },
                .discarded => {
                    self.discarded_mask |= lane_bit;
                    self.active_mask &= ~lane_bit;
                },
                .barrier => {
                    self.barrier_mask |= lane_bit;
                    self.active_mask &= ~lane_bit;
                },
            };
        }
    }

    if (self.barrier_mask != 0) {
        if ((self.returned_mask | self.discarded_mask) != 0)
            return RuntimeError.BarrierDivergence;
        self.state = .barrier;
    } else {
        self.state = .completed;
    }

    return .{
        .returned_mask = self.returned_mask,
        .discarded_mask = self.discarded_mask,
        .barrier_mask = self.barrier_mask,
    };
}

fn nextExecutionGroup(self: *const Self, program: *const Program) RuntimeError!struct { pc: usize, mask: LaneMask } {
    var candidates = self.active_mask;
    while (candidates != 0) {
        const first_lane: Lane = @intCast(@ctz(candidates));
        const pc = self.pcs[first_lane];
        if (pc >= program.code.len)
            return RuntimeError.InvalidBytecode;

        var mask: LaneMask = 0;
        for (0..lane_count) |lane| {
            const bit = laneBit(@intCast(lane));
            if ((self.active_mask & bit) != 0 and self.pcs[lane] == pc)
                mask |= bit;
        }

        if (program.code[pc].opcode == .fwidth) {
            const waiting = mask;
            for (0..lane_count / 4) |quad| {
                const quad_mask = @as(LaneMask, 0b1111) << @intCast(quad * 4);
                const participating = mask & quad_mask;
                if (participating == 0 or participating == quad_mask)
                    continue;

                if ((self.active_mask & quad_mask) != quad_mask)
                    return RuntimeError.DerivativeUnavailable;

                // Park early arrivals at their PC while the other arm reaches the merge
                mask &= ~quad_mask;
            }
            if (mask == 0) {
                candidates &= ~waiting;
                continue;
            }
        }
        return .{ .pc = pc, .mask = mask };
    }

    // Every active lane is parked at an incompatible derivative instruction
    return RuntimeError.DerivativeUnavailable;
}

pub fn executedSteps(self: *const Self) usize {
    return self.lane_steps;
}

pub fn fastPathExecutedSteps(self: *const Self) usize {
    return self.fast_path_lane_steps;
}

const laneBit = simd.laneBit;

fn laneRegisters(self: *Self, lane: Lane) []u32 {
    const start = @as(usize, lane) * self.register_count;
    return self.register_backing[start..][0..self.register_count];
}

fn laneRegistersConst(self: *const Self, lane: Lane) []const u32 {
    const start = @as(usize, lane) * self.register_count;
    return self.register_backing[start..][0..self.register_count];
}

fn selectLane(self: *Self, lane: Lane) void {
    self.current_lane = lane;
    self.registers = self.laneRegisters(lane);
    const scratch_start = @as(usize, lane) * self.scratch_count;
    self.scratch = self.scratch_backing[scratch_start..][0..self.scratch_count];
}

fn isObservable(self: *const Self) bool {
    return (self.observable_mask & laneBit(self.current_lane)) != 0;
}

const U32x4 = @Vector(lane_count, u32);
const I32x4 = @Vector(lane_count, i32);
const F32x4 = @Vector(lane_count, f32);

fn loadRegisterVector(self: *const Self, register: bc.Register) U32x4 {
    const index: usize = @backingInt(register);
    // SAFETY: the following loop initializes every vector lane before result is returned
    var result: U32x4 = undefined;
    inline for (0..lane_count) |lane|
        result[lane] = self.register_backing[lane * self.register_count + index];
    return result;
}

fn storeRegisterVector(self: *Self, register: bc.Register, values: U32x4) void {
    const index: usize = @backingInt(register);
    inline for (0..lane_count) |lane|
        self.register_backing[lane * self.register_count + index] = values[lane];
}

fn storeRegisterVectorMasked(self: *Self, register: bc.Register, values: U32x4, mask: LaneMask) void {
    if (mask == full_lane_mask) {
        self.storeRegisterVector(register, values);
        return;
    }

    const index: usize = @backingInt(register);
    inline for (0..lane_count) |lane| {
        if ((mask & laneBit(lane)) != 0)
            self.register_backing[lane * self.register_count + index] = values[lane];
    }
}

fn loadScratchVector(self: *const Self, index: usize) U32x4 {
    // SAFETY: the following loop initializes every vector lane before result is returned
    var result: U32x4 = undefined;
    inline for (0..lane_count) |lane|
        result[lane] = self.scratch_backing[lane * self.scratch_count + index];
    return result;
}

fn storeScratchVector(self: *Self, index: usize, values: U32x4) void {
    inline for (0..lane_count) |lane|
        self.scratch_backing[lane * self.scratch_count + index] = values[lane];
}

fn storeScratchVectorMasked(self: *Self, index: usize, values: U32x4, mask: LaneMask) void {
    if (mask == full_lane_mask) {
        self.storeScratchVector(index, values);
        return;
    }

    inline for (0..lane_count) |lane| {
        if ((mask & laneBit(lane)) != 0)
            self.scratch_backing[lane * self.scratch_count + index] = values[lane];
    }
}

fn laneMaskVector(mask: LaneMask) @Vector(lane_count, bool) {
    // SAFETY: the following loop initializes every vector lane before result is returned
    var result: @Vector(lane_count, bool) = undefined;
    inline for (0..lane_count) |lane|
        result[lane] = (mask & laneBit(lane)) != 0;
    return result;
}

fn advanceGroupPcs(self: *Self, mask: LaneMask) void {
    for (0..lane_count) |lane| {
        if ((mask & laneBit(@intCast(lane))) != 0)
            self.pcs[lane] += 1;
    }
}

fn setGroupPcs(self: *Self, mask: LaneMask, pc: usize) void {
    for (0..lane_count) |lane| {
        if ((mask & laneBit(@intCast(lane))) != 0)
            self.pcs[lane] = pc;
    }
}

const FullGroupResult = enum { advance, pc_set };

fn executeVectorGroup(self: *Self, program: *const Program, options: RunOptions, instruction: bc.Instruction, mask: LaneMask) RuntimeError!?FullGroupResult {
    switch (instruction.opcode) {
        .absolute => try self.groupUnaryFloat(instruction, .absolute, mask),
        .bitwise_and => try self.groupBinaryInt(instruction, .bitwise_and, mask),
        .bitwise_or => try self.groupBinaryInt(instruction, .bitwise_or, mask),
        .bitwise_xor => try self.groupBinaryInt(instruction, .bitwise_xor, mask),
        .ceil => try self.groupUnaryFloat(instruction, .ceil, mask),
        .exp => try self.groupUnaryFloat(instruction, .exp, mask),
        .compare_equal => try self.groupCompareInt(instruction, .equal, mask),
        .compare_not_equal => try self.groupCompareInt(instruction, .not_equal, mask),
        .compare_ordered_float_equal => try self.groupCompareFloat(instruction, .ordered_equal, mask),
        .compare_ordered_float_less => try self.groupCompareFloat(instruction, .ordered_less, mask),
        .compare_ordered_float_less_equal => try self.groupCompareFloat(instruction, .ordered_less_equal, mask),
        .compare_ordered_float_not_equal => try self.groupCompareFloat(instruction, .ordered_not_equal, mask),
        .compare_signed_less => try self.groupCompareInt(instruction, .signed_less, mask),
        .compare_unordered_float_equal => try self.groupCompareFloat(instruction, .unordered_equal, mask),
        .compare_unordered_float_less => try self.groupCompareFloat(instruction, .unordered_less, mask),
        .compare_unordered_float_not_equal => try self.groupCompareFloat(instruction, .unordered_not_equal, mask),
        .compare_unsigned_less => try self.groupCompareInt(instruction, .unsigned_less, mask),
        .copy => try self.groupCopy(instruction, mask),
        .float_add => try self.groupBinaryFloat(instruction, .add, false, mask),
        .float_divide => try self.groupBinaryFloat(instruction, .divide, false, mask),
        .float_max => try self.groupBinaryFloat(instruction, .max, false, mask),
        .float_min => try self.groupBinaryFloat(instruction, .min, false, mask),
        .float_multiply => try self.groupBinaryFloat(instruction, .multiply, false, mask),
        .float_subtract => try self.groupBinaryFloat(instruction, .subtract, false, mask),
        .floor => try self.groupUnaryFloat(instruction, .floor, mask),
        .integer_add => try self.groupBinaryInt(instruction, .add, mask),
        .integer_multiply => try self.groupBinaryInt(instruction, .multiply, mask),
        .integer_subtract => try self.groupBinaryInt(instruction, .subtract, mask),
        .logical_and => try self.groupBinaryInt(instruction, .logical_and, mask),
        .logical_or => try self.groupBinaryInt(instruction, .logical_or, mask),
        .negate_f32 => try self.groupUnaryFloat(instruction, .negate, mask),
        .pow => try self.groupBinaryFloat(instruction, .pow, false, mask),
        .select => try self.groupSelect(instruction, mask),
        .sign => try self.groupUnaryFloat(instruction, .sign, mask),
        .vector_times_scalar, .matrix_times_scalar => try self.groupBinaryFloat(instruction, .multiply, true, mask),
        .branch => {
            if (instruction.immediate >= program.branches.len or @backingInt(instruction.a) >= self.register_count)
                return RuntimeError.InvalidBytecode;
            const condition = self.loadRegisterVector(instruction.a) != @as(U32x4, @splat(0));
            const selected_lanes = laneMaskVector(mask);
            const all_true = @reduce(.And, !selected_lanes | condition);
            const all_false = @reduce(.And, !selected_lanes | !condition);
            if (!all_true and !all_false)
                return null;

            const branch = program.branches[instruction.immediate];
            const target_pc = try self.applyGroupEdge(program, if (all_true) branch.true_edge else branch.false_edge, mask);
            self.setGroupPcs(mask, target_pc);
            return .pc_set;
        },
        .jump_edge => {
            self.setGroupPcs(mask, try self.applyGroupEdge(program, instruction.immediate, mask));
            return .pc_set;
        },
        .load_buffer => {
            if (mask != full_lane_mask)
                return null;
            for (0..lane_count) |lane_index| {
                self.selectLane(@intCast(lane_index));
                try self.loadBuffer(program, options.resource_buffers, instruction);
            }
        },
        .load_push_constant => {
            if (mask != full_lane_mask)
                return null;
            for (0..lane_count) |lane_index| {
                self.selectLane(@intCast(lane_index));
                try self.loadPushConstant(options.push_constants, instruction);
            }
        },
        else => return null,
    }
    return .advance;
}

fn applyGroupEdge(self: *Self, program: *const Program, edge_index: u32, mask: LaneMask) RuntimeError!usize {
    if (edge_index >= program.edges.len)
        return RuntimeError.InvalidBytecode;

    const edge = program.edges[edge_index];
    const end = std.math.add(usize, edge.first_copy, edge.copy_count) catch return RuntimeError.InvalidBytecode;
    if (end > program.copies.len or edge.target_pc >= program.code.len)
        return RuntimeError.InvalidBytecode;

    const copies = program.copies[edge.first_copy..end];
    for (copies) |item| {
        const scratch_base: usize = @backingInt(item.scratch_base);
        try self.validateRegisterRange(item.source, item.components);
        const scratch_end = std.math.add(usize, scratch_base, item.components) catch return RuntimeError.InvalidBytecode;
        if (scratch_end > self.scratch_count)
            return RuntimeError.InvalidBytecode;
        for (0..item.components) |component|
            self.storeScratchVectorMasked(scratch_base + component, self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(item.source) + component))), mask);
    }
    for (copies) |item| {
        const scratch_base: usize = @backingInt(item.scratch_base);
        try self.validateRegisterRange(item.destination, item.components);
        for (0..item.components) |component|
            self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(item.destination) + component)), self.loadScratchVector(scratch_base + component), mask);
    }
    return edge.target_pc;
}

fn groupUnaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: UnaryFloat, mask: LaneMask) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);
    for (0..instruction.components) |component| {
        const source: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component))));
        const result = switch (operation) {
            .absolute => @abs(source),
            .ceil => @ceil(source),
            .exp => @exp(source),
            .floor => @floor(source),
            .negate => -source,
            .sign => @select(f32, source > @as(F32x4, @splat(0.0)), @as(F32x4, @splat(1.0)), @select(f32, source < @as(F32x4, @splat(0.0)), @as(F32x4, @splat(-1.0)), @as(F32x4, @splat(0.0)))),
            .round => @round(source),
        };
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), @bitCast(result), mask);
    }
}

fn groupBinaryInt(self: *Self, instruction: bc.Instruction, comptime operation: BinaryInt, mask: LaneMask) RuntimeError!void {
    if (instruction.components == 0 or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);

    for (0..instruction.components) |component| {
        const lhs = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component)));
        const rhs = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.c) + component)));
        const result: U32x4 = switch (operation) {
            .add => lhs +% rhs,
            .subtract => lhs -% rhs,
            .multiply => lhs *% rhs,
            .bitwise_and => lhs & rhs,
            .bitwise_or => lhs | rhs,
            .bitwise_xor => lhs ^ rhs,
            .logical_and => @select(u32, (lhs != @as(U32x4, @splat(0))) & (rhs != @as(U32x4, @splat(0))), @as(U32x4, @splat(1)), @as(U32x4, @splat(0))),
            .logical_or => @select(u32, (lhs != @as(U32x4, @splat(0))) | (rhs != @as(U32x4, @splat(0))), @as(U32x4, @splat(1)), @as(U32x4, @splat(0))),
            else => unreachable,
        };
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), result, mask);
    }
}

fn groupBinaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: BinaryFloat, comptime broadcast_rhs: bool, mask: LaneMask) RuntimeError!void {
    if (instruction.components == 0 or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, if (broadcast_rhs) 1 else instruction.components);

    for (0..instruction.components) |component| {
        const lhs: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component))));
        const rhs_component = if (broadcast_rhs) 0 else component;
        const rhs: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.c) + rhs_component))));
        if (operation == .pow) {
            const lhs_lanes: [lane_count]f32 = @bitCast(lhs);
            const rhs_lanes: [lane_count]f32 = @bitCast(rhs);
            var result_lanes = lhs_lanes;
            for (0..lane_count) |lane| {
                if ((mask & laneBit(@intCast(lane))) != 0)
                    result_lanes[lane] = std.math.pow(f32, lhs_lanes[lane], rhs_lanes[lane]);
            }
            self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), @bitCast(result_lanes), mask);
            continue;
        }

        const result = switch (operation) {
            .add => lhs + rhs,
            .subtract => lhs - rhs,
            .multiply => lhs * rhs,
            .divide => lhs / rhs,
            .max => @select(f32, lhs < rhs, rhs, lhs),
            .min => @select(f32, lhs > rhs, rhs, lhs),
            else => unreachable,
        };
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), @bitCast(result), mask);
    }
}

fn groupCompareInt(self: *Self, instruction: bc.Instruction, comptime operation: CompareInt, mask: LaneMask) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);
    for (0..instruction.components) |component| {
        const lhs = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component)));
        const rhs = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.c) + component)));
        const condition = switch (operation) {
            .equal => lhs == rhs,
            .not_equal => lhs != rhs,
            .unsigned_less => lhs < rhs,
            .signed_less => @as(I32x4, @bitCast(lhs)) < @as(I32x4, @bitCast(rhs)),
        };
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), @select(u32, condition, @as(U32x4, @splat(1)), @as(U32x4, @splat(0))), mask);
    }
}

fn groupCompareFloat(self: *Self, instruction: bc.Instruction, comptime operation: CompareFloat, mask: LaneMask) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);
    for (0..instruction.components) |component| {
        const lhs: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component))));
        const rhs: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.c) + component))));
        const unordered = (lhs != lhs) | (rhs != rhs);
        const condition = switch (operation) {
            .ordered_equal => !unordered & (lhs == rhs),
            .unordered_equal => unordered | (lhs == rhs),
            .ordered_not_equal => !unordered & (lhs != rhs),
            .unordered_not_equal => unordered | (lhs != rhs),
            .ordered_less => !unordered & (lhs < rhs),
            .ordered_less_equal => !unordered & (lhs <= rhs),
            .unordered_less => unordered | (lhs < rhs),
        };
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), @select(u32, condition, @as(U32x4, @splat(1)), @as(U32x4, @splat(0))), mask);
    }
}

fn groupCopy(self: *Self, instruction: bc.Instruction, mask: LaneMask) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    for (0..instruction.components) |component|
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component))), mask);
}

fn groupSelect(self: *Self, instruction: bc.Instruction, mask: LaneMask) RuntimeError!void {
    if (instruction.components == 0 or instruction.immediate > 1)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, if (instruction.immediate == 1) instruction.components else 1);
    try self.validateRegisterRange(instruction.c, instruction.components);
    try self.validateRegisterRange(instruction.d, instruction.components);

    for (0..instruction.components) |component| {
        const condition_component = if (instruction.immediate == 1) component else 0;
        const condition = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + condition_component))) != @as(U32x4, @splat(0));
        const true_value = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.c) + component)));
        const false_value = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.d) + component)));
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), @select(u32, condition, true_value, false_value), mask);
    }
}

fn executeInstruction(self: *Self, program: *const Program, options: RunOptions, instruction: bc.Instruction) RuntimeError!?LaneOutcome {
    switch (instruction.opcode) {
        .@"unreachable" => return RuntimeError.UnreachableExecuted,
        .absolute => try self.unaryFloat(instruction, .absolute),
        .all => try self.all(instruction),
        .any => try self.any(instruction),
        .atan2 => try self.binaryFloat(instruction, .atan2, false),
        .array_length => try self.arrayLength(program, options.resource_buffers, instruction),
        .arithmetic_shift_right => try self.binaryInt(instruction, .arithmetic_shift_right),
        .bit_count => try self.unaryInt(instruction, .bit_count),
        .bit_field_extract_signed => try self.bitFieldExtract(instruction, true),
        .bit_field_extract_unsigned => try self.bitFieldExtract(instruction, false),
        .bit_field_insert => try self.bitFieldInsert(instruction),
        .bit_reverse => try self.unaryInt(instruction, .bit_reverse),
        .bitwise_and => try self.binaryInt(instruction, .bitwise_and),
        .bitwise_not => try self.unaryInt(instruction, .bitwise_not),
        .bitwise_or => try self.binaryInt(instruction, .bitwise_or),
        .bitwise_xor => try self.binaryInt(instruction, .bitwise_xor),
        .branch => {
            if (instruction.immediate >= program.branches.len)
                return RuntimeError.InvalidBytecode;

            const branch = program.branches[instruction.immediate];
            self.pcs[self.current_lane] = try self.applyEdge(program, if (self.registers[@backingInt(instruction.a)] != 0) branch.true_edge else branch.false_edge);
        },
        .ceil => try self.unaryFloat(instruction, .ceil),
        .exp => try self.unaryFloat(instruction, .exp),
        .compare_equal => self.compareInt(instruction, .equal),
        .compare_not_equal => self.compareInt(instruction, .not_equal),
        .compare_ordered_float_equal => self.compareFloat(instruction, .ordered_equal),
        .compare_ordered_float_less => self.compareFloat(instruction, .ordered_less),
        .compare_ordered_float_less_equal => self.compareFloat(instruction, .ordered_less_equal),
        .compare_ordered_float_not_equal => self.compareFloat(instruction, .ordered_not_equal),
        .compare_signed_less => self.compareInt(instruction, .signed_less),
        .compare_unordered_float_equal => self.compareFloat(instruction, .unordered_equal),
        .compare_unordered_float_less => self.compareFloat(instruction, .unordered_less),
        .compare_unordered_float_not_equal => self.compareFloat(instruction, .unordered_not_equal),
        .compare_unsigned_less => self.compareInt(instruction, .unsigned_less),
        .copy => self.copy(instruction),
        .discard => return .discarded,
        .dot => try self.dot(instruction),
        .float_add => try self.binaryFloat(instruction, .add, false),
        .float_divide => try self.binaryFloat(instruction, .divide, false),
        .floor => try self.unaryFloat(instruction, .floor),
        .float_max => try self.binaryFloat(instruction, .max, false),
        .float_min => try self.binaryFloat(instruction, .min, false),
        .float_mix => try self.fMix(instruction),
        .float_modulo => try self.binaryFloat(instruction, .modulo, false),
        .float_multiply => try self.binaryFloat(instruction, .multiply, false),
        .float_remainder => try self.binaryFloat(instruction, .remainder, false),
        .float_subtract => try self.binaryFloat(instruction, .subtract, false),
        .float_to_signed => try self.floatToInt(instruction, true),
        .float_to_unsigned => try self.floatToInt(instruction, false),
        .vector_times_scalar => try self.binaryFloat(instruction, .multiply, true),
        .vector_times_matrix => try self.vectorTimesMatrix(instruction),
        .matrix_times_matrix => try self.matrixTimesMatrix(instruction),
        .matrix_times_scalar => try self.binaryFloat(instruction, .multiply, true),
        .matrix_times_vector => try self.matrixTimesVector(instruction),
        .integer_add => try self.binaryInt(instruction, .add),
        .integer_add_carry => try self.extendedInt(instruction, .add_carry),
        .integer_multiply => try self.binaryInt(instruction, .multiply),
        .integer_subtract => try self.binaryInt(instruction, .subtract),
        .integer_subtract_borrow => try self.extendedInt(instruction, .subtract_borrow),
        .image_read => try self.imageRead(program, options.resource_images, instruction),
        .image_read_float => try self.imageReadFloat(program, options.resource_images, instruction),
        .image_gather => try self.imageGather(program, options.resource_images, options.resource_samplers, instruction),
        .image_sample_explicit_lod => try self.imageSample(program, options.resource_images, options.resource_samplers, instruction, true),
        .image_sample_implicit_lod => try self.imageSample(program, options.resource_images, options.resource_samplers, instruction, false),
        .image_write => if (self.isObservable()) try self.imageWrite(program, options.resource_images, instruction),
        .image_write_float => if (self.isObservable()) try self.imageWriteFloat(program, options.resource_images, instruction),
        .is_inf => try self.classifyFloat(instruction, .infinite),
        .is_nan => try self.classifyFloat(instruction, .nan),
        .jump_edge => self.pcs[self.current_lane] = try self.applyEdge(program, instruction.immediate),
        .load_buffer => try self.loadBuffer(program, options.resource_buffers, instruction),
        .load_push_constant => try self.loadPushConstant(options.push_constants, instruction),
        .load_workgroup => try self.loadWorkgroup(program, options.workgroup_memory, instruction),
        .logical_and => try self.binaryInt(instruction, .logical_and),
        .logical_not => try self.unaryInt(instruction, .logical_not),
        .logical_or => try self.binaryInt(instruction, .logical_or),
        .logical_shift_right => try self.binaryInt(instruction, .logical_shift_right),
        .negate_f32 => try self.unaryFloat(instruction, .negate),
        .normalize => try self.normalize(instruction),
        .length => try self.vectorLength(instruction),
        .vector_extract_dynamic => try self.vectorExtractDynamic(instruction),
        .fwidth => return RuntimeError.DerivativeUnavailable,
        .sign => try self.unaryFloat(instruction, .sign),
        .negate_i32 => try self.unaryInt(instruction, .negate),
        .outer_product => try self.outerProduct(instruction),
        .pow => try self.binaryFloat(instruction, .pow, false),
        .return_void => return .returned,
        .round => try self.unaryFloat(instruction, .round),
        .select => try self.select(instruction),
        .shift_left => try self.binaryInt(instruction, .shift_left),
        .signed_divide => try self.binaryInt(instruction, .signed_divide),
        .signed_modulo => try self.binaryInt(instruction, .signed_modulo),
        .signed_multiply_extended => try self.extendedInt(instruction, .signed_multiply),
        .signed_to_float => try self.intToFloat(instruction, true),
        .smooth_step => try self.smoothStep(instruction),
        .store_buffer => if (self.isObservable()) try self.storeBuffer(program, options.resource_buffers, instruction),
        .store_workgroup => if (self.isObservable()) try self.storeWorkgroup(program, options.workgroup_memory, instruction),
        .transpose => try self.transpose(instruction),
        .control_barrier => return .barrier,
        .unsigned_divide => try self.binaryInt(instruction, .unsigned_divide),
        .unsigned_modulo => try self.binaryInt(instruction, .unsigned_modulo),
        .unsigned_multiply_extended => try self.extendedInt(instruction, .unsigned_multiply),
        .unsigned_to_float => try self.intToFloat(instruction, false),
    }
    return null;
}

fn all(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    self.registers[@backingInt(instruction.a)] = blk: {
        for (0..instruction.components) |component| {
            if (self.registers[@backingInt(instruction.b) + component] == 0)
                break :blk 0;
        }
        break :blk 1;
    };
}

fn any(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    self.registers[@backingInt(instruction.a)] = blk: {
        for (0..instruction.components) |component| {
            if (self.registers[@backingInt(instruction.b) + component] != 0)
                break :blk 1;
        }
        break :blk 0;
    };
}

fn arrayLength(self: *Self, program: *const Program, resource_buffers: []const ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.components != 1)
        return RuntimeError.InvalidBytecode;

    if (@backingInt(instruction.a) >= self.registers.len or @backingInt(instruction.b) >= self.registers.len)
        return RuntimeError.InvalidBytecode;

    if (instruction.immediate >= program.array_lengths.len)
        return RuntimeError.InvalidBytecode;

    const metadata = program.array_lengths[instruction.immediate];

    if (metadata.stride == 0)
        return RuntimeError.InvalidBytecode;

    const buffer = try resourceBuffer(program, resource_buffers, metadata.resource);
    const byte_offset: usize = self.registers[@backingInt(instruction.b)];

    if (byte_offset > buffer.len)
        return RuntimeError.BufferOutOfBounds;

    const byte_length = buffer.len - byte_offset;
    const element_count = byte_length / metadata.stride;

    self.registers[@backingInt(instruction.a)] = std.math.cast(u32, element_count) orelse return RuntimeError.IntegerOverflow;
}

fn copy(self: *Self, instruction: bc.Instruction) void {
    for (0..instruction.components) |component|
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = self.registers[@as(usize, @backingInt(instruction.b)) + component];
}

fn unaryInt(self: *Self, instruction: bc.Instruction, comptime operation: UnaryInt) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);

    for (0..instruction.components) |component| {
        const value = self.registers[@as(usize, @backingInt(instruction.b)) + component];
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = switch (operation) {
            .negate => 0 -% value,
            .logical_not => @intFromBool(value == 0),
            .bitwise_not => ~value,
            .bit_count => @popCount(value),
            .bit_reverse => @bitReverse(value),
        };
    }
}

fn bitFieldExtract(self: *Self, instruction: bc.Instruction, comptime signed: bool) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, 1);
    try self.validateRegisterRange(instruction.d, 1);

    const bit_offset = self.registers[@backingInt(instruction.c)];
    const count = self.registers[@backingInt(instruction.d)];
    const valid_range = validBitFieldRange(bit_offset, count);

    for (0..instruction.components) |component| {
        const value = self.registers[@as(usize, @backingInt(instruction.b)) + component];
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = if (!valid_range or count == 0)
            0
        else blk: {
            const shifted = value >> @intCast(bit_offset);
            const extracted = shifted & bitMask(count);
            if (!signed or count == 32)
                break :blk extracted;

            const sign_shift: u5 = @intCast(32 - count);
            break :blk @bitCast(@as(i32, @bitCast(extracted << sign_shift)) >> sign_shift);
        };
    }
}

fn bitFieldInsert(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.immediate >= @backingInt(bc.Register.invalid_register))
        return RuntimeError.InvalidBytecode;
    const count_register: bc.Register = @fromBackingInt(@intCast(instruction.immediate));

    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);
    try self.validateRegisterRange(instruction.d, 1);
    try self.validateRegisterRange(count_register, 1);

    const bit_offset = self.registers[@backingInt(instruction.d)];
    const count = self.registers[@backingInt(count_register)];
    const valid_range = validBitFieldRange(bit_offset, count);

    for (0..instruction.components) |component| {
        const base = self.registers[@as(usize, @backingInt(instruction.b)) + component];
        const insert = self.registers[@as(usize, @backingInt(instruction.c)) + component];
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = if (!valid_range or count == 0)
            base
        else blk: {
            const field_mask = bitMask(count) << @intCast(bit_offset);
            break :blk (base & ~field_mask) | ((insert << @intCast(bit_offset)) & field_mask);
        };
    }
}

fn validBitFieldRange(bit_offset: u32, count: u32) bool {
    return bit_offset <= 32 and count <= 32 - bit_offset;
}

fn bitMask(count: u32) u32 {
    return if (count == 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(count)) - 1;
}

fn unaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: UnaryFloat) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);
    for (0..instruction.components) |component| {
        const value: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        const result = switch (operation) {
            .absolute => @abs(value),
            .ceil => @ceil(value),
            .exp => @exp(value),
            .floor => @floor(value),
            .negate => -value,
            .round => @round(value),
            .sign => if (value > 0.0) @as(f32, 1.0) else if (value < 0.0) @as(f32, -1.0) else @as(f32, 0.0),
        };
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = @bitCast(result);
    }
}

fn groupFwidth(self: *Self, instruction: bc.Instruction, mask: LaneMask) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);
    // Lane order is top-left, top-right, bottom-left, bottom-right
    // Divergent derivatives are undefined; reject them rather than use stale registers
    for (0..lane_count / 4) |quad| {
        const quad_mask = @as(LaneMask, 0b1111) << @intCast(quad * 4);
        const participating = mask & quad_mask;
        if (participating != 0 and participating != quad_mask)
            return RuntimeError.DerivativeUnavailable;
    }
    for (0..instruction.components) |component| {
        const source: bc.Register = @fromBackingInt(@intCast(@as(usize, @backingInt(instruction.b)) + component));
        const destination: bc.Register = @fromBackingInt(@intCast(@as(usize, @backingInt(instruction.a)) + component));
        const values: [lane_count]f32 = @bitCast(self.loadRegisterVector(source));
        var result: [lane_count]f32 = undefined;
        for (0..lane_count) |lane|
            result[lane] = @abs(values[lane ^ 1] - values[lane]) + @abs(values[lane ^ 2] - values[lane]);
        self.storeRegisterVectorMasked(destination, @bitCast(result), mask);
    }
}

fn vectorLength(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, 1);
    try self.validateRegisterRange(instruction.b, instruction.components);

    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;

    const source = self.registers[@backingInt(instruction.b)..][0..instruction.components];
    var magnitude: f32 = 0;

    if (instruction.components == 1) {
        magnitude = @abs(@as(f32, @bitCast(source[0])));
    } else {
        for (source) |bits| {
            const value: f32 = @bitCast(bits);
            magnitude += value * value;
        }
        magnitude = @sqrt(magnitude);
    }
    self.registers[@backingInt(instruction.a)] = @bitCast(magnitude);
}

fn vectorExtractDynamic(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, 1);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, 1);
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;

    const index = self.registers[@backingInt(instruction.c)];
    // OOB extraction is undefined, including negative signed indices. Keep the
    // chosen zero result lane-local so extrapolated helpers cannot abort the wave.
    self.registers[@backingInt(instruction.a)] = if (index < instruction.components)
        self.registers[@as(usize, @backingInt(instruction.b)) + index]
    else
        0;
}

fn normalize(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);

    var squared_length: f32 = 0.0;
    for (0..instruction.components) |component| {
        const value: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        squared_length += value * value;
    }
    const length = @sqrt(squared_length);
    for (0..instruction.components) |component| {
        const value: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = @bitCast(value / length);
    }
}

fn classifyFloat(self: *Self, instruction: bc.Instruction, comptime classification: FloatClassification) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);
    for (0..instruction.components) |component| {
        const value: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = @intFromBool(switch (classification) {
            .infinite => std.math.isInf(value),
            .nan => std.math.isNan(value),
        });
    }
}

fn intToFloat(self: *Self, instruction: bc.Instruction, comptime signed: bool) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);

    for (0..instruction.components) |component| {
        const source = self.registers[@as(usize, @backingInt(instruction.b)) + component];
        const converted: f32 = if (signed)
            @floatFromInt(@as(i32, @bitCast(source)))
        else
            @floatFromInt(source);
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = @bitCast(converted);
    }
}

fn floatToInt(self: *Self, instruction: bc.Instruction, comptime signed: bool) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);

    for (0..instruction.components) |component| {
        const source: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = if (signed)
            @bitCast(std.math.lossyCast(i32, source))
        else
            std.math.lossyCast(u32, source);
    }
}

fn binaryInt(self: *Self, instruction: bc.Instruction, comptime operation: BinaryInt) RuntimeError!void {
    for (0..instruction.components) |component| {
        const lhs = self.registers[@as(usize, @backingInt(instruction.b)) + component];
        const rhs = self.registers[@as(usize, @backingInt(instruction.c)) + component];
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = switch (operation) {
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

fn extendedInt(self: *Self, instruction: bc.Instruction, comptime operation: ExtendedInt) RuntimeError!void {
    if (instruction.components == 0 or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;

    const result_components = std.math.mul(usize, instruction.components, 2) catch return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, result_components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);

    for (0..instruction.components) |component| {
        const lhs = self.registers[@as(usize, @backingInt(instruction.b)) + component];
        const rhs = self.registers[@as(usize, @backingInt(instruction.c)) + component];
        const low, const high = switch (operation) {
            .add_carry => blk: {
                const result, const carry = @addWithOverflow(lhs, rhs);
                break :blk .{ result, @as(u32, carry) };
            },
            .subtract_borrow => blk: {
                const result, const borrow = @subWithOverflow(lhs, rhs);
                break :blk .{ result, @as(u32, borrow) };
            },
            .signed_multiply => blk: {
                const product = @as(i64, @as(i32, @bitCast(lhs))) * @as(i64, @as(i32, @bitCast(rhs)));
                const bits: u64 = @bitCast(product);
                break :blk .{ @as(u32, @truncate(bits)), @as(u32, @truncate(bits >> 32)) };
            },
            .unsigned_multiply => blk: {
                const product = @as(u64, lhs) * @as(u64, rhs);
                break :blk .{ @as(u32, @truncate(product)), @as(u32, @truncate(product >> 32)) };
            },
        };
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = low;
        self.registers[@as(usize, @backingInt(instruction.a)) + instruction.components + component] = high;
    }
}

fn binaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: BinaryFloat, comptime broadcast_rhs: bool) RuntimeError!void {
    if (instruction.components == 0 or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, if (broadcast_rhs) 1 else instruction.components);

    for (0..instruction.components) |component| {
        const lhs: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        const rhs_component = if (broadcast_rhs) 0 else component;
        const rhs: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.c)) + rhs_component]);
        const result = switch (operation) {
            .add => lhs + rhs,
            .subtract => lhs - rhs,
            .multiply => lhs * rhs,
            .divide => lhs / rhs,
            .max => if (lhs < rhs) rhs else lhs,
            .min => if (lhs > rhs) rhs else lhs,
            .modulo => lhs - rhs * @floor(lhs / rhs),
            .remainder => @rem(lhs, rhs),
            .atan2 => std.math.atan2(lhs, rhs),
            .pow => std.math.pow(f32, lhs, rhs),
        };
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = @bitCast(result);
    }
}

fn smoothStep(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);
    try self.validateRegisterRange(instruction.d, instruction.components);

    for (0..instruction.components) |component| {
        const edge0: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        const edge1: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.c)) + component]);
        const value: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.d)) + component]);
        const t = std.math.clamp((value - edge0) / (edge1 - edge0), 0.0, 1.0);
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = @bitCast(t * t * (3.0 - 2.0 * t));
    }
}

fn dot(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.components < 2 or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, 1);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);

    var sum: f32 = 0.0;
    for (0..instruction.components) |component| {
        const lhs: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        const rhs: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.c)) + component]);
        sum += lhs * rhs;
    }
    self.registers[@backingInt(instruction.a)] = @bitCast(sum);
}

fn fMix(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);

    for (0..instruction.components) |component| {
        const x: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + component]);
        const y: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.c)) + component]);
        const a: f32 = @bitCast(self.registers[@as(usize, @backingInt(instruction.d)) + component]);
        self.registers[@backingInt(instruction.a) + component] = @bitCast(x * (1.0 - a) + y * a);
    }
}

fn outerProduct(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    const dimensions = bc.MatrixDimensions.decode(instruction.immediate);
    if (dimensions.rows == 0 or dimensions.inner != 0 or dimensions.columns == 0 or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;

    const result_components = try componentProduct(dimensions.rows, dimensions.columns);
    if (instruction.components != result_components)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, result_components);
    try self.validateRegisterRange(instruction.b, dimensions.rows);
    try self.validateRegisterRange(instruction.c, dimensions.columns);

    for (0..dimensions.columns) |column| {
        const rhs: f32 = @bitCast(self.registers[@backingInt(instruction.c) + column]);
        for (0..dimensions.rows) |row| {
            const lhs: f32 = @bitCast(self.registers[@backingInt(instruction.b) + row]);
            self.registers[@backingInt(instruction.a) + column * dimensions.rows + row] = @bitCast(lhs * rhs);
        }
    }
}

fn transpose(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    const dimensions = bc.MatrixDimensions.decode(instruction.immediate);
    if (dimensions.rows == 0 or dimensions.inner != 0 or dimensions.columns == 0 or
        instruction.c != .invalid_register or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;

    const components = try componentProduct(dimensions.rows, dimensions.columns);
    if (instruction.components != components)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, components);
    try self.validateRegisterRange(instruction.b, components);

    for (0..dimensions.columns) |column| {
        for (0..dimensions.rows) |row| {
            const source_index = column * dimensions.rows + row;
            const destination_index = row * dimensions.columns + column;
            self.registers[@backingInt(instruction.a) + destination_index] = self.registers[@backingInt(instruction.b) + source_index];
        }
    }
}

fn matrixTimesVector(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    const dimensions = bc.MatrixDimensions.decode(instruction.immediate);
    if (dimensions.rows == 0 or dimensions.inner == 0 or dimensions.columns != 1 or instruction.components != dimensions.rows or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;

    const matrix_components = try componentProduct(dimensions.rows, dimensions.inner);
    try self.validateRegisterRange(instruction.a, dimensions.rows);
    try self.validateRegisterRange(instruction.b, matrix_components);
    try self.validateRegisterRange(instruction.c, dimensions.inner);

    for (0..dimensions.rows) |row| {
        var sum: f32 = 0.0;
        for (0..dimensions.inner) |column| {
            const matrix: f32 = @bitCast(self.registers[@backingInt(instruction.b) + column * dimensions.rows + row]);
            const vector: f32 = @bitCast(self.registers[@backingInt(instruction.c) + column]);
            sum += matrix * vector;
        }
        self.registers[@backingInt(instruction.a) + row] = @bitCast(sum);
    }
}

fn vectorTimesMatrix(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    const dimensions = bc.MatrixDimensions.decode(instruction.immediate);
    if (dimensions.rows != 1 or dimensions.inner == 0 or dimensions.columns == 0 or instruction.components != dimensions.columns or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;

    const matrix_components = try componentProduct(dimensions.inner, dimensions.columns);
    try self.validateRegisterRange(instruction.a, dimensions.columns);
    try self.validateRegisterRange(instruction.b, dimensions.inner);
    try self.validateRegisterRange(instruction.c, matrix_components);

    for (0..dimensions.columns) |column| {
        var sum: f32 = 0.0;
        for (0..dimensions.inner) |row| {
            const vector: f32 = @bitCast(self.registers[@backingInt(instruction.b) + row]);
            const matrix: f32 = @bitCast(self.registers[@backingInt(instruction.c) + column * dimensions.inner + row]);
            sum += vector * matrix;
        }
        self.registers[@backingInt(instruction.a) + column] = @bitCast(sum);
    }
}

fn matrixTimesMatrix(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    const dimensions = bc.MatrixDimensions.decode(instruction.immediate);
    if (dimensions.rows == 0 or dimensions.inner == 0 or dimensions.columns == 0 or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;

    const lhs_components = try componentProduct(dimensions.rows, dimensions.inner);
    const rhs_components = try componentProduct(dimensions.inner, dimensions.columns);
    const result_components = try componentProduct(dimensions.rows, dimensions.columns);
    if (instruction.components != result_components)
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterRange(instruction.a, result_components);
    try self.validateRegisterRange(instruction.b, lhs_components);
    try self.validateRegisterRange(instruction.c, rhs_components);

    for (0..dimensions.columns) |column| {
        for (0..dimensions.rows) |row| {
            var sum: f32 = 0.0;
            for (0..dimensions.inner) |inner| {
                const lhs: f32 = @bitCast(self.registers[@backingInt(instruction.b) + inner * dimensions.rows + row]);
                const rhs: f32 = @bitCast(self.registers[@backingInt(instruction.c) + column * dimensions.inner + inner]);
                sum += lhs * rhs;
            }
            self.registers[@backingInt(instruction.a) + column * dimensions.rows + row] = @bitCast(sum);
        }
    }
}

fn componentProduct(lhs: u8, rhs: u8) RuntimeError!usize {
    return std.math.mul(usize, lhs, rhs) catch RuntimeError.InvalidBytecode;
}

fn compareInt(self: *Self, instruction: bc.Instruction, comptime operation: CompareInt) void {
    for (0..instruction.components) |component| {
        const lhs = self.registers[@backingInt(instruction.b) + component];
        const rhs = self.registers[@backingInt(instruction.c) + component];

        self.registers[@backingInt(instruction.a) + component] = @intFromBool(switch (operation) {
            .equal => lhs == rhs,
            .not_equal => lhs != rhs,
            .unsigned_less => lhs < rhs,
            .signed_less => @as(i32, @bitCast(lhs)) < @as(i32, @bitCast(rhs)),
        });
    }
}

fn compareFloat(self: *Self, instruction: bc.Instruction, comptime operation: CompareFloat) void {
    for (0..instruction.components) |component| {
        const lhs: f32 = @bitCast(self.registers[@backingInt(instruction.b) + component]);
        const rhs: f32 = @bitCast(self.registers[@backingInt(instruction.c) + component]);

        const unordered = std.math.isNan(lhs) or std.math.isNan(rhs);
        self.registers[@backingInt(instruction.a) + component] = @intFromBool(switch (operation) {
            .ordered_equal => !unordered and lhs == rhs,
            .unordered_equal => unordered or lhs == rhs,
            .ordered_not_equal => !unordered and lhs != rhs,
            .unordered_not_equal => unordered or lhs != rhs,
            .ordered_less => !unordered and lhs < rhs,
            .ordered_less_equal => !unordered and lhs <= rhs,
            .unordered_less => unordered or lhs < rhs,
        });
    }
}

fn select(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.components == 0 or instruction.immediate > 1)
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, if (instruction.immediate == 1) instruction.components else 1);
    try self.validateRegisterRange(instruction.c, instruction.components);
    try self.validateRegisterRange(instruction.d, instruction.components);

    for (0..instruction.components) |component| {
        const condition_component = if (instruction.immediate == 1) component else 0;
        const selected = if (self.registers[@as(usize, @backingInt(instruction.b)) + condition_component] != 0)
            @backingInt(instruction.c)
        else
            @backingInt(instruction.d);
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = self.registers[@as(usize, selected) + component];
    }
}

fn loadBuffer(self: *Self, program: *const Program, resource_buffers: []const ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const resource = try self.selectBufferResource(program, instruction);
    const buffer = try resourceBuffer(program, resource_buffers, resource);
    const bytes = try self.bufferRange(buffer, instruction);
    self.loadWords(instruction, bytes);
}

fn loadPushConstant(self: *Self, push_constants: []const u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const bytes = try self.pushConstantRange(push_constants, instruction);
    self.loadWords(instruction, bytes);
}

fn loadWords(self: *Self, instruction: bc.Instruction, bytes: []const u8) void {
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(u32);
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = std.mem.readInt(u32, bytes[offset..][0..@sizeOf(u32)], .little);
    }
}

fn storeBuffer(self: *const Self, program: *const Program, resource_buffers: []const ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const resource = try self.selectBufferResource(program, instruction);
    const buffer = try resourceBuffer(program, resource_buffers, resource);
    const bytes = try self.bufferRange(buffer, instruction);
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(u32);
        std.mem.writeInt(u32, bytes[offset..][0..@sizeOf(u32)], self.registers[@as(usize, @backingInt(instruction.a)) + component], .little);
    }
}

fn imageRead(self: *Self, program: *const Program, resource_images: []const ?*SoftImageView, instruction: bc.Instruction) RuntimeError!void {
    try self.validateImageInstruction(instruction);
    const view = try resourceImage(program, resource_images, instruction.immediate);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const pixel = image.readInt4(imageOffset(self, instruction), imageSubresource(view), view.interface.format) catch return RuntimeError.InvalidResource;
    const components: [4]u32 = @bitCast(pixel);
    @memcpy(self.registers[@backingInt(instruction.a)..][0..4], &components);
}

fn imageReadFloat(self: *Self, program: *const Program, resource_images: []const ?*SoftImageView, instruction: bc.Instruction) RuntimeError!void {
    try self.validateImageInstruction(instruction);
    const view = try resourceImage(program, resource_images, instruction.immediate);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const pixel = image.readFloat4(imageOffset(self, instruction), imageSubresource(view), view.interface.format) catch return RuntimeError.InvalidResource;
    const components: [4]u32 = @bitCast(pixel);
    @memcpy(self.registers[@backingInt(instruction.a)..][0..4], &components);
}

fn imageGather(
    self: *Self,
    program: *const Program,
    resource_images: []const ?*SoftImageView,
    resource_samplers: []const ?*SoftSampler,
    instruction: bc.Instruction,
) RuntimeError!void {
    if (instruction.components != 4 or instruction.immediate >= program.image_sampler_pairs.len or instruction.c == .invalid_register or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterSpan(instruction);

    const pair = program.image_sampler_pairs[instruction.immediate];
    if (pair.dimension != .two_d or pair.arrayed)
        return RuntimeError.InvalidBytecode;

    const coordinate_base: usize = @backingInt(instruction.b);
    const coordinate_end = std.math.add(usize, coordinate_base, 2) catch return RuntimeError.InvalidBytecode;
    if (coordinate_end > self.registers.len or @backingInt(instruction.c) >= self.registers.len)
        return RuntimeError.InvalidBytecode;

    const component: usize = self.registers[@backingInt(instruction.c)];
    if (component >= 4)
        return RuntimeError.InvalidResource;

    const view = try sampledImage(program, resource_images, pair.image);
    const sampler = try resourceSampler(program, resource_samplers, pair.sampler);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const extent = image.getMipLevelExtent(view.interface.subresource_range.base_mip_level);
    if (extent.width == 0 or extent.height == 0)
        return RuntimeError.InvalidResource;

    const x: f32 = @bitCast(self.registers[coordinate_base]);
    const y: f32 = @bitCast(self.registers[coordinate_base + 1]);
    const width: f32 = @floatFromInt(extent.width);
    const height: f32 = @floatFromInt(extent.height);
    const base_x: i32 = @intFromFloat(@floor(x * width - 0.5));
    const base_y: i32 = @intFromFloat(@floor(y * height - 0.5));
    const gather_x = [4]i32{ base_x, base_x + 1, base_x + 1, base_x };
    const gather_y = [4]i32{ base_y + 1, base_y + 1, base_y, base_y };

    var components: [4]u32 = undefined;
    for (0..4) |i| {
        const sample_x = (@as(f32, @floatFromInt(gather_x[i])) + 0.5) / width;
        const sample_y = (@as(f32, @floatFromInt(gather_y[i])) + 0.5) / height;
        components[i] = switch (pair.destination_kind) {
            .floating => blk: {
                const texel: [4]f32 = @bitCast(SoftSampler.sampleImageFloat4(image, view, sampler, .@"2D", sample_x, sample_y, 0.0, 0.0, .{}) catch return RuntimeError.InvalidResource);
                break :blk @bitCast(texel[component]);
            },
            .signed_integer, .unsigned_integer => blk: {
                const texel: [4]u32 = @bitCast(SoftSampler.sampleImageInt4(image, view, sampler, .@"2D", sample_x, sample_y, 0.0, 0.0, .{}) catch return RuntimeError.InvalidResource);
                break :blk texel[component];
            },
            .boolean, .mixed => return RuntimeError.InvalidBytecode,
        };
    }
    @memcpy(self.registers[@backingInt(instruction.a)..][0..4], &components);
}

fn imageSample(
    self: *Self,
    program: *const Program,
    resource_images: []const ?*SoftImageView,
    resource_samplers: []const ?*SoftSampler,
    instruction: bc.Instruction,
    explicit_lod: bool,
) RuntimeError!void {
    if (instruction.components != 4 or instruction.immediate >= program.image_sampler_pairs.len)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterSpan(instruction);

    const pair = program.image_sampler_pairs[instruction.immediate];
    if (pair.dimension == .cube and pair.arrayed)
        return RuntimeError.InvalidBytecode;

    const coordinate_count = Program.imageCoordinateComponents(pair.dimension, pair.arrayed);
    const coordinate_end = std.math.add(usize, @backingInt(instruction.b), coordinate_count) catch return RuntimeError.InvalidBytecode;
    if (coordinate_end > self.registers.len)
        return RuntimeError.InvalidBytecode;

    const lod: ?f32 = if (explicit_lod) blk: {
        if (instruction.c == .invalid_register or @backingInt(instruction.c) >= self.registers.len)
            return RuntimeError.InvalidBytecode;
        break :blk @bitCast(self.registers[@backingInt(instruction.c)]);
    } else blk: {
        if (instruction.c != .invalid_register)
            return RuntimeError.InvalidBytecode;
        break :blk null;
    };

    const view = try sampledImage(program, resource_images, pair.image);
    const sampler = try resourceSampler(program, resource_samplers, pair.sampler);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const coordinate_base: usize = @backingInt(instruction.b);
    const x: f32 = @bitCast(self.registers[coordinate_base]);
    const y: f32 = if (coordinate_count >= 2) @bitCast(self.registers[coordinate_base + 1]) else 0.0;
    const z: f32 = if (coordinate_count >= 3) @bitCast(self.registers[coordinate_base + 2]) else 0.0;
    const dimension: spv.SpvDim = switch (pair.dimension) {
        .one_d => .@"1D",
        .two_d => .@"2D",
        .three_d => .@"3D",
        .cube => .Cube,
    };

    const components: [4]u32 = switch (pair.destination_kind) {
        .floating => @bitCast(SoftSampler.sampleImageFloat4(image, view, sampler, dimension, x, y, z, lod, .{}) catch return RuntimeError.InvalidResource),
        .signed_integer, .unsigned_integer => @bitCast(SoftSampler.sampleImageInt4(image, view, sampler, dimension, x, y, z, lod, .{}) catch return RuntimeError.InvalidResource),
        .boolean, .mixed => return RuntimeError.InvalidBytecode,
    };
    @memcpy(self.registers[@backingInt(instruction.a)..][0..4], &components);
}

fn imageWrite(self: *const Self, program: *const Program, resource_images: []const ?*SoftImageView, instruction: bc.Instruction) RuntimeError!void {
    try self.validateImageInstruction(instruction);
    const view = try resourceImage(program, resource_images, instruction.immediate);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const components: [4]u32 = self.registers[@backingInt(instruction.a)..][0..4].*;
    const pixel: @Vector(4, u32) = @bitCast(components);
    image.writeInt4(imageOffset(self, instruction), imageSubresource(view), view.interface.format, pixel) catch return RuntimeError.InvalidResource;
}

fn imageWriteFloat(self: *const Self, program: *const Program, resource_images: []const ?*SoftImageView, instruction: bc.Instruction) RuntimeError!void {
    try self.validateImageInstruction(instruction);
    const view = try resourceImage(program, resource_images, instruction.immediate);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const components: [4]u32 = self.registers[@backingInt(instruction.a)..][0..4].*;
    const pixel: @Vector(4, f32) = @bitCast(components);
    image.writeFloat4(imageOffset(self, instruction), imageSubresource(view), view.interface.format, pixel) catch return RuntimeError.InvalidResource;
}

fn validateImageInstruction(self: *const Self, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.components != 4)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterSpan(instruction);
    const coordinate_end = std.math.add(usize, @backingInt(instruction.b), 2) catch return RuntimeError.InvalidBytecode;
    if (coordinate_end > self.registers.len)
        return RuntimeError.InvalidBytecode;
}

fn imageOffset(self: *const Self, instruction: bc.Instruction) vk.Offset3D {
    return .{
        .x = @bitCast(self.registers[@backingInt(instruction.b)]),
        .y = @bitCast(self.registers[@as(usize, @backingInt(instruction.b)) + 1]),
        .z = 0,
    };
}

fn imageSubresource(view: *const SoftImageView) vk.ImageSubresource {
    const range = view.interface.subresource_range;
    return .{
        .aspect_mask = range.aspect_mask,
        .mip_level = range.base_mip_level,
        .array_layer = range.base_array_layer,
    };
}

fn loadWorkgroup(self: *Self, program: *const Program, optional_memory: ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const bytes = try self.workgroupRange(program, optional_memory, instruction);
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(u32);
        self.registers[@as(usize, @backingInt(instruction.a)) + component] = std.mem.readInt(u32, bytes[offset..][0..@sizeOf(u32)], .little);
    }
}

fn storeWorkgroup(self: *const Self, program: *const Program, optional_memory: ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const bytes = try self.workgroupRange(program, optional_memory, instruction);
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(u32);
        std.mem.writeInt(u32, bytes[offset..][0..@sizeOf(u32)], self.registers[@as(usize, @backingInt(instruction.a)) + component], .little);
    }
}

fn workgroupRange(self: *const Self, program: *const Program, optional_memory: ?[]u8, instruction: bc.Instruction) RuntimeError![]u8 {
    const memory = optional_memory orelse return RuntimeError.WorkgroupMemoryUnavailable;

    if (@backingInt(instruction.b) >= self.registers.len)
        return RuntimeError.InvalidBytecode;

    const variable = ids.WorkgroupVariableId.fromIndex(instruction.immediate);
    const binding = program.workgroupBinding(variable) orelse return RuntimeError.InvalidBytecode;
    const relative_offset: usize = self.registers[@backingInt(instruction.b)];
    const byte_count = std.math.mul(usize, instruction.components, @sizeOf(u32)) catch return RuntimeError.BufferOutOfBounds;
    const relative_end = std.math.add(usize, relative_offset, byte_count) catch return RuntimeError.BufferOutOfBounds;

    if (relative_end > @as(usize, binding.byte_size))
        return RuntimeError.BufferOutOfBounds;

    const start = std.math.add(usize, @as(usize, binding.byte_offset), relative_offset) catch return RuntimeError.BufferOutOfBounds;
    const end = std.math.add(usize, start, byte_count) catch return RuntimeError.BufferOutOfBounds;

    if (end > memory.len)
        return RuntimeError.BufferOutOfBounds;

    return memory[start..end];
}

fn validateRegisterSpan(self: *const Self, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, instruction.components);
}

fn validateUnaryInstruction(self: *const Self, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.components == 0 or instruction.c != .invalid_register or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
}

fn validateRegisterRange(self: *const Self, base: bc.Register, components: usize) RuntimeError!void {
    const register_end = std.math.add(usize, @backingInt(base), components) catch return RuntimeError.InvalidBytecode;
    if (register_end > self.registers.len)
        return RuntimeError.InvalidBytecode;
}

fn bufferRange(self: *const Self, buffer: []u8, instruction: bc.Instruction) RuntimeError![]u8 {
    const byte_offset, const end = try self.memoryRange(buffer.len, instruction);
    return buffer[byte_offset..end];
}

fn pushConstantRange(self: *const Self, push_constants: []const u8, instruction: bc.Instruction) RuntimeError![]const u8 {
    const byte_offset, const end = try self.memoryRange(push_constants.len, instruction);
    return push_constants[byte_offset..end];
}

fn memoryRange(self: *const Self, memory_len: usize, instruction: bc.Instruction) RuntimeError!struct { usize, usize } {
    if (@backingInt(instruction.b) >= self.registers.len)
        return RuntimeError.InvalidBytecode;

    const byte_offset: usize = self.registers[@backingInt(instruction.b)];
    const byte_count = std.math.mul(usize, instruction.components, @sizeOf(u32)) catch return RuntimeError.BufferOutOfBounds;
    const end = std.math.add(usize, byte_offset, byte_count) catch return RuntimeError.BufferOutOfBounds;
    if (end > memory_len)
        return RuntimeError.BufferOutOfBounds;
    return .{ byte_offset, end };
}

fn selectBufferResource(self: *const Self, program: *const Program, instruction: bc.Instruction) RuntimeError!u32 {
    if (instruction.c == .invalid_register)
        return instruction.immediate;

    if (@backingInt(instruction.c) >= self.registers.len)
        return RuntimeError.InvalidBytecode;
    if (instruction.immediate >= program.descriptor_arrays.len)
        return RuntimeError.InvalidBytecode;

    const array_element = self.registers[@backingInt(instruction.c)];
    for (program.descriptor_arrays[instruction.immediate].candidates) |candidate| {
        if (candidate.array_element == array_element)
            return @backingInt(candidate.resource);
    }

    return RuntimeError.InvalidResource;
}

fn resourceBuffer(program: *const Program, resource_buffers: []const ?[]u8, resource_index: u32) RuntimeError![]u8 {
    const resource = ids.ResourceId.fromIndex(resource_index);
    _ = program.resourceBinding(resource) orelse return RuntimeError.InvalidResource;
    if (resource.index() >= resource_buffers.len)
        return RuntimeError.ResourceNotBound;
    return resource_buffers[resource.index()] orelse RuntimeError.ResourceNotBound;
}

fn resourceImage(program: *const Program, resource_images: []const ?*SoftImageView, resource_index: u32) RuntimeError!*SoftImageView {
    const resource = ids.ResourceId.fromIndex(resource_index);
    const binding = program.resourceBinding(resource) orelse return RuntimeError.InvalidResource;
    if (binding.kind != .storage_image)
        return RuntimeError.InvalidResource;
    if (resource.index() >= resource_images.len)
        return RuntimeError.ResourceNotBound;
    return resource_images[resource.index()] orelse RuntimeError.ResourceNotBound;
}

fn sampledImage(program: *const Program, resource_images: []const ?*SoftImageView, resource: ids.ResourceId) RuntimeError!*SoftImageView {
    const binding = program.resourceBinding(resource) orelse return RuntimeError.InvalidResource;
    if (binding.kind != .sampled_image)
        return RuntimeError.InvalidResource;
    if (resource.index() >= resource_images.len)
        return RuntimeError.ResourceNotBound;
    return resource_images[resource.index()] orelse RuntimeError.ResourceNotBound;
}

fn resourceSampler(program: *const Program, resource_samplers: []const ?*SoftSampler, resource: ids.ResourceId) RuntimeError!*SoftSampler {
    const binding = program.resourceBinding(resource) orelse return RuntimeError.InvalidResource;
    if (binding.kind != .sampler)
        return RuntimeError.InvalidResource;
    if (resource.index() >= resource_samplers.len)
        return RuntimeError.ResourceNotBound;
    return resource_samplers[resource.index()] orelse RuntimeError.ResourceNotBound;
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
            self.scratch[@as(usize, @backingInt(item.scratch_base)) + component] = self.registers[@as(usize, @backingInt(item.source)) + component];
        }
    }
    for (copies) |item| {
        for (0..item.components) |component| {
            self.registers[@as(usize, @backingInt(item.destination)) + component] = self.scratch[@as(usize, @backingInt(item.scratch_base)) + component];
        }
    }

    if (edge.target_pc >= program.code.len)
        return RuntimeError.InvalidBytecode;

    return edge.target_pc;
}
