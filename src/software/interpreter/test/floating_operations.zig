const std = @import("std");
const shader_ir = @import("shader_ir");

const bc = @import("../bytecode.zig");
const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");
const copyWords = @import("slot_helpers.zig").copyWords;
const expectWords = @import("slot_helpers.zig").expectWords;

const ir = shader_ir.ir;

inline fn reg(index: u16) bc.Register {
    return @fromBackingInt(index);
}

inline fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

fn bitsF32(value: bc.Slot) !f32 {
    try std.testing.expectEqual(@as(bc.Slot, 0), value >> 32);
    return @bitCast(@as(u32, @truncate(value)));
}

fn bytecodeProgram(code: []const bc.Instruction, register_count: usize) Program {
    return .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .stage = .compute,
        .uses_atomics = false,
        .uses_control_barriers = false,
        .workgroup_memory_size = 0,
        .entry_pc = 0,
        .register_count = register_count,
        .scratch_count = 0,
        .array_lengths = &.{},
        .descriptor_arrays = &.{},
        .image_sampler_pairs = &.{},
        .code = code,
        .edges = &.{},
        .copies = &.{},
        .branches = &.{},
        .initializers = &.{},
        .interfaces = &.{},
        .resources = &.{},
        .workgroup_variables = &.{},
    };
}

test "[interpreter] float classification produces boolean lanes" {
    const code = [_]bc.Instruction{
        .{ .opcode = .is_inf, .components = 1, .a = reg(4), .b = reg(0) },
        .{ .opcode = .is_inf, .components = 4, .a = reg(5), .b = reg(0) },
        .{ .opcode = .is_nan, .components = 4, .a = reg(9), .b = reg(0) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 13);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const values = [_]u32{
        f32Bits(std.math.inf(f32)),
        f32Bits(-std.math.inf(f32)),
        f32Bits(std.math.nan(f32)),
        f32Bits(12.5),
    };
    copyWords(runtime.registers.slice(0, 4), &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, 1), runtime.registers.at(4).*);
    try expectWords(&.{ 1, 1, 0, 0 }, runtime.registers.slice(5, 9));
    try expectWords(&.{ 0, 0, 1, 0 }, runtime.registers.slice(9, 13));
}

test "[interpreter] select broadcasts scalar conditions and applies vector conditions per lane" {
    const code = [_]bc.Instruction{
        .{ .opcode = .select, .components = 4, .a = reg(12), .b = reg(0), .c = reg(4), .d = reg(8) },
        .{ .opcode = .select, .components = 4, .a = reg(16), .b = reg(0), .c = reg(4), .d = reg(8), .immediate = 1 },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 20);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const values = [_]u32{
        1,  0,  1,  0,
        10, 11, 12, 13,
        20, 21, 22, 23,
    };
    copyWords(runtime.registers.slice(0, 12), &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try expectWords(&.{ 10, 11, 12, 13 }, runtime.registers.slice(12, 16));
    try expectWords(&.{ 10, 21, 12, 23 }, runtime.registers.slice(16, 20));
}

test "[interpreter] GLSL extended floating operations execute component-wise" {
    const code = [_]bc.Instruction{
        .{ .opcode = .float_absolute, .a = reg(8), .b = reg(0) },
        .{ .opcode = .compare_ordered_float_less, .components = 4, .a = reg(40), .b = reg(0), .c = reg(28) },
        .{ .opcode = .compare_ordered_float_less, .components = 4, .a = reg(44), .b = reg(28), .c = reg(0) },
        .{ .opcode = .select, .components = 4, .a = reg(48), .b = reg(40), .c = reg(36), .d = reg(28), .immediate = 1 },
        .{ .opcode = .select, .components = 4, .a = reg(13), .b = reg(44), .c = reg(32), .d = reg(48), .immediate = 1 },
        .{ .opcode = .dot, .components = 2, .a = reg(52), .b = reg(1), .c = reg(1) },
        .{ .opcode = .inverse_sqrt, .a = reg(52), .b = reg(52) },
        .{ .opcode = .copy, .a = reg(53), .b = reg(52) },
        .{ .opcode = .float_multiply, .components = 2, .a = reg(9), .b = reg(1), .c = reg(52) },
        .{ .opcode = .float_subtract, .a = reg(20), .b = reg(5), .c = reg(3) },
        .{ .opcode = .float_subtract, .a = reg(21), .b = reg(4), .c = reg(3) },
        .{ .opcode = .float_divide, .a = reg(20), .b = reg(20), .c = reg(21) },
        .{ .opcode = .float_max, .a = reg(20), .b = reg(20), .c = reg(22) },
        .{ .opcode = .float_min, .a = reg(20), .b = reg(20), .c = reg(4) },
        .{ .opcode = .float_multiply, .a = reg(25), .b = reg(20), .c = reg(20) },
        .{ .opcode = .float_multiply, .a = reg(26), .b = reg(23), .c = reg(20) },
        .{ .opcode = .float_subtract, .a = reg(27), .b = reg(24), .c = reg(26) },
        .{ .opcode = .float_multiply, .a = reg(11), .b = reg(25), .c = reg(27) },
        .{ .opcode = .atan2, .a = reg(12), .b = reg(6), .c = reg(7) },
        .{ .opcode = .pow, .a = reg(17), .b = reg(1), .c = reg(2) },
        .{ .opcode = .float_max, .a = reg(18), .b = reg(0), .c = reg(4) },
        .{ .opcode = .floor, .a = reg(19), .b = reg(0) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 54);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    copyWords(runtime.registers.slice(22, 25), &.{ f32Bits(0), f32Bits(2), f32Bits(3) });
    runtime.registers.slice(28, 32).fill(f32Bits(0));
    runtime.registers.slice(32, 36).fill(f32Bits(1));
    runtime.registers.slice(36, 40).fill(f32Bits(-1));
    const values = [_]u32{
        f32Bits(-2.25),
        f32Bits(3.0),
        f32Bits(4.0),
        f32Bits(-0.0),
        f32Bits(1.0),
        f32Bits(0.25),
        f32Bits(1.0),
        f32Bits(1.0),
    };
    copyWords(runtime.registers.slice(0, 8), &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(f32, 2.25), try bitsF32(runtime.registers.at(8).*));
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), try bitsF32(runtime.registers.at(9).*), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), try bitsF32(runtime.registers.at(10).*), 0.00001);
    try std.testing.expectEqual(@as(f32, 0.15625), try bitsF32(runtime.registers.at(11).*));
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), try bitsF32(runtime.registers.at(12).*), 0.00001);
    try expectWords(&.{ f32Bits(-1.0), f32Bits(1.0), f32Bits(1.0), f32Bits(0.0) }, runtime.registers.slice(13, 17));
    try std.testing.expectEqual(@as(f32, 81.0), try bitsF32(runtime.registers.at(17).*));
    try std.testing.expectEqual(@as(f32, 1.0), try bitsF32(runtime.registers.at(18).*));
    try std.testing.expectEqual(@as(f32, -3.0), try bitsF32(runtime.registers.at(19).*));
}

