const std = @import("std");
const vk = @import("vulkan");
const format_info = @import("base").format;
const zm = @import("base").zm;
const spv = @import("spv");
const shader_ir = @import("shader_ir");
const bc = @import("bytecode.zig");
const Program = @import("Program.zig");
const simd = @import("simd.zig");
const SoftImage = @import("../SoftImage.zig");
const SoftImageView = @import("../SoftImageView.zig");
const SoftBuffer = @import("../SoftBuffer.zig");
const SoftBufferView = @import("../SoftBufferView.zig");
const blitter = @import("../device/blitter.zig");
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
    absolute,
    bit_count,
    bit_reverse,
    bitwise_not,
    logical_not,
    negate,
    sign,
};

const BinaryInt = enum {
    add,
    arithmetic_shift_right,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    logical_and,
    logical_or,
    logical_shift_right,
    multiply,
    shift_left,
    signed_divide,
    signed_max,
    signed_min,
    signed_modulo,
    subtract,
    unsigned_divide,
    unsigned_max,
    unsigned_min,
    unsigned_modulo,
};

const TernaryInt = enum {
    signed_clamp,
    unsigned_clamp,
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
    acos,
    acosh,
    asin,
    asinh,
    atan,
    atanh,
    ceil,
    cos,
    cosh,
    degrees,
    exp,
    exp2,
    floor,
    fract,
    log,
    log2,
    negate,
    radians,
    round,
    sign,
    sin,
    sinh,
    sqrt,
    tan,
    tanh,
    trunc,
};

const BinaryFloat = enum {
    add,
    atan2,
    divide,
    max,
    min,
    modulo,
    multiply,
    pow,
    remainder,
    step,
    subtract,
};

const TernaryFloat = enum {
    clamp,
    mul_add,
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

pub const Slot = bc.Slot;

pub inline fn low32(value: Slot) u32 {
    return @truncate(value);
}

pub inline fn readF32(value: Slot) f32 {
    return @bitCast(low32(value));
}

pub inline fn writeF32(value: f32) Slot {
    return @as(Slot, @as(u32, @bitCast(value)));
}

pub inline fn readI32(value: Slot) i32 {
    return @bitCast(low32(value));
}

pub inline fn writeI32(value: i32) Slot {
    return @as(Slot, @as(u32, @bitCast(value)));
}

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
    resource_texel_buffers: []const ?*SoftBufferView = &.{},
    resource_samplers: []const ?*SoftSampler = &.{},
    workgroup_memory: ?[]u8 = null,
};

const Self = @This();

pub const LaneView = struct {
    storage: []Slot,
    lane: usize,
    len: usize,

    pub inline fn at(self: LaneView, index: usize) *Slot {
        std.debug.assert(index < self.len);
        return &self.storage[index * lane_count + self.lane];
    }

    pub inline fn get(self: LaneView, index: usize) Slot {
        return self.at(index).*;
    }

    pub inline fn set(self: LaneView, index: usize, value: Slot) void {
        self.at(index).* = value;
    }

    pub fn slice(self: LaneView, start: usize, end: usize) LaneView {
        std.debug.assert(start <= end and end <= self.len);
        return .{ .storage = self.storage[start * lane_count .. end * lane_count], .lane = self.lane, .len = end - start };
    }

    pub fn fill(self: LaneView, value: Slot) void {
        for (0..self.len) |index| self.at(index).* = value;
    }
};

allocator: std.mem.Allocator,
register_backing: []Slot,
scratch_backing: []Slot,
register_count: usize,
scratch_count: usize,
registers: LaneView,
scratch: LaneView,
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
    const register_backing = try allocator.alloc(Slot, register_words);
    errdefer allocator.free(register_backing);
    const scratch_backing = try allocator.alloc(Slot, scratch_words);
    errdefer allocator.free(scratch_backing);

    @memset(register_backing, 0);
    @memset(scratch_backing, 0);

    for (program.initializers) |initializer| {
        const start = @as(usize, @backingInt(initializer.register)) * lane_count;
        @memset(register_backing[start..][0..lane_count], initializer.value);
    }

    var self: Self = .{
        .allocator = allocator,
        .register_backing = register_backing,
        .scratch_backing = scratch_backing,
        .register_count = program.register_count,
        .scratch_count = program.scratch_count,
        .registers = .{ .storage = register_backing, .lane = 0, .len = program.register_count },
        .scratch = .{ .storage = scratch_backing, .lane = 0, .len = program.scratch_count },
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
    for (program.interfaces) |optional_binding| {
        const binding = optional_binding orelse continue;
        const start = @as(usize, @backingInt(binding.span.base)) * lane_count;
        @memset(self.register_backing[start..][0 .. @as(usize, binding.span.components) * lane_count], 0);
    }
    @memset(&self.pcs, program.entry_pc);
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
    for (values, 0..) |value, component|
        lane_registers.at(@as(usize, @backingInt(binding.span.base)) + component).* = value;
}

