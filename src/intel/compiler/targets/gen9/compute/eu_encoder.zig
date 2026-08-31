const std = @import("std");
const device = @import("../../../device.zig");
const ir_instruction = @import("../../../ir/instruction.zig");
const operand = @import("../../../ir/operand.zig");
const message_descriptor = @import("message_descriptor.zig");
const eu = @import("eu.zig");

pub const Error = error{
    UnsupportedExecutionSize,
    UnsupportedDataType,
    UnsupportedOperand,
    InvalidRegister,
    InvalidRegion,
};

pub const eot_payload_grf: u8 = 112;

pub const EncodedInstruction = struct {
    words: [2]u64 = .{ 0, 0 },

    pub fn setBits(self: *EncodedInstruction, high: u7, low: u7, value: u64) void {
        const width = @as(u8, high) - @as(u8, low) + 1;
        const word = @as(usize, high) / 64;
        const word_low: u6 = @intCast(@as(u8, low) % 64);
        const mask = (@as(u64, std.math.maxInt(u64)) >> @intCast(64 - width)) << word_low;
        self.words[word] = (self.words[word] & ~mask) | ((value << word_low) & mask);
    }

    pub fn bits(self: EncodedInstruction, high: u7, low: u7) u64 {
        const width = @as(u8, high) - @as(u8, low) + 1;
        const word = @as(usize, high) / 64;
        const word_low: u6 = @intCast(@as(u8, low) % 64);
        return (self.words[word] >> word_low) & (@as(u64, std.math.maxInt(u64)) >> @intCast(64 - width));
    }
};

const RegisterFile = enum(u2) {
    architecture = 0,
    grf = 1,
    immediate = 3,
};

const HardwareType = enum(u4) {
    unsigned_dword = 0,
    signed_dword = 1,
    unsigned_word = 2,
    float = 7,
};

const Grf = struct {
    number: u8,
    byte_offset: u5,
};

pub fn encodeMove(execution_size: device.ExecutionSize, move: ir_instruction.Move) Error!EncodedInstruction {
    var encoded = try instructionHeader(.mov, execution_size);
    const destination = try resolveGrf(move.destination.register, move.destination.region.byte_offset);
    setDestination(&encoded, .grf, try hardwareType(move.destination.type), destination, try horizontalStride(move.destination.region.horizontal_stride));
    try setSource0(&encoded, move.source);
    return encoded;
}

pub fn encodeEndThread(header: operand.PhysicalGrf) Error![2]EncodedInstruction {
    if (header.number != 0 or header.byte_offset != 0)
        return Error.InvalidRegister;

    var copy = try instructionHeader(.mov, .simd8);
    copy.setBits(34, 34, 1); // NoMask
    setDestination(&copy, .grf, .unsigned_dword, .{ .number = eot_payload_grf, .byte_offset = 0 }, 1);
    copy.setBits(42, 41, @intFromEnum(RegisterFile.grf));
    copy.setBits(46, 43, @intFromEnum(HardwareType.unsigned_dword));
    copy.setBits(76, 69, header.number);
    copy.setBits(81, 80, 1);
    copy.setBits(84, 82, 3);
    copy.setBits(88, 85, 4);

    var send = try instructionHeader(.send, .simd8);
    send.setBits(34, 34, 1); // NoMask
    setDestination(&send, .architecture, .unsigned_word, .{ .number = 0, .byte_offset = 0 }, 1);
    send.setBits(42, 41, @intFromEnum(RegisterFile.grf));
    send.setBits(46, 43, @intFromEnum(HardwareType.unsigned_word));
    send.setBits(76, 69, eot_payload_grf);
    send.setBits(81, 80, 1);
    send.setBits(84, 82, 3);
    send.setBits(88, 85, 4);
    send.setBits(90, 89, @intFromEnum(RegisterFile.immediate));
    send.setBits(94, 91, @intFromEnum(HardwareType.unsigned_dword));
    send.setBits(124, 96, 0x02000010); // mlen=1, no response, do not dereference URB
    send.setBits(27, 24, 7); // Thread Spawner
    send.setBits(127, 127, 1);

    return .{ copy, send };
}