test "[interpreter] exp executes scalar and vector f32 including special values" {
    const code = [_]bc.Instruction{
        .{ .opcode = .exp, .a = reg(4), .b = reg(0) },
        .{ .opcode = .exp, .components = 4, .a = reg(5), .b = reg(0) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 9);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    const cases = [_][4]f32{
        .{ 0, -0.0, 1, -1 },
        .{ -0.5, 2, -1000, 1000 },
        .{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 0 },
    };
    const expected = [_][4]f32{
        .{ 1, 1, 2.718281828459045, 0.3678794411714423 },
        .{ 0.6065306597126334, 7.38905609893065, 0, std.math.inf(f32) },
        .{ std.math.inf(f32), 0, std.math.nan(f32), 1 },
    };
    for (cases, expected) |inputs, results| {
        runtime.resetInvocation(&program);
        for (inputs, 0..) |input, i| runtime.registers.at(i).* = f32Bits(input);
        try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
        try expectExpResult(results[0], try bitsF32(runtime.registers.at(4).*));
        for (results, 0..) |result, i|
            try expectExpResult(result, try bitsF32(runtime.registers.at(5 + i).*));
    }
}

test "[interpreter] exp wave execution preserves inactive lanes" {
    const code = [_]bc.Instruction{
        .{ .opcode = .exp, .a = reg(4), .b = reg(0) },
        .{ .opcode = .exp, .components = 4, .a = reg(5), .b = reg(0) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 9);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    for ([_]Runtime.LaneMask{ Runtime.full_lane_mask, 0b0101 }) |mask| {
        runtime.resetWave(&program, mask, mask);
        for (0..Runtime.lane_count) |lane| {
            const registers = runtime.laneRegisters(lane);
            registers.slice(4, 9).fill(f32Bits(-99));
            const inputs = [_]f32{ -0.5, @as(f32, @floatFromInt(lane)), -std.math.inf(f32), std.math.nan(f32) };
            for (inputs, 0..) |input, i| registers.at(i).* = f32Bits(input);
        }
        const outcome = try runtime.runWave(&program, .{});
        try std.testing.expectEqual(mask, outcome.returned_mask);
        if (mask == Runtime.full_lane_mask)
            try std.testing.expect(runtime.fastPathExecutedSteps() > 0);
        for (0..Runtime.lane_count) |lane| {
            const registers = runtime.laneRegisters(lane);
            if (mask & (@as(Runtime.LaneMask, 1) << @intCast(lane)) == 0) {
                try expectWords(&@as([5]u32, @splat(f32Bits(-99))), registers.slice(4, 9));
                continue;
            }
            try expectExpResult(0.6065306597126334, try bitsF32(registers.at(4).*));
            for (0..4) |i|
                try expectExpResult(@exp(try bitsF32(registers.at(i).*)), try bitsF32(registers.at(5 + i).*));
        }
    }
}

fn expectExpResult(expected: f32, actual: f32) !void {
    if (std.math.isNan(expected)) {
        try std.testing.expect(std.math.isNan(actual));
    } else if (std.math.isInf(expected) or expected == 0 or expected == 1) {
        try std.testing.expectEqual(expected, actual);
    } else {
        try std.testing.expectApproxEqRel(expected, actual, 0.000001);
    }
}

test "[interpreter] exp IR lowers scalar and vector f32 to bytecode" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    %scalar: constant f32 = -0.5
        \\    %vector: constant vec2[f32] = null
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %scalar_result: f32 = exp %scalar
        \\            %vector_result: vec2[f32] = exp %vector
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();
    try @import("liveness.zig").makeResultsObservable(&module);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 5), program.code.len);
    try std.testing.expectEqual(bc.Opcode.exp, program.code[0].opcode);
    try std.testing.expectEqual(bc.Opcode.exp, program.code[1].opcode);
    try std.testing.expectEqual(@as(u16, 1), program.code[0].components);
    try std.testing.expectEqual(@as(u16, 2), program.code[1].components);
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try expectExpResult(0.6065306597126334, try bitsF32(runtime.registers.at(@backingInt(program.code[0].a)).*));
    const vector_start = @backingInt(program.code[1].a);
    try expectWords(&.{ f32Bits(1), f32Bits(1) }, runtime.registers.slice(vector_start, vector_start + 2));
}