pub fn readOutputLane(self: *const Self, program: *const Program, lane: usize, variable: ids.InterfaceVariableId, values: []u32) RuntimeError!void {
    if (lane >= lane_count)
        return RuntimeError.InvalidLane;
    const binding = program.interfaceBinding(variable) orelse return RuntimeError.InvalidInterface;
    if (binding.direction != .output)
        return RuntimeError.WrongInterfaceDirection;
    if (binding.span.components != values.len)
        return RuntimeError.WrongInterfaceType;

    const lane_registers = self.laneRegisters(lane);
    for (values, 0..) |*value, component|
        value.* = low32(lane_registers.get(@as(usize, @backingInt(binding.span.base)) + component));
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
        if (instruction.opcode.isDerivative()) {
            try self.groupDerivative(instruction, group_mask);
            self.advanceGroupPcs(group_mask);
            continue;
        }
        if (program.stage == .fragment and instruction.opcode == .image_sample_implicit_lod) {
            try self.groupImageSample(program, options, instruction, group_mask);
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

        if (program.code[pc].opcode.isDerivative() or
            (program.stage == .fragment and program.code[pc].opcode == .image_sample_implicit_lod))
        {
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

pub fn laneRegisters(self: *const Self, lane: usize) LaneView {
    std.debug.assert(lane < lane_count);
    return .{ .storage = self.register_backing, .lane = lane, .len = self.register_count };
}

pub fn laneScratch(self: *const Self, lane: usize) LaneView {
    std.debug.assert(lane < lane_count);
    return .{ .storage = self.scratch_backing, .lane = lane, .len = self.scratch_count };
}

fn selectLane(self: *Self, lane: Lane) void {
    self.current_lane = lane;
    self.registers = self.laneRegisters(lane);
    self.scratch = self.laneScratch(lane);
}

fn isObservable(self: *const Self) bool {
    return (self.observable_mask & laneBit(self.current_lane)) != 0;
}

const SlotVector = @Vector(lane_count, Slot);
const U32x4 = @Vector(lane_count, u32);
const I32x4 = @Vector(lane_count, i32);
const F32x4 = @Vector(lane_count, f32);

fn loadRegisterVector(self: *const Self, register: bc.Register) U32x4 {
    return @truncate(self.loadSlotVector(register));
}

fn storeRegisterVector(self: *Self, register: bc.Register, values: U32x4) void {
    self.storeSlotVector(register, @intCast(values));
}

fn storeRegisterVectorMasked(self: *Self, register: bc.Register, values: U32x4, mask: LaneMask) void {
    self.storeSlotVectorMasked(register, @intCast(values), mask);
}

fn loadSlotVector(self: *const Self, register: bc.Register) SlotVector {
    const start = @as(usize, @backingInt(register)) * lane_count;
    return self.register_backing[start..][0..lane_count].*;
}

fn storeSlotVector(self: *Self, register: bc.Register, values: SlotVector) void {
    const start = @as(usize, @backingInt(register)) * lane_count;
    self.register_backing[start..][0..lane_count].* = values;
}

fn storeSlotVectorMasked(self: *Self, register: bc.Register, values: SlotVector, mask: LaneMask) void {
    if (mask == full_lane_mask) {
        self.storeSlotVector(register, values);
        return;
    }
    self.storeSlotVector(register, @select(Slot, laneMaskVector(mask), values, self.loadSlotVector(register)));
}

fn loadScratchVector(self: *const Self, index: usize) SlotVector {
    return self.scratch_backing[index * lane_count ..][0..lane_count].*;
}

fn storeScratchVector(self: *Self, index: usize, values: SlotVector) void {
    self.scratch_backing[index * lane_count ..][0..lane_count].* = values;
}

fn storeScratchVectorMasked(self: *Self, index: usize, values: SlotVector, mask: LaneMask) void {
    if (mask == full_lane_mask) {
        self.storeScratchVector(index, values);
        return;
    }
    self.storeScratchVector(index, @select(Slot, laneMaskVector(mask), values, self.loadScratchVector(index)));
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
        .acos => try self.groupUnaryFloat(instruction, .acos, mask),
        .acosh => try self.groupUnaryFloat(instruction, .acosh, mask),
        .asin => try self.groupUnaryFloat(instruction, .asin, mask),
        .asinh => try self.groupUnaryFloat(instruction, .asinh, mask),
        .atan => try self.groupUnaryFloat(instruction, .atan, mask),
        .atanh => try self.groupUnaryFloat(instruction, .atanh, mask),
        .bitwise_and => try self.groupBinaryInt(instruction, .bitwise_and, mask),
        .bitwise_or => try self.groupBinaryInt(instruction, .bitwise_or, mask),
        .bitwise_xor => try self.groupBinaryInt(instruction, .bitwise_xor, mask),
        .ceil => try self.groupUnaryFloat(instruction, .ceil, mask),
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
        .cos => try self.groupUnaryFloat(instruction, .cos, mask),
        .cosh => try self.groupUnaryFloat(instruction, .cosh, mask),
        .degrees => try self.groupUnaryFloat(instruction, .degrees, mask),
        .exp => try self.groupUnaryFloat(instruction, .exp, mask),
        .exp2 => try self.groupUnaryFloat(instruction, .exp2, mask),
        .float_absolute => try self.groupUnaryFloat(instruction, .absolute, mask),
        .float_add => try self.groupBinaryFloat(instruction, .add, false, mask),
        .float_clamp => try self.groupTernaryFloat(instruction, .clamp, mask),
        .float_divide => try self.groupBinaryFloat(instruction, .divide, false, mask),
        .float_max => try self.groupBinaryFloat(instruction, .max, false, mask),
        .float_min => try self.groupBinaryFloat(instruction, .min, false, mask),
        .float_multiply => try self.groupBinaryFloat(instruction, .multiply, false, mask),
        .float_sign => try self.groupUnaryFloat(instruction, .sign, mask),
        .float_subtract => try self.groupBinaryFloat(instruction, .subtract, false, mask),
        .floor => try self.groupUnaryFloat(instruction, .floor, mask),
        .fract => try self.groupUnaryFloat(instruction, .fract, mask),
        .integer_absolute => try self.groupUnaryInt(instruction, .absolute, mask),
        .integer_add => try self.groupBinaryInt(instruction, .add, mask),
        .integer_multiply => try self.groupBinaryInt(instruction, .multiply, mask),
        .integer_sign => try self.groupUnaryInt(instruction, .sign, mask),
        .integer_subtract => try self.groupBinaryInt(instruction, .subtract, mask),
        .log => try self.groupUnaryFloat(instruction, .log, mask),
        .log2 => try self.groupUnaryFloat(instruction, .log2, mask),
        .logical_and => try self.groupBinaryInt(instruction, .logical_and, mask),
        .logical_or => try self.groupBinaryInt(instruction, .logical_or, mask),
        .negate_f32 => try self.groupUnaryFloat(instruction, .negate, mask),
        .pow => try self.groupBinaryFloat(instruction, .pow, false, mask),
        .radians => try self.groupUnaryFloat(instruction, .radians, mask),
        .select => try self.groupSelect(instruction, mask),
        .signed_clamp => try self.groupTernaryInt(instruction, .signed_clamp, mask),
        .sin => try self.groupUnaryFloat(instruction, .sin, mask),
        .sinh => try self.groupUnaryFloat(instruction, .sinh, mask),
        .sqrt => try self.groupUnaryFloat(instruction, .sqrt, mask),
        .tan => try self.groupUnaryFloat(instruction, .tan, mask),
        .tanh => try self.groupUnaryFloat(instruction, .tanh, mask),
        .trunc => try self.groupUnaryFloat(instruction, .trunc, mask),
        .unsigned_clamp => try self.groupTernaryInt(instruction, .unsigned_clamp, mask),
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
            self.storeScratchVectorMasked(scratch_base + component, self.loadSlotVector(@fromBackingInt(@intCast(@backingInt(item.source) + component))), mask);
    }
    for (copies) |item| {
        const scratch_base: usize = @backingInt(item.scratch_base);
        try self.validateRegisterRange(item.destination, item.components);
        for (0..item.components) |component|
            self.storeSlotVectorMasked(@fromBackingInt(@intCast(@backingInt(item.destination) + component)), self.loadScratchVector(scratch_base + component), mask);
    }
    return edge.target_pc;
}

fn groupUnaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: UnaryFloat, mask: LaneMask) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);
    for (0..instruction.components) |component| {
        const source: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component))));
        const result = switch (operation) {
            .absolute => @abs(source),
            .acos => std.math.acos(source),
            .acosh => simd.acosh(source),
            .asin => std.math.asin(source),
            .asinh => simd.asinh(source),
            .atan => std.math.atan(source),
            .atanh => simd.atanh(source),
            .ceil => @ceil(source),
            .cos => @cos(source),
            .cosh => simd.cosh(source),
            .degrees => std.math.radiansToDegrees(source),
            .exp => @exp(source),
            .exp2 => @exp2(source),
            .floor => @floor(source),
            .fract => source - @floor(source),
            .log => @log(source),
            .log2 => @log2(source),
            .negate => -source,
            .radians => std.math.degreesToRadians(source),
            .round => @round(source),
            .sign => @select(f32, source > @as(F32x4, @splat(0.0)), @as(F32x4, @splat(1.0)), @select(f32, source < @as(F32x4, @splat(0.0)), @as(F32x4, @splat(-1.0)), @as(F32x4, @splat(0.0)))),
            .sin => @sin(source),
            .sinh => simd.sinh(source),
            .sqrt => @sqrt(source),
            .tan => @tan(source),
            .tanh => simd.tanh(source),
            .trunc => @trunc(source),
        };
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), @bitCast(result), mask);
    }
}

fn groupUnaryInt(self: *Self, instruction: bc.Instruction, comptime operation: UnaryInt, mask: LaneMask) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);
    for (0..instruction.components) |component| {
        const source: U32x4 = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component)));
        const result: U32x4 = switch (operation) {
            .absolute => @abs(@as(I32x4, @bitCast(source))),
            .bit_count => @popCount(source),
            .bit_reverse => @bitReverse(source),
            .bitwise_not => ~source,
            .logical_not => @intFromBool(source == 0),
            .negate => 0 -% source,
            .sign => @bitCast(@select(
                i32,
                @as(I32x4, @bitCast(source)) > @as(I32x4, @splat(0)),
                @as(I32x4, @splat(1)),
                @select(
                    i32,
                    @as(I32x4, @bitCast(source)) < @as(I32x4, @splat(0)),
                    @as(I32x4, @splat(-1)),
                    @as(I32x4, @splat(0)),
                ),
            )),
        };
        self.storeRegisterVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), result, mask);
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

fn groupTernaryInt(self: *Self, instruction: bc.Instruction, comptime operation: TernaryInt, mask: LaneMask) RuntimeError!void {
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);
    try self.validateRegisterRange(instruction.d, instruction.components);

    for (0..instruction.components) |component| {
        const x = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component)));
        const y = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.c) + component)));
        const z = self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.d) + component)));

        const result: U32x4 = switch (operation) {
            .signed_clamp => @bitCast(std.math.clamp(@as(I32x4, @bitCast(x)), @as(I32x4, @bitCast(y)), @as(I32x4, @bitCast(z)))),
            .unsigned_clamp => std.math.clamp(x, y, z),
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

fn groupTernaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: TernaryFloat, mask: LaneMask) RuntimeError!void {
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);
    try self.validateRegisterRange(instruction.d, instruction.components);

    for (0..instruction.components) |component| {
        const x: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component))));
        const y: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.c) + component))));
        const z: F32x4 = @bitCast(self.loadRegisterVector(@fromBackingInt(@intCast(@backingInt(instruction.d) + component))));

        const result = switch (operation) {
            .clamp => std.math.clamp(x, y, z),
            .mul_add => @mulAdd(F32x4, x, y, z),
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
        self.storeSlotVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), self.loadSlotVector(@fromBackingInt(@intCast(@backingInt(instruction.b) + component))), mask);
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
        const true_value = self.loadSlotVector(@fromBackingInt(@intCast(@backingInt(instruction.c) + component)));
        const false_value = self.loadSlotVector(@fromBackingInt(@intCast(@backingInt(instruction.d) + component)));
        self.storeSlotVectorMasked(@fromBackingInt(@intCast(@backingInt(instruction.a) + component)), @select(Slot, condition, true_value, false_value), mask);
    }
}