pub fn encodeSurfaceMessage(execution_size: device.ExecutionSize, message: ir_instruction.SurfaceMessage) Error!EncodedInstruction {
    var encoded = try instructionHeader(.send, execution_size);
    const descriptor = message_descriptor.encode(message);
    const payload = try resolveGrf(message.payload.base, 0);
    if (payload.byte_offset != 0)
        return Error.InvalidRegister;

    if (message.response) |response| {
        const destination = try resolveGrf(response.base, 0);
        if (destination.byte_offset != 0)
            return Error.InvalidRegister;
        setDestination(&encoded, .grf, .unsigned_word, destination, 1);
    } else {
        setDestination(&encoded, .architecture, .unsigned_word, .{ .number = 0, .byte_offset = 0 }, 1);
    }

    encoded.setBits(42, 41, @intFromEnum(RegisterFile.grf));
    encoded.setBits(46, 43, @intFromEnum(HardwareType.unsigned_dword));
    encoded.setBits(76, 69, payload.number);
    encoded.setBits(68, 64, payload.byte_offset);
    encoded.setBits(81, 80, 1); // horizontal stride 1
    encoded.setBits(84, 82, 3); // width 8
    encoded.setBits(88, 85, 4); // vertical stride 8
    encoded.setBits(90, 89, @intFromEnum(RegisterFile.immediate));
    encoded.setBits(94, 91, @intFromEnum(HardwareType.unsigned_dword));
    encoded.setBits(124, 96, descriptor.value);
    encoded.setBits(27, 24, descriptor.sfid);
    return encoded;
}

pub fn encodeJump(displacement_bytes: i32) Error!EncodedInstruction {
    return encodeJumpWithPredicate(displacement_bytes, null);
}

pub fn encodePredicatedJump(displacement_bytes: i32, predicate: operand.Predicate) Error!EncodedInstruction {
    return encodeJumpWithPredicate(displacement_bytes, predicate);
}

fn encodeJumpWithPredicate(displacement_bytes: i32, predicate: ?operand.Predicate) Error!EncodedInstruction {
    var encoded = try instructionHeader(.jmpi, .simd1);
    encoded.setBits(34, 34, 1); // NoMask

    // JMPI updates the instruction pointer: IP = IP + displacement.
    setDestination(&encoded, .architecture, .signed_dword, .{ .number = 0xa0, .byte_offset = 0 }, 1);
    encoded.setBits(42, 41, @intFromEnum(RegisterFile.architecture));
    encoded.setBits(46, 43, @intFromEnum(HardwareType.signed_dword));
    encoded.setBits(76, 69, 0xa0);
    encoded.setBits(81, 80, 0);
    encoded.setBits(84, 82, 0);
    encoded.setBits(88, 85, 0);
    setSource1Immediate(&encoded, .signed_dword, .{ .i32 = displacement_bytes });

    if (predicate) |value| {
        const flag = switch (value.flag) {
            .physical => |physical| physical,
            .virtual => return Error.UnsupportedOperand,
        };
        if (flag.register != 0 or flag.subregister > 1)
            return Error.InvalidRegister;

        encoded.setBits(19, 16, 1); // Normal predicate control.
        encoded.setBits(20, 20, @intFromBool(value.inverse));
        encoded.setBits(33, 33, flag.register);
        encoded.setBits(32, 32, flag.subregister);
    }

    return encoded;
}

pub fn patchJump(encoded_bytes: []u8, displacement_bytes: i32) Error!void {
    if (encoded_bytes.len < 16)
        return Error.InvalidRegister;

    var encoded: EncodedInstruction = .{ .words = .{
        std.mem.readInt(u64, encoded_bytes[0..8], .little),
        std.mem.readInt(u64, encoded_bytes[8..16], .little),
    } };
    if (encoded.bits(6, 0) != @intFromEnum(eu.Opcode.jmpi))
        return Error.UnsupportedOperand;
    encoded.setBits(127, 96, @as(u32, @bitCast(displacement_bytes)));
    std.mem.writeInt(u64, encoded_bytes[0..8], encoded.words[0], .little);
    std.mem.writeInt(u64, encoded_bytes[8..16], encoded.words[1], .little);
}