test "[interpreter] float remainder truncates and dot reduces vectors" {
    const code = [_]bc.Instruction{
        .{ .opcode = .float_remainder, .components = 3, .a = reg(6), .b = reg(0), .c = reg(3) },
        .{ .opcode = .dot, .components = 3, .a = reg(9), .b = reg(0), .c = reg(3) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 10);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const values = [_]u32{
        f32Bits(-5.5), f32Bits(2.0),  f32Bits(3.0),
        f32Bits(2.0),  f32Bits(-5.0), f32Bits(6.0),
    };
    copyWords(runtime.registers.slice(0, 6), &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    const expected_remainders = [_]f32{ -1.5, 2.0, 3.0 };

    for (expected_remainders, 0..) |expected, i|
        try std.testing.expectEqual(expected, try bitsF32(runtime.registers.at(6 + i).*));

    try std.testing.expectEqual(@as(f32, -3.0), try bitsF32(runtime.registers.at(9).*));
}

test "[interpreter] outer product and rectangular transpose are column-major" {
    const code = [_]bc.Instruction{
        .{ .opcode = .float_multiply, .a = reg(11), .b = reg(0), .c = reg(2) },
        .{ .opcode = .float_multiply, .a = reg(12), .b = reg(1), .c = reg(2) },
        .{ .opcode = .float_multiply, .a = reg(13), .b = reg(0), .c = reg(3) },
        .{ .opcode = .float_multiply, .a = reg(14), .b = reg(1), .c = reg(3) },
        .{ .opcode = .float_multiply, .a = reg(15), .b = reg(0), .c = reg(4) },
        .{ .opcode = .float_multiply, .a = reg(16), .b = reg(1), .c = reg(4) },
        .{ .opcode = .copy, .a = reg(17), .b = reg(5) },
        .{ .opcode = .copy, .a = reg(18), .b = reg(7) },
        .{ .opcode = .copy, .a = reg(19), .b = reg(9) },
        .{ .opcode = .copy, .a = reg(20), .b = reg(6) },
        .{ .opcode = .copy, .a = reg(21), .b = reg(8) },
        .{ .opcode = .copy, .a = reg(22), .b = reg(10) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 23);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const input = [_]u32{
        f32Bits(2), f32Bits(3),
        f32Bits(4), f32Bits(5),
        f32Bits(6), f32Bits(1),
        f32Bits(2), f32Bits(3),
        f32Bits(4), f32Bits(5),
        f32Bits(6),
    };
    copyWords(runtime.registers.slice(0, 11), &input);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    const expected_outer = [_]f32{ 8, 12, 10, 15, 12, 18 };
    const expected_transpose = [_]f32{ 1, 3, 5, 2, 4, 6 };

    for (expected_outer, 0..) |expected, i|
        try std.testing.expectEqual(expected, try bitsF32(runtime.registers.at(11 + i).*));

    for (expected_transpose, 0..) |expected, i|
        try std.testing.expectEqual(expected, try bitsF32(runtime.registers.at(17 + i).*));
}

test "[interpreter] malformed floating bytecode returns an error" {
    const code = [_]bc.Instruction{
        .{
            .opcode = .float_multiply,
            .components = 6,
            .a = reg(0),
            .b = reg(6),
            .c = reg(0),
        },
    };
    var program = bytecodeProgram(&code, 11);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try std.testing.expectError(Runtime.RuntimeError.InvalidBytecode, runtime.run(&program, .{}));
}

test "[interpreter] shared floating IR lowers to bytecode" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    %scalar: constant f32 = null
        \\    %vector2: constant vec2[f32] = null
        \\    %vector3: constant vec3[f32] = null
        \\    %unsigned2: constant vec2[u32] = null
        \\    %matrix: constant mat3x2[f32] = null
        \\    %zero: constant f32 = null
        \\    %one: constant f32 = bits(0x3f800000)
        \\    %two: constant f32 = bits(0x40000000)
        \\    %three: constant f32 = bits(0x40400000)
        \\    %negative_one: constant f32 = bits(0xbf800000)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %infinite: bool = is_inf %scalar
        \\            %nan: vec2[bool] = is_nan %vector2
        \\            %selected: vec2[u32] = select %nan, %unsigned2, %unsigned2
        \\            %absolute_result: f32 = float_absolute %scalar
        \\            %floor_result: f32 = floor %scalar
        \\            %zero2: vec2[f32] = composite_construct %zero, %zero
        \\            %one2: vec2[f32] = composite_construct %one, %one
        \\            %negative_one2: vec2[f32] = composite_construct %negative_one, %negative_one
        \\            %negative: vec2[bool] = cmp_ordered_float_less %vector2, %zero2
        \\            %positive: vec2[bool] = cmp_ordered_float_less %zero2, %vector2
        \\            %nonpositive_sign: vec2[f32] = select %negative, %negative_one2, %zero2
        \\            %sign_result: vec2[f32] = select %positive, %one2, %nonpositive_sign
        \\            %squared_length: f32 = dot %vector2, %vector2
        \\            %inverse_length: f32 = inverse_sqrt %squared_length
        \\            %inverse_length2: vec2[f32] = composite_construct %inverse_length, %inverse_length
        \\            %normalized: vec2[f32] = float_multiply %vector2, %inverse_length2
        \\            %angle: f32 = atan2 %scalar, %scalar
        \\            %powered: vec2[f32] = pow %vector2, %vector2
        \\            %maximum: vec2[f32] = float_max %vector2, %vector2
        \\            %numerator: f32 = float_subtract %scalar, %zero
        \\            %denominator: f32 = float_subtract %one, %zero
        \\            %ratio: f32 = float_divide %numerator, %denominator
        \\            %lower_bounded: f32 = float_max %ratio, %zero
        \\            %t: f32 = float_min %lower_bounded, %one
        \\            %squared: f32 = float_multiply %t, %t
        \\            %twice: f32 = float_multiply %two, %t
        \\            %factor: f32 = float_subtract %three, %twice
        \\            %smooth: f32 = float_multiply %squared, %factor
        \\            %remainder: f32 = float_remainder %scalar, %scalar
        \\            %dot_result: f32 = dot %vector2, %vector2
        \\            %v0: f32 = composite_extract %vector3[0]
        \\            %v1: f32 = composite_extract %vector3[1]
        \\            %v2: f32 = composite_extract %vector3[2]
        \\            %v0_splat: vec2[f32] = composite_construct %v0, %v0
        \\            %v1_splat: vec2[f32] = composite_construct %v1, %v1
        \\            %v2_splat: vec2[f32] = composite_construct %v2, %v2
        \\            %outer0: vec2[f32] = float_multiply %vector2, %v0_splat
        \\            %outer1: vec2[f32] = float_multiply %vector2, %v1_splat
        \\            %outer2: vec2[f32] = float_multiply %vector2, %v2_splat
        \\            %outer: mat3x2[f32] = composite_construct %outer0, %outer1, %outer2
        \\            %m00: f32 = composite_extract %matrix[0][0]
        \\            %m10: f32 = composite_extract %matrix[1][0]
        \\            %m20: f32 = composite_extract %matrix[2][0]
        \\            %m01: f32 = composite_extract %matrix[0][1]
        \\            %m11: f32 = composite_extract %matrix[1][1]
        \\            %m21: f32 = composite_extract %matrix[2][1]
        \\            %transposed0: vec3[f32] = composite_construct %m00, %m10, %m20
        \\            %transposed1: vec3[f32] = composite_construct %m01, %m11, %m21
        \\            %transposed: mat2x3[f32] = composite_construct %transposed0, %transposed1
        \\            %signed: vec2[i32] = convert float_to_signed %vector2
        \\            %unsigned: vec3[u32] = convert float_to_unsigned %vector3
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    try @import("liveness.zig").makeResultsObservable(&module);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    const expected = [_]struct { bc.Opcode, u8 }{
        .{ .is_inf, 1 },
        .{ .is_nan, 2 },
        .{ .select, 2 },
        .{ .float_absolute, 1 },
        .{ .floor, 1 },
        .{ .compare_ordered_float_less, 2 },
        .{ .compare_ordered_float_less, 2 },
        .{ .select, 2 },
        .{ .select, 2 },
        .{ .dot, 2 },
        .{ .inverse_sqrt, 1 },
        .{ .float_multiply, 2 },
        .{ .atan2, 1 },
        .{ .pow, 2 },
        .{ .float_max, 2 },
        .{ .float_subtract, 1 },
        .{ .float_subtract, 1 },
        .{ .float_divide, 1 },
        .{ .float_max, 1 },
        .{ .float_min, 1 },
        .{ .float_multiply, 1 },
        .{ .float_multiply, 1 },
        .{ .float_subtract, 1 },
        .{ .float_multiply, 1 },
        .{ .float_remainder, 1 },
        .{ .dot, 2 },
        .{ .float_multiply, 2 },
        .{ .float_multiply, 2 },
        .{ .float_multiply, 2 },
        .{ .float_to_signed, 2 },
        .{ .float_to_unsigned, 3 },
        .{ .return_void, 1 },
    };
    var index: usize = 0;
    var matrix_copies: usize = 0;
    var column_copies: usize = 0;
    for (program.code) |instruction| {
        if (instruction.opcode == .copy) {
            if (instruction.components == 6) matrix_copies += 1;
            if (instruction.components == 3) column_copies += 1;
            continue;
        }
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqual(expected[index][0], instruction.opcode);
        try std.testing.expectEqual(expected[index][1], instruction.components);
        if (instruction.opcode == .select)
            try std.testing.expectEqual(@as(u32, 1), instruction.immediate);
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
    try std.testing.expect(matrix_copies >= 2);
    try std.testing.expect(column_copies >= 2);
}

test "[interpreter] length scalar absolute value and vector magnitude, dynamic extraction" {
    const code = [_]bc.Instruction{
        .{ .opcode = .float_absolute, .a = reg(5), .b = reg(0) },
        .{ .opcode = .dot, .components = 2, .a = reg(6), .b = reg(1), .c = reg(1) },
        .{ .opcode = .sqrt, .a = reg(6), .b = reg(6) },
        .{ .opcode = .vector_extract_dynamic, .components = 2, .a = reg(7), .b = reg(1), .c = reg(3) },
        .{ .opcode = .vector_extract_dynamic, .components = 2, .a = reg(8), .b = reg(1), .c = reg(4) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 9);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    copyWords(runtime.registers.slice(0, 5), &[_]u32{ f32Bits(-7), f32Bits(3), f32Bits(4), 0, 1 });
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try expectWords(&.{ f32Bits(7), f32Bits(5), f32Bits(3), f32Bits(4) }, runtime.registers.slice(5, 9));
    runtime.registers.at(3).* = @as(u32, @bitCast(@as(i32, -1)));
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, 0), runtime.registers.at(7).*);
    runtime.registers.at(3).* = 2;
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, 0), runtime.registers.at(7).*);
    runtime.registers.at(3).* = 0;
    runtime.registers.at(4).* = std.math.maxInt(u32);
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, f32Bits(3)), runtime.registers.at(7).*);
    try std.testing.expectEqual(@as(bc.Slot, 0), runtime.registers.at(8).*);
}