fn executeInstruction(self: *Self, program: *const Program, options: RunOptions, instruction: bc.Instruction) RuntimeError!?LaneOutcome {
    switch (instruction.opcode) {
        .@"unreachable" => return RuntimeError.UnreachableExecuted,
        .acos => try self.unaryFloat(instruction, .acos),
        .acosh => try self.unaryFloat(instruction, .acosh),
        .all => try self.all(instruction),
        .any => try self.any(instruction),
        .arithmetic_shift_right => try self.binaryInt(instruction, .arithmetic_shift_right),
        .array_length => try self.arrayLength(program, options.resource_buffers, instruction),
        .asin => try self.unaryFloat(instruction, .asin),
        .asinh => try self.unaryFloat(instruction, .asinh),
        .atan => try self.unaryFloat(instruction, .atan),
        .atan2 => try self.binaryFloat(instruction, .atan2, false),
        .atanh => try self.unaryFloat(instruction, .atanh),
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
            self.pcs[self.current_lane] = try self.applyEdge(program, if (low32(self.registers.at(@backingInt(instruction.a)).*) != 0) branch.true_edge else branch.false_edge);
        },
        .ceil => try self.unaryFloat(instruction, .ceil),
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
        .control_barrier => return .barrier,
        .copy => self.copy(instruction),
        .cos => try self.unaryFloat(instruction, .cos),
        .cosh => try self.unaryFloat(instruction, .cosh),
        .d_pdx, .d_pdy, .fwidth => return RuntimeError.DerivativeUnavailable,
        .degrees => try self.unaryFloat(instruction, .degrees),
        .discard => return .discarded,
        .dot => try self.dot(instruction),
        .exp => try self.unaryFloat(instruction, .exp),
        .exp2 => try self.unaryFloat(instruction, .exp2),
        .float_absolute => try self.unaryFloat(instruction, .absolute),
        .float_add => try self.binaryFloat(instruction, .add, false),
        .float_clamp => try self.ternaryFloat(instruction, .clamp),
        .float_divide => try self.binaryFloat(instruction, .divide, false),
        .float_max => try self.binaryFloat(instruction, .max, false),
        .float_min => try self.binaryFloat(instruction, .min, false),
        .float_mix => try self.fMix(instruction),
        .float_modulo => try self.binaryFloat(instruction, .modulo, false),
        .float_mul_add => try self.ternaryFloat(instruction, .mul_add),
        .float_multiply => try self.binaryFloat(instruction, .multiply, false),
        .float_remainder => try self.binaryFloat(instruction, .remainder, false),
        .float_sign => try self.unaryFloat(instruction, .sign),
        .float_subtract => try self.binaryFloat(instruction, .subtract, false),
        .float_to_signed => try self.floatToInt(instruction, true),
        .float_to_unsigned => try self.floatToInt(instruction, false),
        .floor => try self.unaryFloat(instruction, .floor),
        .fract => try self.unaryFloat(instruction, .fract),
        .image_fetch => try self.imageRead(program, options, instruction, false, true),
        .image_fetch_float => try self.imageRead(program, options, instruction, true, true),
        .image_gather => try self.imageGather(program, options.resource_images, options.resource_samplers, instruction),
        .image_read => try self.imageRead(program, options, instruction, false, false),
        .image_read_float => try self.imageRead(program, options, instruction, true, false),
        .image_sample_explicit_lod => try self.imageSample(program, options.resource_images, options.resource_samplers, instruction, true, null),
        .image_sample_implicit_lod => try self.imageSample(program, options.resource_images, options.resource_samplers, instruction, false, null),
        .image_size_query_lod => try self.imageSizeQueryLod(program, options.resource_images, instruction),
        .image_write => if (self.isObservable()) try self.imageWrite(program, options, instruction, false),
        .image_write_float => if (self.isObservable()) try self.imageWrite(program, options, instruction, true),
        .integer_absolute => try self.unaryInt(instruction, .absolute),
        .integer_add => try self.binaryInt(instruction, .add),
        .integer_add_carry => try self.extendedInt(instruction, .add_carry),
        .integer_multiply => try self.binaryInt(instruction, .multiply),
        .integer_sign => try self.unaryInt(instruction, .sign),
        .integer_subtract => try self.binaryInt(instruction, .subtract),
        .integer_subtract_borrow => try self.extendedInt(instruction, .subtract_borrow),
        .is_inf => try self.classifyFloat(instruction, .infinite),
        .is_nan => try self.classifyFloat(instruction, .nan),
        .jump_edge => self.pcs[self.current_lane] = try self.applyEdge(program, instruction.immediate),
        .length => try self.vectorLength(instruction),
        .load_buffer => try self.loadBuffer(program, options.resource_buffers, instruction),
        .load_push_constant => try self.loadPushConstant(options.push_constants, instruction),
        .load_workgroup => try self.loadWorkgroup(program, options.workgroup_memory, instruction),
        .log => try self.unaryFloat(instruction, .log),
        .log2 => try self.unaryFloat(instruction, .log2),
        .logical_and => try self.binaryInt(instruction, .logical_and),
        .logical_not => try self.unaryInt(instruction, .logical_not),
        .logical_or => try self.binaryInt(instruction, .logical_or),
        .logical_shift_right => try self.binaryInt(instruction, .logical_shift_right),
        .matrix_times_matrix => try self.matrixTimesMatrix(instruction),
        .matrix_times_scalar => try self.binaryFloat(instruction, .multiply, true),
        .matrix_times_vector => try self.matrixTimesVector(instruction),
        .negate_f32 => try self.unaryFloat(instruction, .negate),
        .negate_i32 => try self.unaryInt(instruction, .negate),
        .normalize => try self.normalize(instruction),
        .outer_product => try self.outerProduct(instruction),
        .pow => try self.binaryFloat(instruction, .pow, false),
        .radians => try self.unaryFloat(instruction, .radians),
        .return_void => return .returned,
        .round => try self.unaryFloat(instruction, .round),
        .select => try self.select(instruction),
        .shift_left => try self.binaryInt(instruction, .shift_left),
        .signed_clamp => try self.ternaryInt(instruction, .signed_clamp),
        .signed_divide => try self.binaryInt(instruction, .signed_divide),
        .signed_max => try self.binaryInt(instruction, .signed_max),
        .signed_min => try self.binaryInt(instruction, .signed_min),
        .signed_modulo => try self.binaryInt(instruction, .signed_modulo),
        .signed_multiply_extended => try self.extendedInt(instruction, .signed_multiply),
        .signed_to_float => try self.intToFloat(instruction, true),
        .sin => try self.unaryFloat(instruction, .sin),
        .sinh => try self.unaryFloat(instruction, .sinh),
        .smooth_step => try self.smoothStep(instruction),
        .sqrt => try self.unaryFloat(instruction, .sqrt),
        .step => try self.binaryFloat(instruction, .step, false),
        .store_buffer => if (self.isObservable()) try self.storeBuffer(program, options.resource_buffers, instruction),
        .store_workgroup => if (self.isObservable()) try self.storeWorkgroup(program, options.workgroup_memory, instruction),
        .tan => try self.unaryFloat(instruction, .tan),
        .tanh => try self.unaryFloat(instruction, .tanh),
        .transpose => try self.transpose(instruction),
        .trunc => try self.unaryFloat(instruction, .trunc),
        .unsigned_clamp => try self.ternaryInt(instruction, .unsigned_clamp),
        .unsigned_divide => try self.binaryInt(instruction, .unsigned_divide),
        .unsigned_max => try self.binaryInt(instruction, .unsigned_max),
        .unsigned_min => try self.binaryInt(instruction, .unsigned_min),
        .unsigned_modulo => try self.binaryInt(instruction, .unsigned_modulo),
        .unsigned_multiply_extended => try self.extendedInt(instruction, .unsigned_multiply),
        .unsigned_to_float => try self.intToFloat(instruction, false),
        .vector_extract_dynamic => try self.vectorExtractDynamic(instruction),
        .vector_times_matrix => try self.vectorTimesMatrix(instruction),
        .vector_times_scalar => try self.binaryFloat(instruction, .multiply, true),
    }
    return null;
}

fn all(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    self.registers.at(@backingInt(instruction.a)).* = blk: {
        for (0..instruction.components) |component| {
            if (low32(self.registers.at(@backingInt(instruction.b) + component).*) == 0)
                break :blk 0;
        }
        break :blk 1;
    };
}