pub fn encodeBinary(execution_size: device.ExecutionSize, binary: ir_instruction.Binary) Error!EncodedInstruction {
    const opcode: eu.Opcode = switch (binary.opcode) {
        .bitwise_xor => .xor,
        .add => .add,
        .multiply => .mul,
        else => return Error.UnsupportedOperand,
    };

    var encoded = try instructionHeader(opcode, execution_size);
    const destination = try resolveGrf(binary.destination.register, binary.destination.region.byte_offset);
    setDestination(&encoded, .grf, try hardwareType(binary.destination.type), destination, try horizontalStride(binary.destination.region.horizontal_stride));
    try setSource0(&encoded, binary.lhs);
    try setSource1(&encoded, binary.rhs);
    return encoded;
}

pub fn encodeCompare(execution_size: device.ExecutionSize, compare: ir_instruction.Compare) Error!EncodedInstruction {
    const flag = switch (compare.destination) {
        .physical => |value| value,
        .virtual => return Error.UnsupportedOperand,
    };
    if (flag.register != 0 or flag.subregister > 1)
        return Error.InvalidRegister;

    var encoded = try instructionHeader(.cmp, execution_size);
    setDestination(&encoded, .architecture, try hardwareType(compare.lhs.type), .{ .number = 0, .byte_offset = 0 }, 1);
    try setSource0(&encoded, compare.lhs);
    try setSource1(&encoded, compare.rhs);

    const condition: eu.CompareCondition = switch (compare.opcode) {
        .equal => .zero,
        .not_equal => .not_zero,
        .greater_than => .greater,
        .greater_or_equal => .greater_or_equal,
        .less_than => .less,
        .less_or_equal => .less_or_equal,
    };

    encoded.setBits(27, 24, @intFromEnum(condition));
    encoded.setBits(33, 33, flag.register);
    encoded.setBits(32, 32, flag.subregister);
    return encoded;
}

pub fn encodeMath(execution_size: device.ExecutionSize, math: ir_instruction.Math) Error!EncodedInstruction {
    if (execution_size != .simd8)
        return Error.UnsupportedExecutionSize;

    var encoded = try instructionHeader(.math, execution_size);
    const destination = try resolveGrf(math.destination.register, math.destination.region.byte_offset);
    setDestination(&encoded, .grf, try hardwareType(math.destination.type), destination, try horizontalStride(math.destination.region.horizontal_stride));

    try setSource0(&encoded, math.lhs);
    try setSource1(&encoded, math.rhs);

    const function: eu.MathFunction = switch (math.opcode) {
        .integer_quotient => .idiv,
    };

    encoded.setBits(27, 24, @intFromEnum(function));

    return encoded;
}

fn instructionHeader(opcode: eu.Opcode, execution_size: device.ExecutionSize) Error!EncodedInstruction {
    var encoded: EncodedInstruction = .{};
    encoded.setBits(6, 0, @intFromEnum(opcode));
    encoded.setBits(23, 21, try executionSize(execution_size));
    return encoded;
}

fn setDestination(encoded: *EncodedInstruction, file: RegisterFile, data_type: HardwareType, register: Grf, horizontal_stride: u2) void {
    encoded.setBits(36, 35, @intFromEnum(file));
    encoded.setBits(40, 37, @intFromEnum(data_type));
    encoded.setBits(52, 48, register.byte_offset);
    encoded.setBits(60, 53, register.number);
    encoded.setBits(62, 61, horizontal_stride);
}

fn setSource0Register(encoded: *EncodedInstruction, source: operand.Source, register: Grf) Error!void {
    encoded.setBits(42, 41, @intFromEnum(RegisterFile.grf));
    encoded.setBits(46, 43, @intFromEnum(try hardwareType(source.type)));
    encoded.setBits(68, 64, register.byte_offset);
    encoded.setBits(76, 69, register.number);
    encoded.setBits(77, 77, @intFromBool(source.absolute));
    encoded.setBits(78, 78, @intFromBool(source.negate));
    encoded.setBits(81, 80, try horizontalStride(source.region.horizontal_stride));
    encoded.setBits(84, 82, try regionWidth(source.region.width));
    encoded.setBits(88, 85, try verticalStride(source.region.vertical_stride));
}