test "[interpreter] nonlinear scalar and vector fwidth uses same-instruction quad values and helper masks" {
    const code = [_]bc.Instruction{
        .{ .opcode = .float_multiply, .components = 2, .a = reg(2), .b = reg(0), .c = reg(0) },
        .{ .opcode = .fwidth, .components = 2, .a = reg(4), .b = reg(2) },
        .{ .opcode = .fwidth, .a = reg(6), .b = reg(2) },
        .{ .opcode = .float_multiply, .a = reg(8), .b = reg(2), .c = reg(3) },
        .{ .opcode = .fwidth, .a = reg(9), .b = reg(8) },
        .{ .opcode = .store_buffer, .a = reg(9), .b = reg(7), .immediate = 0 },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 10);
    program.stage = .fragment;
    program.resources = &.{.{ .kind = .storage_buffer, .set = 0, .binding = 0, .array_element = 0 }};
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    const values = [4][2]f32{ .{ 1, 2 }, .{ 2, 2 }, .{ 1, 3 }, .{ 2, 3 } };
    var buffer: [Runtime.lane_count * 4]u8 = @splat(0xaa);
    for (0..Runtime.lane_count) |observable_lane| {
        runtime.resetWave(&program, Runtime.full_lane_mask, @as(Runtime.LaneMask, 1) << @intCast(observable_lane));
        for (0..Runtime.lane_count) |lane| {
            const value = values[lane % 4];
            const registers = runtime.laneRegisters(lane);
            registers.at(0).* = f32Bits(value[0]);
            registers.at(1).* = f32Bits(value[1]);
            registers.at(7).* = @intCast(lane * 4);
        }
        @memset(&buffer, 0xaa);
        const outcome = try runtime.runWave(&program, .{ .resource_buffers = &.{&buffer} });
        try std.testing.expectEqual(Runtime.full_lane_mask, outcome.returned_mask);
        for (0..Runtime.lane_count) |lane| {
            const registers = runtime.laneRegisters(lane);
            try expectWords(&.{ f32Bits(3), f32Bits(5), f32Bits(3) }, registers.slice(4, 7));
            const expected_scalar = [_]f32{ 17, 32, 32, 47 };
            try std.testing.expectEqual(@as(bc.Slot, f32Bits(expected_scalar[lane % 4])), registers.at(9).*);
            try std.testing.expectEqual(if (lane == observable_lane) f32Bits(expected_scalar[lane % 4]) else @as(u32, 0xaaaaaaaa), std.mem.readInt(u32, buffer[lane * 4 ..][0..4], .little));
        }
    }
    runtime.resetWave(&program, 0b0111, 0b0001);
    try std.testing.expectError(error.DerivativeUnavailable, runtime.runWave(&program, .{}));
    runtime.resetWave(&program, 0, 0);
    const inactive = try runtime.runWave(&program, .{});
    try std.testing.expectEqual(@as(Runtime.LaneMask, 0), inactive.returned_mask);
}