fn any(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    self.registers.at(@backingInt(instruction.a)).* = blk: {
        for (0..instruction.components) |component| {
            if (low32(self.registers.at(@backingInt(instruction.b) + component).*) != 0)
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
    const byte_offset: usize = low32(self.registers.at(@backingInt(instruction.b)).*);

    if (byte_offset > buffer.len)
        return RuntimeError.BufferOutOfBounds;

    const byte_length = buffer.len - byte_offset;
    const element_count = byte_length / metadata.stride;

    self.registers.at(@backingInt(instruction.a)).* = std.math.cast(u32, element_count) orelse return RuntimeError.IntegerOverflow;
}

fn copy(self: *Self, instruction: bc.Instruction) void {
    for (0..instruction.components) |component|
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*;
}

fn unaryInt(self: *Self, instruction: bc.Instruction, comptime operation: UnaryInt) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);

    for (0..instruction.components) |component| {
        const value = low32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const result: u32 = switch (operation) {
            .absolute => @abs(@as(i32, @bitCast(value))),
            .bit_count => @popCount(value),
            .bit_reverse => @bitReverse(value),
            .bitwise_not => ~value,
            .logical_not => @intFromBool(value == 0),
            .negate => 0 -% value,
            .sign => @bitCast(@as(i32, if (@as(i32, @bitCast(value)) > 0) 1 else if (@as(i32, @bitCast(value)) < 0) -1 else 0)),
        };
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = result;
    }
}

fn bitFieldExtract(self: *Self, instruction: bc.Instruction, comptime signed: bool) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, 1);
    try self.validateRegisterRange(instruction.d, 1);

    const bit_offset = low32(self.registers.at(@backingInt(instruction.c)).*);
    const count = low32(self.registers.at(@backingInt(instruction.d)).*);
    const valid_range = validBitFieldRange(bit_offset, count);

    for (0..instruction.components) |component| {
        const value = low32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const result: u32 = if (!valid_range or count == 0)
            0
        else blk: {
            const shifted = value >> @intCast(bit_offset);
            const extracted = shifted & bitMask(count);
            if (!signed or count == 32)
                break :blk extracted;

            const sign_shift: u5 = @intCast(32 - count);
            break :blk @as(u32, @bitCast(@as(i32, @bitCast(extracted << sign_shift)) >> sign_shift));
        };
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = result;
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

    const bit_offset = low32(self.registers.at(@backingInt(instruction.d)).*);
    const count = low32(self.registers.at(@backingInt(count_register)).*);
    const valid_range = validBitFieldRange(bit_offset, count);

    for (0..instruction.components) |component| {
        const base = low32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const insert = low32(self.registers.at(@as(usize, @backingInt(instruction.c)) + component).*);
        const result: u32 = if (!valid_range or count == 0)
            base
        else blk: {
            const field_mask = bitMask(count) << @intCast(bit_offset);
            break :blk (base & ~field_mask) | ((insert << @intCast(bit_offset)) & field_mask);
        };
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = result;
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
        const value: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const result = switch (operation) {
            .absolute => @abs(value),
            .acos => std.math.acos(value),
            .acosh => std.math.acosh(value),
            .asin => std.math.asin(value),
            .asinh => std.math.asinh(value),
            .atan => std.math.atan(value),
            .atanh => std.math.atanh(value),
            .ceil => @ceil(value),
            .cos => @cos(value),
            .cosh => (@exp(value) + @exp(-value)) / 2, // std.math.cosh is not precise enough for Vulkan CTS
            .degrees => std.math.radiansToDegrees(value),
            .exp => @exp(value),
            .exp2 => @exp2(value),
            .floor => @floor(value),
            .fract => value - @floor(value),
            .log => @log(value),
            .log2 => @log2(value),
            .negate => -value,
            .radians => std.math.degreesToRadians(value),
            .round => @round(value),
            .sign => if (value > 0.0) @as(f32, 1.0) else if (value < 0.0) @as(f32, -1.0) else @as(f32, 0.0),
            .sin => @sin(value),
            .sinh => (@exp(value) - @exp(-value)) / 2, // std.math.sinh is not precise enough for Vulkan CTS
            .sqrt => @sqrt(value),
            .tan => @tan(value),
            .tanh => std.math.tanh(value),
            .trunc => @trunc(value),
        };
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = writeF32(result);
    }
}

fn groupDerivative(self: *Self, instruction: bc.Instruction, mask: LaneMask) RuntimeError!void {
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
        for (0..lane_count) |lane| {
            result[lane] = switch (instruction.opcode) {
                .d_pdx => values[lane | 1] - values[lane & ~@as(usize, 1)],
                .d_pdy => values[lane | 2] - values[lane & ~@as(usize, 2)],
                .fwidth => @abs(values[lane ^ 1] - values[lane]) + @abs(values[lane ^ 2] - values[lane]),
                else => return RuntimeError.InvalidBytecode,
            };
        }
        self.storeRegisterVectorMasked(destination, @bitCast(result), mask);
    }
}

fn vectorLength(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, 1);
    try self.validateRegisterRange(instruction.b, instruction.components);

    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;

    const source = self.registers.slice(@backingInt(instruction.b), @as(usize, @backingInt(instruction.b)) + instruction.components);
    var magnitude: f32 = 0;

    if (instruction.components == 1) {
        magnitude = @abs(readF32(source.get(0)));
    } else {
        for (0..source.len) |component| {
            const value: f32 = readF32(source.get(component));
            magnitude += value * value;
        }
        magnitude = @sqrt(magnitude);
    }
    self.registers.at(@backingInt(instruction.a)).* = writeF32(magnitude);
}

fn vectorExtractDynamic(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterRange(instruction.a, 1);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, 1);
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;

    const index = low32(self.registers.at(@backingInt(instruction.c)).*);
    self.registers.at(@backingInt(instruction.a)).* = if (index < instruction.components)
        self.registers.at(@as(usize, @backingInt(instruction.b)) + index).*
    else
        0;
}

fn normalize(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);

    var squared_length: f32 = 0.0;
    for (0..instruction.components) |component| {
        const value: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        squared_length += value * value;
    }
    const length = @sqrt(squared_length);
    for (0..instruction.components) |component| {
        const value: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = writeF32(value / length);
    }
}

fn classifyFloat(self: *Self, instruction: bc.Instruction, comptime classification: FloatClassification) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);
    for (0..instruction.components) |component| {
        const bits = self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*;
        const result = switch (instruction.scalar_bits) {
            16 => classifyFloatBits(f16, @as(u16, @truncate(bits)), classification),
            32 => classifyFloatBits(f32, low32(bits), classification),
            64 => classifyFloatBits(f64, bits, classification),
            else => return RuntimeError.InvalidBytecode,
        };
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = @intFromBool(result);
    }
}

fn classifyFloatBits(comptime Float: type, bits: anytype, comptime classification: FloatClassification) bool {
    const value: Float = @bitCast(bits);
    return switch (classification) {
        .infinite => std.math.isInf(value),
        .nan => std.math.isNan(value),
    };
}

fn intToFloat(self: *Self, instruction: bc.Instruction, comptime signed: bool) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);

    for (0..instruction.components) |component| {
        const source = low32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const converted: f32 = if (signed)
            @floatFromInt(@as(i32, @bitCast(source)))
        else
            @floatFromInt(source);
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = writeF32(converted);
    }
}

fn floatToInt(self: *Self, instruction: bc.Instruction, comptime signed: bool) RuntimeError!void {
    try self.validateUnaryInstruction(instruction);

    for (0..instruction.components) |component| {
        const source: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = if (signed)
            writeI32(std.math.lossyCast(i32, source))
        else
            std.math.lossyCast(u32, source);
    }
}