fn setSource0Immediate(encoded: *EncodedInstruction, data_type: HardwareType, immediate: operand.Immediate) void {
    encoded.setBits(42, 41, @intFromEnum(RegisterFile.immediate));
    encoded.setBits(46, 43, @intFromEnum(data_type));
    encoded.setBits(90, 89, @intFromEnum(RegisterFile.architecture));
    encoded.setBits(94, 91, @intFromEnum(data_type));
    encoded.setBits(127, 96, switch (immediate) {
        .u32 => |value| value,
        .i32 => |value| @as(u32, @bitCast(value)),
        .f32 => |value| @as(u32, @bitCast(value)),
    });
}

fn setSource0(encoded: *EncodedInstruction, source: operand.Source) Error!void {
    switch (source.register) {
        .physical_grf => {
            const register = try resolveGrf(source.register, source.region.byte_offset);
            try setSource0Register(encoded, source, register);
        },
        .immediate => |immediate| {
            setSource0Immediate(encoded, try hardwareType(source.type), try applyImmediateModifiers(immediate, source.negate, source.absolute));
        },

        else => return Error.UnsupportedOperand,
    }
}

fn setSource1Register(encoded: *EncodedInstruction, source: operand.Source, register: Grf) Error!void {
    encoded.setBits(90, 89, @intFromEnum(RegisterFile.grf));
    encoded.setBits(94, 91, @intFromEnum(try hardwareType(source.type)));

    // Direct addressing.
    encoded.setBits(100, 96, register.byte_offset);
    encoded.setBits(108, 101, register.number);

    // Source modifiers.
    encoded.setBits(109, 109, @intFromBool(source.absolute));
    encoded.setBits(110, 110, @intFromBool(source.negate));

    // AddressMode = direct.
    encoded.setBits(111, 111, 0);

    // Align1 region.
    encoded.setBits(113, 112, try horizontalStride(source.region.horizontal_stride));
    encoded.setBits(116, 114, try regionWidth(source.region.width));
    encoded.setBits(120, 117, try verticalStride(source.region.vertical_stride));
}

fn setSource1Immediate(encoded: *EncodedInstruction, data_type: HardwareType, immediate: operand.Immediate) void {
    encoded.setBits(90, 89, @intFromEnum(RegisterFile.immediate));

    encoded.setBits(94, 91, @intFromEnum(data_type));

    encoded.setBits(127, 96, switch (immediate) {
        .u32 => |value| value,
        .i32 => |value| @as(u32, @bitCast(value)),
        .f32 => |value| @as(u32, @bitCast(value)),
    });
}

fn setSource1(encoded: *EncodedInstruction, source: operand.Source) Error!void {
    switch (source.register) {
        .physical_grf => {
            const register = try resolveGrf(source.register, source.region.byte_offset);
            try setSource1Register(encoded, source, register);
        },

        .immediate => |immediate| {
            setSource1Immediate(encoded, try hardwareType(source.type), try applyImmediateModifiers(immediate, source.negate, source.absolute));
        },

        else => return Error.UnsupportedOperand,
    }
}

fn applyImmediateModifiers(immediate: operand.Immediate, negate: bool, absolute: bool) Error!operand.Immediate {
    if (absolute)
        return Error.UnsupportedOperand;
    if (!negate)
        return immediate;

    return switch (immediate) {
        .u32 => |value| .{ .u32 = 0 -% value },
        .i32 => |value| .{ .i32 = 0 -% value },
        .f32 => |value| .{ .f32 = -value },
    };
}

fn resolveGrf(register: operand.RegisterRef, region_byte_offset: u16) Error!Grf {
    const physical = switch (register) {
        .physical_grf => |value| value,
        else => return Error.UnsupportedOperand,
    };

    const byte_address = @as(u32, physical.number) * 32 + physical.byte_offset + region_byte_offset;
    const number = byte_address / 32;

    if (number >= 128)
        return Error.InvalidRegister;

    return .{
        .number = @intCast(number),
        .byte_offset = @intCast(byte_address % 32),
    };
}