test "[interpreter] signed nonlinear derivatives preserve quad pairs, aliases, and helper masks" {
    for ([_]bc.Opcode{ .d_pdx, .d_pdx_coarse, .d_pdy, .fwidth_coarse, .fwidth_fine }) |opcode| {
        const code = [_]bc.Instruction{
            .{ .opcode = .float_multiply, .components = 2, .a = reg(2), .b = reg(0), .c = reg(0) },
            .{ .opcode = .copy, .a = reg(0), .b = reg(2) },
            .{ .opcode = opcode, .components = 2, .a = reg(4), .b = reg(2) },
            .{ .opcode = opcode, .a = reg(6), .b = reg(2) },
            .{ .opcode = opcode, .a = reg(0), .b = reg(0) },
            .{ .opcode = opcode, .components = 2, .a = reg(2), .b = reg(2) },
            .{ .opcode = .store_buffer, .a = reg(6), .b = reg(7), .immediate = 0 },
            .{ .opcode = .return_void },
        };
        var program = bytecodeProgram(&code, 8);
        defer program.deinit();
        program.stage = .fragment;
        program.uses_derivatives = true;
        program.resources = &.{.{ .kind = .storage_buffer, .set = 0, .binding = 0, .array_element = 0 }};
        var runtime = try Runtime.init(std.testing.allocator, &program);
        defer runtime.deinit();
        const values = [4][2]f32{ .{ -3, 2 }, .{ 1, -1 }, .{ -2, -4 }, .{ 4, 3 } };
        const differences: [4][2]f32 = switch (opcode) {
            .d_pdx => .{ .{ -8, -3 }, .{ -8, -3 }, .{ 12, -7 }, .{ 12, -7 } },
            .d_pdx_coarse => @splat(.{ -8, -3 }),
            .d_pdy => .{ .{ -5, 12 }, .{ 15, 8 }, .{ -5, 12 }, .{ 15, 8 } },
            .fwidth_coarse => @splat(.{ 13, 15 }),
            .fwidth_fine => .{ .{ 13, 15 }, .{ 23, 11 }, .{ 17, 19 }, .{ 27, 15 } },
            else => unreachable,
        };
        var buffer: [Runtime.lane_count * 4]u8 = undefined;
        // The extra case leaves the second quad wholly inactive on eight-lane waves.
        for (0..Runtime.lane_count + 1) |case| {
            const observable_lane = case % Runtime.lane_count;
            const execution_mask: Runtime.LaneMask = if (case == Runtime.lane_count) 0b1111 else Runtime.full_lane_mask;
            runtime.resetWave(&program, execution_mask, @as(Runtime.LaneMask, 1) << @intCast(observable_lane));
            for (0..Runtime.lane_count) |lane| {
                const registers = runtime.laneRegisters(lane);
                registers.fill(0xaaaaaaaa);
                const scale: f32 = @floatFromInt(lane / 4 + 1);
                registers.at(0).* = f32Bits(values[lane % 4][0] * scale);
                registers.at(1).* = f32Bits(values[lane % 4][1] * scale);
                registers.at(7).* = @intCast(lane * 4);
            }
            @memset(&buffer, 0xaa);
            const outcome = try runtime.runWave(&program, .{ .resource_buffers = &.{&buffer} });
            try std.testing.expectEqual(execution_mask, outcome.returned_mask);
            for (0..Runtime.lane_count) |lane| {
                const registers = runtime.laneRegisters(lane);
                const scale: f32 = @floatFromInt(lane / 4 + 1);
                const expected = [2]u32{ f32Bits(differences[lane % 4][0] * scale * scale), f32Bits(differences[lane % 4][1] * scale * scale) };
                if ((execution_mask & (@as(Runtime.LaneMask, 1) << @intCast(lane))) != 0) {
                    try expectWords(&expected, registers.slice(2, 4));
                    try expectWords(&expected, registers.slice(4, 6));
                    try std.testing.expectEqual(@as(bc.Slot, expected[0]), registers.at(0).*);
                    try std.testing.expectEqual(@as(bc.Slot, expected[0]), registers.at(6).*);
                } else {
                    try expectWords(&@as([5]u32, @splat(0xaaaaaaaa)), registers.slice(2, 7));
                }
                try std.testing.expectEqual(if (lane == observable_lane) expected[0] else @as(u32, 0xaaaaaaaa), std.mem.readInt(u32, buffer[lane * 4 ..][0..4], .little));
            }
        }
        for ([_]Runtime.LaneMask{ 0b0111, 0b1011, 0b1101, 0b1110 }) |mask| {
            runtime.resetWave(&program, mask, mask);
            try std.testing.expectError(error.DerivativeUnavailable, runtime.runWave(&program, .{}));
        }
        runtime.resetWave(&program, 0, 0);
        try std.testing.expectEqual(@as(Runtime.LaneMask, 0), (try runtime.runWave(&program, .{})).returned_mask);
    }
}