fn binaryInt(self: *Self, instruction: bc.Instruction, comptime operation: BinaryInt) RuntimeError!void {
    for (0..instruction.components) |component| {
        const lhs = low32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const rhs = low32(self.registers.at(@as(usize, @backingInt(instruction.c)) + component).*);

        const result: u32 = switch (operation) {
            .add => lhs +% rhs,
            .arithmetic_shift_right => if (rhs >= 32) return RuntimeError.ShiftOutOfRange else @bitCast(@as(i32, @bitCast(lhs)) >> @intCast(rhs)),
            .bitwise_and => lhs & rhs,
            .bitwise_or => lhs | rhs,
            .bitwise_xor => lhs ^ rhs,
            .logical_and => @intFromBool(lhs != 0 and rhs != 0),
            .logical_or => @intFromBool(lhs != 0 or rhs != 0),
            .logical_shift_right => if (rhs >= 32) return RuntimeError.ShiftOutOfRange else lhs >> @intCast(rhs),
            .multiply => lhs *% rhs,
            .shift_left => if (rhs >= 32) return RuntimeError.ShiftOutOfRange else lhs << @intCast(rhs),
            .signed_divide => blk: {
                const signed_lhs: i32 = @bitCast(lhs);
                const signed_rhs: i32 = @bitCast(rhs);

                if (signed_rhs == 0)
                    return RuntimeError.DivisionByZero;

                if (signed_lhs == std.math.minInt(i32) and signed_rhs == -1)
                    return RuntimeError.IntegerOverflow;

                break :blk @bitCast(@divTrunc(signed_lhs, signed_rhs));
            },
            .signed_max => @bitCast(@max(@as(i32, @bitCast(lhs)), @as(i32, @bitCast(rhs)))),
            .signed_min => @bitCast(@min(@as(i32, @bitCast(lhs)), @as(i32, @bitCast(rhs)))),
            .signed_modulo => blk: {
                const signed_lhs: i32 = @bitCast(lhs);
                const signed_rhs: i32 = @bitCast(rhs);

                if (signed_rhs == 0)
                    return RuntimeError.DivisionByZero;

                if (signed_lhs == std.math.minInt(i32) and signed_rhs == -1)
                    break :blk 0;

                break :blk @bitCast(@mod(signed_lhs, signed_rhs));
            },
            .subtract => lhs -% rhs,
            .unsigned_divide => if (rhs == 0) return RuntimeError.DivisionByZero else lhs / rhs,
            .unsigned_max => @max(lhs, rhs),
            .unsigned_min => @min(lhs, rhs),
            .unsigned_modulo => if (rhs == 0) return RuntimeError.DivisionByZero else lhs % rhs,
        };
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = result;
    }
}

fn ternaryInt(self: *Self, instruction: bc.Instruction, comptime operation: TernaryInt) RuntimeError!void {
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);
    try self.validateRegisterRange(instruction.d, instruction.components);

    for (0..instruction.components) |component| {
        const x = low32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const y = low32(self.registers.at(@as(usize, @backingInt(instruction.c)) + component).*);
        const z = low32(self.registers.at(@as(usize, @backingInt(instruction.d)) + component).*);

        const result: u32 = switch (operation) {
            .signed_clamp => @bitCast(std.math.clamp(@as(i32, @bitCast(x)), @as(i32, @bitCast(y)), @as(i32, @bitCast(z)))),
            .unsigned_clamp => std.math.clamp(x, y, z),
        };

        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = result;
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
        const lhs = low32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const rhs = low32(self.registers.at(@as(usize, @backingInt(instruction.c)) + component).*);
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
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = low;
        self.registers.at(@as(usize, @backingInt(instruction.a)) + instruction.components + component).* = high;
    }
}

fn binaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: BinaryFloat, comptime broadcast_rhs: bool) RuntimeError!void {
    if (instruction.components == 0 or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, if (broadcast_rhs) 1 else instruction.components);

    for (0..instruction.components) |component| {
        const lhs: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const rhs_component = if (broadcast_rhs) 0 else component;
        const rhs: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.c)) + rhs_component).*);

        const result: f32 = switch (operation) {
            .add => lhs + rhs,
            .atan2 => std.math.atan2(lhs, rhs),
            .divide => lhs / rhs,
            .max => if (lhs < rhs) rhs else lhs,
            .min => if (lhs > rhs) rhs else lhs,
            .modulo => lhs - rhs * @floor(lhs / rhs),
            .multiply => lhs * rhs,
            .pow => std.math.pow(f32, lhs, rhs),
            .remainder => @rem(lhs, rhs),
            .step => if (rhs < lhs) 0.0 else 1.0,
            .subtract => lhs - rhs,
        };

        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = writeF32(result);
    }
}

fn ternaryFloat(self: *Self, instruction: bc.Instruction, comptime operation: TernaryFloat) RuntimeError!void {
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);
    try self.validateRegisterRange(instruction.d, instruction.components);

    for (0..instruction.components) |component| {
        const x: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const y: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.c)) + component).*);
        const z: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.d)) + component).*);

        const result: f32 = switch (operation) {
            .clamp => std.math.clamp(x, y, z),
            .mul_add => @mulAdd(f32, x, y, z),
        };

        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = writeF32(result);
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
        const edge0: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const edge1: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.c)) + component).*);
        const value: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.d)) + component).*);
        const t = std.math.clamp((value - edge0) / (edge1 - edge0), 0.0, 1.0);
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = writeF32(t * t * (3.0 - 2.0 * t));
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
        const lhs: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const rhs: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.c)) + component).*);
        sum += lhs * rhs;
    }
    self.registers.at(@backingInt(instruction.a)).* = writeF32(sum);
}

fn fMix(self: *Self, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.components == 0)
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, instruction.components);
    try self.validateRegisterRange(instruction.c, instruction.components);

    for (0..instruction.components) |component| {
        const x: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.b)) + component).*);
        const y: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.c)) + component).*);
        const a: f32 = readF32(self.registers.at(@as(usize, @backingInt(instruction.d)) + component).*);
        self.registers.at(@backingInt(instruction.a) + component).* = writeF32(x * (1.0 - a) + y * a);
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
        const rhs: f32 = readF32(self.registers.at(@backingInt(instruction.c) + column).*);
        for (0..dimensions.rows) |row| {
            const lhs: f32 = readF32(self.registers.at(@backingInt(instruction.b) + row).*);
            self.registers.at(@backingInt(instruction.a) + column * dimensions.rows + row).* = writeF32(lhs * rhs);
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
            self.registers.at(@backingInt(instruction.a) + destination_index).* = self.registers.at(@backingInt(instruction.b) + source_index).*;
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
            const matrix: f32 = readF32(self.registers.at(@backingInt(instruction.b) + column * dimensions.rows + row).*);
            const vector: f32 = readF32(self.registers.at(@backingInt(instruction.c) + column).*);
            sum += matrix * vector;
        }
        self.registers.at(@backingInt(instruction.a) + row).* = writeF32(sum);
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
            const vector: f32 = readF32(self.registers.at(@backingInt(instruction.b) + row).*);
            const matrix: f32 = readF32(self.registers.at(@backingInt(instruction.c) + column * dimensions.inner + row).*);
            sum += vector * matrix;
        }
        self.registers.at(@backingInt(instruction.a) + column).* = writeF32(sum);
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
                const lhs: f32 = readF32(self.registers.at(@backingInt(instruction.b) + inner * dimensions.rows + row).*);
                const rhs: f32 = readF32(self.registers.at(@backingInt(instruction.c) + column * dimensions.inner + inner).*);
                sum += lhs * rhs;
            }
            self.registers.at(@backingInt(instruction.a) + column * dimensions.rows + row).* = writeF32(sum);
        }
    }
}

fn componentProduct(lhs: u8, rhs: u8) RuntimeError!usize {
    return std.math.mul(usize, lhs, rhs) catch RuntimeError.InvalidBytecode;
}

fn compareInt(self: *Self, instruction: bc.Instruction, comptime operation: CompareInt) void {
    for (0..instruction.components) |component| {
        const lhs = low32(self.registers.at(@backingInt(instruction.b) + component).*);
        const rhs = low32(self.registers.at(@backingInt(instruction.c) + component).*);

        self.registers.at(@backingInt(instruction.a) + component).* = @intFromBool(switch (operation) {
            .equal => lhs == rhs,
            .not_equal => lhs != rhs,
            .unsigned_less => lhs < rhs,
            .signed_less => @as(i32, @bitCast(lhs)) < @as(i32, @bitCast(rhs)),
        });
    }
}