fn hardwareType(data_type: operand.DataType) Error!HardwareType {
    return switch (data_type) {
        .u32 => .unsigned_dword,
        .i32 => .signed_dword,
        .f32 => .float,
        else => Error.UnsupportedDataType,
    };
}

fn executionSize(size: device.ExecutionSize) Error!u3 {
    return switch (size) {
        .simd1 => 0,
        .simd8 => 3,
        else => Error.UnsupportedExecutionSize,
    };
}

fn horizontalStride(stride: u8) Error!u2 {
    return switch (stride) {
        0 => 0,
        1 => 1,
        2 => 2,
        4 => 3,
        else => Error.InvalidRegion,
    };
}

fn regionWidth(width: u8) Error!u3 {
    return switch (width) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        16 => 4,
        else => Error.InvalidRegion,
    };
}

fn verticalStride(stride: u8) Error!u4 {
    return switch (stride) {
        0 => 0,
        1 => 1,
        2 => 2,
        4 => 3,
        8 => 4,
        16 => 5,
        32 => 6,
        else => Error.InvalidRegion,
    };
}

fn testBinary(opcode: ir_instruction.BinaryOpcode) ir_instruction.Binary {
    return .{
        .opcode = opcode,
        .destination = .{
            .register = .{ .physical_grf = .{ .number = 3 } },
            .type = .u32,
        },
        .lhs = .{
            .register = .{ .physical_grf = .{ .number = 1 } },
            .type = .u32,
            .region = operand.Region.contiguous(.simd8),
        },
        .rhs = .{
            .register = .{ .immediate = .{ .u32 = 16 } },
            .type = .u32,
            .region = operand.Region.broadcast(),
        },
    };
}

test "[gen9] EU encoder: encode integer multiply" {
    const encoded = try encodeBinary(.simd8, testBinary(.multiply));
    try std.testing.expectEqual(@as(u64, 65), encoded.bits(6, 0));
    try std.testing.expectEqual(@as(u64, 3), encoded.bits(23, 21));
}

test "[gen9] EU encoder: encode bitwise XOR" {
    const encoded = try encodeBinary(.simd8, testBinary(.bitwise_xor));
    try std.testing.expectEqual(@as(u64, 7), encoded.bits(6, 0));
    try std.testing.expectEqual(@as(u64, 16), encoded.bits(127, 96));
}

test "[gen9] EU encoder: encode unsigned less-than comparison" {
    const encoded = try encodeCompare(.simd8, .{
        .opcode = .less_than,
        .destination = .{ .physical = .{ .register = 0, .subregister = 1 } },
        .lhs = .{
            .register = .{ .physical_grf = .{ .number = 1 } },
            .type = .u32,
            .region = operand.Region.contiguous(.simd8),
        },
        .rhs = .{
            .register = .{ .physical_grf = .{ .number = 2 } },
            .type = .u32,
            .region = operand.Region.contiguous(.simd8),
        },
    });

    try std.testing.expectEqual(@as(u64, 16), encoded.bits(6, 0));
    try std.testing.expectEqual(@as(u64, 5), encoded.bits(27, 24));
    try std.testing.expectEqual(@as(u64, 0), encoded.bits(33, 33));
    try std.testing.expectEqual(@as(u64, 1), encoded.bits(32, 32));
}

test "[gen9] EU encoder: encode predicated jump" {
    const encoded = try encodePredicatedJump(-32, .{
        .flag = .{ .physical = .{ .register = 0, .subregister = 1 } },
        .inverse = true,
    });

    try std.testing.expectEqual(@as(u64, @intFromEnum(eu.Opcode.jmpi)), encoded.bits(6, 0));
    try std.testing.expectEqual(@as(u64, 1), encoded.bits(19, 16));
    try std.testing.expectEqual(@as(u64, 1), encoded.bits(20, 20));
    try std.testing.expectEqual(@as(u64, 1), encoded.bits(32, 32));
    try std.testing.expectEqual(@as(i32, -32), @as(i32, @bitCast(@as(u32, @truncate(encoded.bits(127, 96))))));
}