test "[interpreter] each derivative alone lowers scalar and vector results and excludes dead derivatives" {
    for ([_]bc.Opcode{ .d_pdx, .d_pdx_coarse, .d_pdy, .fwidth_coarse, .fwidth_fine }) |opcode| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\shader fragment @main
            \\{{
            \\    %scalar: constant f32 = null
            \\    %vector: constant vec2[f32] = null
            \\    fn @main() -> void
            \\    {{
            \\        .entry():
            \\            %ds: f32 = {s} %scalar
            \\            %dv: vec2[f32] = {s} %vector
            \\            return
            \\    }}
            \\}}
        , .{ @tagName(opcode), @tagName(opcode) });
        defer std.testing.allocator.free(source);
        var module = try ir.parser.parseString(std.testing.allocator, source);
        defer module.deinit();
        var dead = try Program.compile(std.testing.allocator, &module);
        defer dead.deinit();
        try std.testing.expect(!dead.uses_derivatives);
        try std.testing.expectEqual(@as(usize, 1), dead.code.len);
        try std.testing.expectEqual(bc.Opcode.return_void, dead.code[0].opcode);
        try @import("liveness.zig").makeResultsObservable(&module);
        var program = try Program.compile(std.testing.allocator, &module);
        defer program.deinit();
        try std.testing.expect(program.uses_derivatives);
        try std.testing.expectEqual(@as(usize, 5), program.code.len);
        for (program.code[0..2], 1..) |instruction, components| {
            try std.testing.expectEqual(opcode, instruction.opcode);
            try std.testing.expectEqual(@as(u16, @intCast(components)), instruction.components);
        }
    }
}