fn compareFloat(self: *Self, instruction: bc.Instruction, comptime operation: CompareFloat) void {
    for (0..instruction.components) |component| {
        const lhs: f32 = readF32(self.registers.at(@backingInt(instruction.b) + component).*);
        const rhs: f32 = readF32(self.registers.at(@backingInt(instruction.c) + component).*);

        const unordered = std.math.isNan(lhs) or std.math.isNan(rhs);
        self.registers.at(@backingInt(instruction.a) + component).* = @intFromBool(switch (operation) {
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
        const selected = if (low32(self.registers.at(@as(usize, @backingInt(instruction.b)) + condition_component).*) != 0)
            @backingInt(instruction.c)
        else
            @backingInt(instruction.d);
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = self.registers.at(@as(usize, selected) + component).*;
    }
}

fn loadBuffer(self: *Self, program: *const Program, resource_buffers: []const ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const resource = try self.selectBufferResource(program, instruction);
    const buffer = try resourceBuffer(program, resource_buffers, resource);
    const bytes = try self.bufferRange(buffer, instruction);
    try self.loadWords(instruction, bytes);
}

fn loadPushConstant(self: *Self, push_constants: []const u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const bytes = try self.pushConstantRange(push_constants, instruction);
    try self.loadWords(instruction, bytes);
}

fn loadWords(self: *Self, instruction: bc.Instruction, bytes: []const u8) RuntimeError!void {
    switch (instruction.scalar_bits) {
        8 => self.loadScalars(u8, instruction, bytes),
        16 => self.loadScalars(u16, instruction, bytes),
        32 => self.loadScalars(u32, instruction, bytes),
        64 => self.loadScalars(u64, instruction, bytes),
        else => return RuntimeError.InvalidBytecode,
    }
}

fn loadScalars(self: *Self, comptime Int: type, instruction: bc.Instruction, bytes: []const u8) void {
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(Int);
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = std.mem.readInt(Int, bytes[offset..][0..@sizeOf(Int)], .little);
    }
}

fn storeWords(self: *const Self, instruction: bc.Instruction, bytes: []u8) RuntimeError!void {
    switch (instruction.scalar_bits) {
        8 => self.storeScalars(u8, instruction, bytes),
        16 => self.storeScalars(u16, instruction, bytes),
        32 => self.storeScalars(u32, instruction, bytes),
        64 => self.storeScalars(u64, instruction, bytes),
        else => return RuntimeError.InvalidBytecode,
    }
}

fn storeScalars(self: *const Self, comptime Int: type, instruction: bc.Instruction, bytes: []u8) void {
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(Int);
        std.mem.writeInt(Int, bytes[offset..][0..@sizeOf(Int)], @truncate(self.registers.at(@as(usize, @backingInt(instruction.a)) + component).*), .little);
    }
}

fn scalarByteSize(instruction: bc.Instruction) RuntimeError!usize {
    return switch (instruction.scalar_bits) {
        8, 16, 32, 64 => instruction.scalar_bits / 8,
        else => RuntimeError.InvalidBytecode,
    };
}

fn storeBuffer(self: *const Self, program: *const Program, resource_buffers: []const ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const resource = try self.selectBufferResource(program, instruction);
    const buffer = try resourceBuffer(program, resource_buffers, resource);
    const bytes = try self.bufferRange(buffer, instruction);
    try self.storeWords(instruction, bytes);
}

fn imageSizeQueryLod(self: *Self, program: *const Program, resource_images: []const ?*SoftImageView, instruction: bc.Instruction) RuntimeError!void {
    if (instruction.immediate >= program.image_accesses.len or instruction.c != .invalid_register or
        instruction.d != .invalid_register or instruction.scalar_bits != 32)
        return RuntimeError.InvalidBytecode;

    const access = program.image_accesses[instruction.immediate];
    const spatial: u8 = switch (access.dimension) {
        .one_d => 1,
        .two_d, .cube => 2,
        .three_d => 3,
        .buffer => return RuntimeError.InvalidBytecode,
    };

    if ((access.arrayed and access.dimension == .three_d) or access.offset != .invalid_register or
        instruction.components != spatial + @as(u8, @intFromBool(access.arrayed)))
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterRange(instruction.a, instruction.components);
    try self.validateRegisterRange(instruction.b, 1);

    const view = try sampledImage(program, resource_images, access.resource);
    const image: *const SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const range = view.interface.subresource_range;

    if (range.base_mip_level >= image.interface.mip_levels or image.interface.samples.toInt() != 1)
        return RuntimeError.InvalidResource;

    const levels = @min(view.interface.levelCount(), image.interface.mip_levels - range.base_mip_level);
    if (levels == 0)
        return RuntimeError.InvalidResource;

    const lod = low32(self.registers.at(@backingInt(instruction.b)).*);
    const destination: usize = @backingInt(instruction.a);

    self.registers.slice(destination, destination + instruction.components).fill(0);

    if (lod >= levels)
        return;

    const mip = range.base_mip_level + lod;
    if (mip >= 32)
        return RuntimeError.InvalidResource;

    const extent = image.getMipLevelExtent(mip);
    const dimensions = [3]u32{ extent.width, extent.height, extent.depth };

    for (dimensions[0..spatial], 0..) |value, component|
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = value;

    if (access.arrayed) {
        const layer_limit = if (image.interface.image_type == .@"3d" and image.interface.flags.@"2d_array_compatible")
            image.getMipLevelExtent(range.base_mip_level).depth
        else
            image.interface.array_layers;

        if (range.base_array_layer >= layer_limit)
            return RuntimeError.InvalidResource;

        const layers = @min(view.interface.layerCount(), layer_limit - range.base_array_layer);
        self.registers.at(@as(usize, @backingInt(instruction.a)) + spatial).* = if (access.dimension == .cube) layers / 6 else layers;
    }
}

fn imageRead(self: *Self, program: *const Program, options: RunOptions, instruction: bc.Instruction, comptime floating: bool, comptime fetch: bool) RuntimeError!void {
    const access = try self.validateImageInstruction(program, instruction, fetch);
    var components: [4]u32 = @splat(0);
    if (access.dimension == .buffer) {
        const view = try resourceTexelBuffer(program, options.resource_texel_buffers, access.resource, fetch);
        if (try mapBufferTexel(view, readI32(self.registers.at(@backingInt(instruction.b)).*))) |texel| {
            components = if (floating)
                @bitCast(blitter.readFloat4(texel, view.interface.format))
            else
                @bitCast(blitter.readInt4(texel, view.interface.format));
        }
    } else {
        const view = if (fetch)
            try sampledImage(program, options.resource_images, access.resource)
        else
            try resourceImage(program, options.resource_images, @backingInt(access.resource));

        if (try self.imageLocation(view, access, instruction)) |location| {
            const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
            const format = format_info.fromAspect(view.interface.format, location.subresource.aspect_mask);
            if (floating) {
                var pixel = image.readFloat4(location.offset, location.subresource, format) catch return RuntimeError.InvalidResource;
                if (fetch) {
                    if (format_info.isSrgb(format))
                        pixel = zm.srgbToRgb(pixel);
                    pixel = SoftSampler.swizzleFloat4(pixel, view.interface.components);
                }
                components = @bitCast(pixel);
            } else {
                var pixel = image.readInt4(location.offset, location.subresource, format) catch return RuntimeError.InvalidResource;
                if (fetch)
                    pixel = SoftSampler.swizzleInt4(pixel, view.interface.components);
                components = @bitCast(pixel);
            }
        }
    }
    for (components, 0..) |value, channel|
        self.registers.at(@as(usize, @backingInt(instruction.a)) + channel).* = value;
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

    const component: usize = low32(self.registers.at(@backingInt(instruction.c)).*);
    if (component >= 4)
        return RuntimeError.InvalidResource;

    const view = try sampledImage(program, resource_images, pair.image);
    const sampler = try resourceSampler(program, resource_samplers, pair.sampler);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const extent = image.getMipLevelExtent(view.interface.subresource_range.base_mip_level);
    if (extent.width == 0 or extent.height == 0)
        return RuntimeError.InvalidResource;

    const x: f32 = readF32(self.registers.at(coordinate_base).*);
    const y: f32 = readF32(self.registers.at(coordinate_base + 1).*);
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
    for (components, 0..) |value, channel|
        self.registers.at(@as(usize, @backingInt(instruction.a)) + channel).* = value;
}

fn floatRegisterVector(registers: LaneView, first: bc.Register, components: u16) @Vector(4, f32) {
    var values: [4]f32 = @splat(0);
    for (0..components) |component|
        values[component] = readF32(registers.get(@as(usize, @backingInt(first)) + component));
    return values;
}

fn vectorDerivative(value: @Vector(4, f32)) spv.Runtime.Vec4(f32) {
    return .{ .x = value[0], .y = value[1], .z = value[2], .w = value[3] };
}

fn groupImageSample(self: *Self, program: *const Program, options: RunOptions, instruction: bc.Instruction, mask: LaneMask) RuntimeError!void {
    const pair = try self.validateSampleInstruction(program, instruction, false);
    const spatial = Program.spatialImageComponents(pair.dimension);
    var gradients: [lane_count]spv.Runtime.ImageDerivatives = undefined;

    for (0..lane_count) |lane| {
        if ((mask & laneBit(@intCast(lane))) == 0)
            continue;

        const quad_mask = @as(LaneMask, 0b1111) << @intCast(lane & ~@as(usize, 3));
        if ((mask & quad_mask) != quad_mask)
            return RuntimeError.DerivativeUnavailable;

        const left = floatRegisterVector(self.laneRegisters(@intCast(lane & ~@as(usize, 1))), instruction.b, spatial);
        const right = floatRegisterVector(self.laneRegisters(@intCast(lane | 1)), instruction.b, spatial);
        const top = floatRegisterVector(self.laneRegisters(@intCast(lane & ~@as(usize, 2))), instruction.b, spatial);
        const bottom = floatRegisterVector(self.laneRegisters(@intCast(lane | 2)), instruction.b, spatial);

        gradients[lane] = .{ .dx = vectorDerivative(right - left), .dy = vectorDerivative(bottom - top) };
    }
    for (0..lane_count) |lane| {
        if ((mask & laneBit(@intCast(lane))) == 0)
            continue;

        self.selectLane(@intCast(lane));
        try self.imageSample(program, options.resource_images, options.resource_samplers, instruction, false, gradients[lane]);
    }
}

fn validateSampleInstruction(self: *const Self, program: *const Program, instruction: bc.Instruction, explicit_lod: bool) RuntimeError!Program.ImageSamplerPair {
    if (instruction.immediate >= program.image_sampler_pairs.len or instruction.d != .invalid_register)
        return RuntimeError.InvalidBytecode;

    const pair = program.image_sampler_pairs[instruction.immediate];
    if (pair.dimension == .buffer or (pair.dimension == .cube and pair.arrayed) or
        instruction.components != (if (pair.dref != .invalid_register) @as(u16, 1) else 4) or
        (pair.dref != .invalid_register and pair.destination_kind != .floating) or
        (pair.destination_kind != .floating and pair.destination_kind != .signed_integer and pair.destination_kind != .unsigned_integer))
        return RuntimeError.InvalidBytecode;

    try self.validateRegisterSpan(instruction);
    try self.validateRegisterRange(instruction.b, Program.imageCoordinateComponents(pair.dimension, pair.arrayed));

    const has_grad = pair.grad_x != .invalid_register;

    if (has_grad != (pair.grad_y != .invalid_register) or
        (explicit_lod and ((instruction.c != .invalid_register) == has_grad)) or
        (explicit_lod and pair.bias != .invalid_register) or
        (!explicit_lod and (instruction.c != .invalid_register or has_grad)) or
        (pair.dimension == .cube and pair.offset != .invalid_register))
        return RuntimeError.InvalidBytecode;

    if (instruction.c != .invalid_register)
        try self.validateRegisterRange(instruction.c, 1);

    const spatial = Program.spatialImageComponents(pair.dimension);
    for ([_]bc.Register{ pair.grad_x, pair.grad_y, pair.offset }) |register| {
        if (register != .invalid_register)
            try self.validateRegisterRange(register, spatial);
    }

    for ([_]bc.Register{ pair.bias, pair.dref }) |register| {
        if (register != .invalid_register)
            try self.validateRegisterRange(register, 1);
    }

    return pair;
}

fn sampleOffset(self: *const Self, register: bc.Register, dimension: Program.ImageDimension) SoftSampler.ImageOffset {
    if (register == .invalid_register)
        return .{};

    const spatial = Program.spatialImageComponents(dimension);
    const index: usize = @backingInt(register);

    return .{
        .x = readI32(self.registers.at(index).*),
        .y = if (spatial >= 2) readI32(self.registers.at(index + 1).*) else 0,
        .z = if (spatial >= 3) readI32(self.registers.at(index + 2).*) else 0,
    };
}

fn imageSample(
    self: *Self,
    program: *const Program,
    resource_images: []const ?*SoftImageView,
    resource_samplers: []const ?*SoftSampler,
    instruction: bc.Instruction,
    explicit_lod: bool,
    implicit_derivatives: ?spv.Runtime.ImageDerivatives,
) RuntimeError!void {
    const pair = try self.validateSampleInstruction(program, instruction, explicit_lod);
    const coordinate_count = Program.imageCoordinateComponents(pair.dimension, pair.arrayed);
    const coordinate = floatRegisterVector(self.registers, instruction.b, coordinate_count);
    const view = try sampledImage(program, resource_images, pair.image);
    const sampler = try resourceSampler(program, resource_samplers, pair.sampler);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const dimension: spv.SpvDim = switch (pair.dimension) {
        .one_d => .@"1D",
        .two_d => .@"2D",
        .three_d => .@"3D",
        .cube => .Cube,
        .buffer => return RuntimeError.InvalidBytecode,
    };
    var lod: ?f32 = if (instruction.c == .invalid_register) null else readF32(self.registers.at(@backingInt(instruction.c)).*);

    const derivatives = if (pair.grad_x != .invalid_register) blk: {
        const spatial = Program.spatialImageComponents(pair.dimension);
        break :blk spv.Runtime.ImageDerivatives{
            .dx = vectorDerivative(floatRegisterVector(self.registers, pair.grad_x, spatial)),
            .dy = vectorDerivative(floatRegisterVector(self.registers, pair.grad_y, spatial)),
        };
    } else implicit_derivatives;

    if (derivatives) |gradient|
        lod = SoftSampler.lodFromDerivatives(image, view, dimension, coordinate, gradient);

    // SAFETY: initialized in the next condition
    var biased_sampler: SoftSampler = undefined;
    const sampling_sampler = if (pair.bias != .invalid_register) blk: {
        if (lod == null)
            return RuntimeError.DerivativeUnavailable;

        const bias: f32 = readF32(self.registers.at(@backingInt(pair.bias)).*);
        biased_sampler = sampler.*;
        biased_sampler.interface.mip_lod_bias = std.math.clamp(bias + sampler.interface.mip_lod_bias, -SoftSampler.max_lod_bias, SoftSampler.max_lod_bias);

        break :blk &biased_sampler;
    } else sampler;

    const offset = self.sampleOffset(pair.offset, pair.dimension);
    var components: [4]u32 = undefined;

    if (pair.dref != .invalid_register) {
        const reference: f32 = readF32(self.registers.at(@backingInt(pair.dref)).*);
        const value = SoftSampler.sampleImageDref(image, view, sampling_sampler, dimension, coordinate[0], coordinate[1], coordinate[2], coordinate[3], reference, lod, offset) catch return RuntimeError.InvalidResource;
        components[0] = @bitCast(value);
    } else {
        components = switch (pair.destination_kind) {
            .floating => @bitCast(SoftSampler.sampleImageFloat4(image, view, sampling_sampler, dimension, coordinate[0], coordinate[1], coordinate[2], lod, offset) catch return RuntimeError.InvalidResource),
            .signed_integer, .unsigned_integer => @bitCast(SoftSampler.sampleImageInt4(image, view, sampling_sampler, dimension, coordinate[0], coordinate[1], coordinate[2], lod, offset) catch return RuntimeError.InvalidResource),
            .boolean, .mixed => return RuntimeError.InvalidBytecode,
        };
    }

    for (components[0..instruction.components], 0..) |value, component|
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = value;
}

fn imageWrite(self: *const Self, program: *const Program, options: RunOptions, instruction: bc.Instruction, comptime floating: bool) RuntimeError!void {
    const access = try self.validateImageInstruction(program, instruction, false);
    var components: [4]u32 = undefined;
    for (&components, 0..) |*value, component|
        value.* = low32(self.registers.get(@as(usize, @backingInt(instruction.a)) + component));
    if (access.dimension == .buffer) {
        const view = try resourceTexelBuffer(program, options.resource_texel_buffers, access.resource, false);
        if (try mapBufferTexel(view, readI32(self.registers.at(@backingInt(instruction.b)).*))) |texel| {
            if (floating)
                blitter.writeFloat4(@bitCast(components), texel, view.interface.format)
            else
                blitter.writeInt4(@bitCast(components), texel, view.interface.format);
        }
    } else {
        const view = try resourceImage(program, options.resource_images, @backingInt(access.resource));
        const location = (try self.imageLocation(view, access, instruction)) orelse return;
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
        const format = format_info.fromAspect(view.interface.format, location.subresource.aspect_mask);

        if (floating)
            image.writeFloat4(location.offset, location.subresource, format, @bitCast(components)) catch return RuntimeError.InvalidResource
        else
            image.writeInt4(location.offset, location.subresource, format, @bitCast(components)) catch return RuntimeError.InvalidResource;
    }
}