test "[interpreter] new shared operations lower for fragment execution and signed or unsigned extraction" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader fragment @main
        \\{
        \\    %scalar: constant f32 = null
        \\    %vector: constant vec2[f32] = null
        \\    %signed: constant i32 = null
        \\    %unsigned: constant u32 = null
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %ls: f32 = float_absolute %scalar
        \\            %squared: f32 = dot %vector, %vector
        \\            %lv: f32 = sqrt %squared
        \\            %ds: f32 = fwidth %scalar
        \\            %dv: vec2[f32] = fwidth %vector
        \\            %es: f32 = vector_extract_dynamic %vector, %signed
        \\            %eu: f32 = vector_extract_dynamic %vector, %unsigned
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();
    try @import("liveness.zig").makeResultsObservable(&module);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expect(program.uses_derivatives);
    const expected = [_]bc.Opcode{ .float_absolute, .dot, .sqrt, .fwidth, .fwidth, .vector_extract_dynamic, .vector_extract_dynamic, .return_void };
    try std.testing.expectEqual(2 * (expected.len - 1) + 1, program.code.len);
    try std.testing.expectEqual(bc.Opcode.return_void, program.code[program.code.len - 1].opcode);
    for (program.code[0 .. expected.len - 1], expected[0 .. expected.len - 1]) |instruction, opcode|
        try std.testing.expectEqual(opcode, instruction.opcode);
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    _ = try runtime.runWave(&program, .{});
}