fn validateImageInstruction(self: *const Self, program: *const Program, instruction: bc.Instruction, fetch: bool) RuntimeError!Program.ImageAccess {
    if (instruction.components != 4 or instruction.d != .invalid_register or instruction.immediate >= program.image_accesses.len)
        return RuntimeError.InvalidBytecode;
    const access = program.image_accesses[instruction.immediate];
    if ((access.arrayed and (access.dimension == .three_d or access.dimension == .buffer)) or (fetch and access.dimension == .cube))
        return RuntimeError.InvalidBytecode;
    try self.validateRegisterSpan(instruction);
    const count = if (access.dimension == .cube) 3 else Program.imageCoordinateComponents(access.dimension, access.arrayed);
    try self.validateRegisterRange(instruction.b, count);
    const needs_lod = fetch and access.dimension != .buffer;
    if (needs_lod != (instruction.c != .invalid_register))
        return RuntimeError.InvalidBytecode;
    if (needs_lod)
        try self.validateRegisterRange(instruction.c, 1);
    if (access.offset != .invalid_register) {
        if (!fetch or access.dimension == .buffer or access.dimension == .cube)
            return RuntimeError.InvalidBytecode;
        try self.validateRegisterRange(access.offset, Program.spatialImageComponents(access.dimension));
    }
    return access;
}

const ImageLocation = struct {
    offset: vk.Offset3D,
    subresource: vk.ImageSubresource,
};

fn imageLocation(self: *const Self, view: *const SoftImageView, access: Program.ImageAccess, instruction: bc.Instruction) RuntimeError!?ImageLocation {
    const image: *const SoftImage = @alignCast(@fieldParentPtr("interface", view.interface.image));
    const range = view.interface.subresource_range;
    if (range.base_mip_level >= image.interface.mip_levels or image.interface.samples.toInt() != 1)
        return RuntimeError.InvalidResource;

    const lod: i32 = if (instruction.c == .invalid_register) 0 else readI32(self.registers.at(@backingInt(instruction.c)).*);
    if (lod < 0 or @as(u32, @intCast(lod)) >= @min(view.interface.levelCount(), image.interface.mip_levels - range.base_mip_level))
        return null;

    const mip = range.base_mip_level + @as(u32, @intCast(lod));
    const index: usize = @backingInt(instruction.b);

    const x: i32 = readI32(self.registers.at(index).*);
    const y: i32 = if (access.dimension != .one_d or access.arrayed) readI32(self.registers.at(index + 1).*) else 0;
    const z: i32 = if (access.dimension == .three_d or access.dimension == .cube or (access.dimension == .two_d and access.arrayed)) readI32(self.registers.at(index + 2).*) else 0;

    var offset: vk.Offset3D = .{
        .x = x,
        .y = if (access.dimension == .one_d) 0 else y,
        .z = if (access.dimension == .three_d) z else 0,
    };

    const texel_offset = self.sampleOffset(access.offset, access.dimension);
    offset.x = std.math.add(i32, offset.x, texel_offset.x) catch return null;
    offset.y = std.math.add(i32, offset.y, texel_offset.y) catch return null;
    offset.z = std.math.add(i32, offset.z, texel_offset.z) catch return null;

    const extent = image.getMipLevelExtent(mip);
    if (offset.x < 0 or offset.y < 0 or offset.z < 0 or
        @as(u32, @intCast(offset.x)) >= extent.width or
        @as(u32, @intCast(offset.y)) >= extent.height or
        @as(u32, @intCast(offset.z)) >= extent.depth)
        return null;

    const relative_layer = std.math.cast(u32, switch (access.dimension) {
        .one_d => if (access.arrayed) y else @as(i32, 0),
        .two_d => if (access.arrayed) z else @as(i32, 0),
        .cube => z,
        .three_d => @as(i32, 0),
        .buffer => return RuntimeError.InvalidBytecode,
    }) orelse return null;

    if (access.dimension == .cube and !access.arrayed and relative_layer >= 6)
        return null;

    const layer_limit = if (image.interface.image_type == .@"3d" and image.interface.flags.@"2d_array_compatible") extent.depth else image.interface.array_layers;
    if (range.base_array_layer >= layer_limit or relative_layer >= layer_limit - range.base_array_layer or relative_layer >= view.interface.layerCount())
        return null;

    return .{
        .offset = offset,
        .subresource = .{ .aspect_mask = range.aspect_mask, .mip_level = mip, .array_layer = range.base_array_layer + relative_layer },
    };
}

fn resourceTexelBuffer(program: *const Program, buffers: []const ?*SoftBufferView, resource: ids.ResourceId, fetch: bool) RuntimeError!*SoftBufferView {
    const binding = program.resourceBinding(resource) orelse return RuntimeError.InvalidResource;
    const expected: shader_ir.ir.types.ResourceKind = if (fetch) .uniform_texel_buffer else .storage_texel_buffer;
    if (binding.kind != expected)
        return RuntimeError.InvalidResource;
    if (resource.index() >= buffers.len)
        return RuntimeError.ResourceNotBound;
    return buffers[resource.index()] orelse RuntimeError.ResourceNotBound;
}

fn mapBufferTexel(view: *const SoftBufferView, x: i32) RuntimeError!?[]u8 {
    if (x < 0)
        return null;
    const buffer: *SoftBuffer = @alignCast(@fieldParentPtr("interface", view.interface.buffer));
    const memory = buffer.interface.memory orelse return RuntimeError.ResourceNotBound;

    if (buffer.interface.offset > memory.size)
        return RuntimeError.InvalidResource;

    const bound_size = @min(buffer.interface.size, memory.size - buffer.interface.offset);
    if (view.interface.offset > bound_size)
        return RuntimeError.InvalidResource;

    const available = bound_size - view.interface.offset;
    const range = if (view.interface.range == vk.WHOLE_SIZE) available else @min(view.interface.range, available);
    const texel_size = format_info.texelSize(view.interface.format);

    if (texel_size == 0)
        return RuntimeError.InvalidResource;

    const offset = std.math.mul(vk.DeviceSize, @intCast(x), texel_size) catch return null;
    if (offset > range or texel_size > range - offset)
        return null;

    return buffer.mapAsSliceWithAddedOffset(u8, view.interface.offset + offset, texel_size) catch RuntimeError.InvalidResource;
}

fn loadWorkgroup(self: *Self, program: *const Program, optional_memory: ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const bytes = try self.workgroupRange(program, optional_memory, instruction);
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(u32);
        self.registers.at(@as(usize, @backingInt(instruction.a)) + component).* = std.mem.readInt(u32, bytes[offset..][0..@sizeOf(u32)], .little);
    }
}

fn storeWorkgroup(self: *const Self, program: *const Program, optional_memory: ?[]u8, instruction: bc.Instruction) RuntimeError!void {
    try self.validateRegisterSpan(instruction);
    const bytes = try self.workgroupRange(program, optional_memory, instruction);
    for (0..instruction.components) |component| {
        const offset = component * @sizeOf(u32);
        std.mem.writeInt(u32, bytes[offset..][0..@sizeOf(u32)], low32(self.registers.at(@as(usize, @backingInt(instruction.a)) + component).*), .little);
    }
}

fn workgroupRange(self: *const Self, program: *const Program, optional_memory: ?[]u8, instruction: bc.Instruction) RuntimeError![]u8 {
    const memory = optional_memory orelse return RuntimeError.WorkgroupMemoryUnavailable;

    if (@backingInt(instruction.b) >= self.registers.len)
        return RuntimeError.InvalidBytecode;

    const variable = ids.WorkgroupVariableId.fromIndex(instruction.immediate);
    const binding = program.workgroupBinding(variable) orelse return RuntimeError.InvalidBytecode;
    const relative_offset: usize = low32(self.registers.at(@backingInt(instruction.b)).*);
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

    const byte_offset: usize = low32(self.registers.at(@backingInt(instruction.b)).*);
    const byte_count = std.math.mul(usize, instruction.components, try scalarByteSize(instruction)) catch return RuntimeError.BufferOutOfBounds;
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

    const array_element = low32(self.registers.at(@backingInt(instruction.c)).*);
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
            self.scratch.at(@as(usize, @backingInt(item.scratch_base)) + component).* = self.registers.at(@as(usize, @backingInt(item.source)) + component).*;
        }
    }
    for (copies) |item| {
        for (0..item.components) |component| {
            self.registers.at(@as(usize, @backingInt(item.destination)) + component).* = self.scratch.at(@as(usize, @backingInt(item.scratch_base)) + component).*;
        }
    }

    if (edge.target_pc >= program.code.len)
        return RuntimeError.InvalidBytecode;

    return edge.target_pc;
}