test "[interpreter] derivatives park early arrivals until nonuniform branch arms reconverge" {
    var code = [_]bc.Instruction{
        .{ .opcode = .branch, .a = reg(0), .immediate = 0 },
        .{ .opcode = .float_multiply, .a = reg(3), .b = reg(1), .c = reg(2) },
        .{ .opcode = .jump_edge, .immediate = 2 },
        .{ .opcode = .float_add, .a = reg(3), .b = reg(1), .c = reg(2) },
        .{ .opcode = .float_multiply, .a = reg(3), .b = reg(3), .c = reg(2) },
        .{ .opcode = .jump_edge, .immediate = 2 },
        .{ .opcode = .fwidth, .a = reg(4), .b = reg(3) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 5);
    defer program.deinit();
    program.stage = .fragment;
    program.branches = &.{.{ .true_edge = 0, .false_edge = 1 }};
    program.edges = &.{
        .{ .target_block = 1, .target_pc = 1, .first_copy = 0, .copy_count = 0 },
        .{ .target_block = 2, .target_pc = 3, .first_copy = 0, .copy_count = 0 },
        .{ .target_block = 3, .target_pc = 6, .first_copy = 0, .copy_count = 0 },
    };
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    for ([_]bc.Opcode{ .fwidth, .fwidth_coarse, .fwidth_fine, .d_pdx, .d_pdx_coarse, .d_pdy }) |opcode| {
        code[6].opcode = opcode;
        for (0..3) |flip| {
            runtime.resetWave(&program, Runtime.full_lane_mask, 1);
            var values: [Runtime.lane_count]f32 = undefined;
            for (0..Runtime.lane_count) |lane| {
                const registers = runtime.laneRegisters(lane);
                // On wide waves the last case lets the second quad finish while the first waits
                registers.at(0).* = @intFromBool((lane + flip) % 2 == 0 or (flip == 2 and lane >= 4));
                const value: f32 = @floatFromInt(lane % 4 + 1);
                registers.at(1).* = f32Bits(value);
                registers.at(2).* = f32Bits(2);
                values[lane] = if (registers.at(0).* != 0) value * 2 else (value + 2) * 2;
            }
            const outcome = try runtime.runWave(&program, .{ .max_steps = 100 });
            try std.testing.expectEqual(Runtime.full_lane_mask, outcome.returned_mask);
            for (0..Runtime.lane_count) |lane| {
                const registers = runtime.laneRegisters(lane);
                const dx = values[lane | 1] - values[lane & ~@as(usize, 1)];
                const dy = values[lane | 2] - values[lane & ~@as(usize, 2)];
                const expected = switch (opcode) {
                    .d_pdx => dx,
                    .d_pdx_coarse => values[(lane & ~@as(usize, 3)) | 1] - values[lane & ~@as(usize, 3)],
                    .d_pdy => dy,
                    .fwidth, .fwidth_fine => @abs(dx) + @abs(dy),
                    .fwidth_coarse => blk: {
                        const base = lane & ~@as(usize, 3);
                        break :blk @abs(values[base | 1] - values[base]) + @abs(values[base | 2] - values[base]);
                    },
                    else => unreachable,
                };
                try std.testing.expectEqual(@as(bc.Slot, f32Bits(expected)), registers.at(4).*);
            }
        }
    }
}

test "[interpreter] parked derivatives reject terminated or incompatible peers and bound looping peers" {
    var code = [_]bc.Instruction{
        .{ .opcode = .fwidth, .a = reg(1), .b = reg(0) },
        .{ .opcode = .return_void, .a = reg(1), .b = reg(0), .immediate = 0 },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 2);
    defer program.deinit();
    program.stage = .fragment;
    program.edges = &.{.{ .target_block = 1, .target_pc = 1, .first_copy = 0, .copy_count = 0 }};
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    for ([_]bc.Opcode{ .fwidth, .fwidth_coarse, .fwidth_fine, .d_pdx, .d_pdx_coarse, .d_pdy }) |opcode| {
        code[0].opcode = opcode;
        for ([_]bc.Opcode{ .return_void, .discard, .control_barrier, .fwidth, .fwidth_coarse, .fwidth_fine, .d_pdx, .d_pdx_coarse, .d_pdy, .jump_edge }) |peer_opcode| {
            code[1].opcode = peer_opcode;
            runtime.resetWave(&program, 0b1111, 1);
            for (1..4) |lane| runtime.pcs[lane] = 1;
            const expected = if (peer_opcode == .jump_edge) error.StepLimitExceeded else error.DerivativeUnavailable;
            try std.testing.expectError(expected, runtime.runWave(&program, .{ .max_steps = 12 }));
        }
    }
}

test "[interpreter] helper OOB extraction produces lane-local zero without aborting observable output" {
    const code = [_]bc.Instruction{
        .{ .opcode = .vector_extract_dynamic, .components = 2, .a = reg(3), .b = reg(0), .c = reg(2) },
        .{ .opcode = .fwidth, .a = reg(5), .b = reg(3) },
        .{ .opcode = .store_buffer, .a = reg(3), .b = reg(4), .immediate = 0 },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 6);
    defer program.deinit();
    program.stage = .fragment;
    program.resources = &.{.{ .kind = .storage_buffer, .set = 0, .binding = 0, .array_element = 0 }};
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    const indices = [_]u32{ 1, @bitCast(@as(i32, -1)), 2, std.math.maxInt(u32) };
    var buffer: [16]u8 = @splat(0xaa);
    runtime.resetWave(&program, 0b1111, 1);
    for (indices, 0..) |index, lane| {
        const registers = runtime.laneRegisters(lane);
        registers.at(0).* = f32Bits(3);
        registers.at(1).* = f32Bits(4);
        registers.at(2).* = index;
        registers.at(4).* = @intCast(lane * 4);
    }
    const outcome = try runtime.runWave(&program, .{ .resource_buffers = &.{&buffer} });
    try std.testing.expectEqual(@as(Runtime.LaneMask, 0b1111), outcome.returned_mask);
    try std.testing.expectEqual(f32Bits(4), std.mem.readInt(u32, buffer[0..4], .little));
    try std.testing.expectEqualSlices(u8, &@as([12]u8, @splat(0xaa)), buffer[4..]);
    const widths = [_]f32{ 8, 4, 4, 0 };
    for (widths, 0..) |width, lane| {
        const registers = runtime.laneRegisters(lane);
        try std.testing.expectEqual(@as(bc.Slot, if (lane == 0) f32Bits(4) else @as(u32, 0)), registers.at(3).*);
        try std.testing.expectEqual(@as(bc.Slot, f32Bits(width)), registers.at(5).*);
    }
}

test "[interpreter] dynamic extraction still rejects malformed bytecode register spans" {
    var code = [_]bc.Instruction{
        .{ .opcode = .vector_extract_dynamic, .components = 2, .a = reg(3), .b = reg(0), .c = reg(2) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 4);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    runtime.registers.at(2).* = std.math.maxInt(u32);
    for (0..4) |operand| {
        code[0].components = if (operand == 3) 0 else 2;
        code[0].a = if (operand == 0) reg(4) else reg(3);
        code[0].b = if (operand == 1) reg(3) else reg(0);
        code[0].c = if (operand == 2) reg(4) else reg(2);
        try std.testing.expectError(error.InvalidBytecode, runtime.run(&program, .{}));
    }
}

test "[interpreter] lowered float clamp executes max then min component-wise" {
    const code = [_]bc.Instruction{
        .{ .opcode = .float_max, .components = 3, .a = reg(9), .b = reg(0), .c = reg(3) },
        .{ .opcode = .float_min, .components = 3, .a = reg(12), .b = reg(9), .c = reg(6) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 15);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    for (0..Runtime.lane_count) |lane| {
        const registers = runtime.laneRegisters(lane);
        copyWords(registers.slice(0, 9), &[_]u32{ f32Bits(-1), f32Bits(0.5), f32Bits(2), f32Bits(0), f32Bits(0), f32Bits(0), f32Bits(1), f32Bits(1), f32Bits(1) });
    }
    _ = try runtime.runWave(&program, .{});
    for (0..Runtime.lane_count) |lane| {
        const registers = runtime.laneRegisters(lane);
        try expectWords(&.{ f32Bits(0), f32Bits(0.5), f32Bits(1) }, registers.slice(12, 15));
    }
}
