const std = @import("std");
const shader_ir = @import("shader_ir");

const bc = @import("../bytecode.zig");
const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ir = shader_ir.ir;

inline fn reg(index: u16) bc.Register {
    return @fromBackingInt(index);
}

inline fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

inline fn bitsF32(value: u32) f32 {
    return @bitCast(value);
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
    @memcpy(runtime.registers[0..4], &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(u32, 1), runtime.registers[4]);
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 0, 0 }, runtime.registers[5..9]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 0 }, runtime.registers[9..13]);
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
    @memcpy(runtime.registers[0..12], &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqualSlices(u32, &.{ 10, 11, 12, 13 }, runtime.registers[12..16]);
    try std.testing.expectEqualSlices(u32, &.{ 10, 21, 12, 23 }, runtime.registers[16..20]);
}

test "[interpreter] GLSL extended floating operations execute component-wise" {
    const code = [_]bc.Instruction{
        .{ .opcode = .absolute, .a = reg(8), .b = reg(0) },
        .{ .opcode = .normalize, .components = 2, .a = reg(9), .b = reg(1) },
        .{ .opcode = .smooth_step, .a = reg(11), .b = reg(3), .c = reg(4), .d = reg(5) },
        .{ .opcode = .atan2, .a = reg(12), .b = reg(6), .c = reg(7) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 13);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const values = [_]u32{
        f32Bits(-2.0),
        f32Bits(3.0),
        f32Bits(4.0),
        f32Bits(0.0),
        f32Bits(1.0),
        f32Bits(0.25),
        f32Bits(1.0),
        f32Bits(1.0),
    };
    @memcpy(runtime.registers[0..8], &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(f32, 2.0), bitsF32(runtime.registers[8]));
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), bitsF32(runtime.registers[9]), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), bitsF32(runtime.registers[10]), 0.00001);
    try std.testing.expectEqual(@as(f32, 0.15625), bitsF32(runtime.registers[11]));
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), bitsF32(runtime.registers[12]), 0.00001);
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
    @memcpy(runtime.registers[0..6], &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    const expected_remainders = [_]f32{ -1.5, 2.0, 3.0 };

    for (runtime.registers[6..9], expected_remainders) |actual, expected|
        try std.testing.expectEqual(expected, bitsF32(actual));

    try std.testing.expectEqual(@as(f32, -3.0), bitsF32(runtime.registers[9]));
}

test "[interpreter] outer product and rectangular transpose are column-major" {
    const dimensions = bc.MatrixDimensions{ .rows = 2, .inner = 0, .columns = 3 };
    const code = [_]bc.Instruction{
        .{ .opcode = .outer_product, .components = 6, .a = reg(11), .b = reg(0), .c = reg(2), .immediate = dimensions.encode() },
        .{ .opcode = .transpose, .components = 6, .a = reg(17), .b = reg(5), .immediate = dimensions.encode() },
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
    @memcpy(runtime.registers[0..11], &input);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    const expected_outer = [_]f32{ 8, 12, 10, 15, 12, 18 };
    const expected_transpose = [_]f32{ 1, 3, 5, 2, 4, 6 };

    for (runtime.registers[11..17], expected_outer) |actual, expected|
        try std.testing.expectEqual(expected, bitsF32(actual));

    for (runtime.registers[17..23], expected_transpose) |actual, expected|
        try std.testing.expectEqual(expected, bitsF32(actual));
}

test "[interpreter] malformed floating bytecode returns an error" {
    const code = [_]bc.Instruction{
        .{
            .opcode = .transpose,
            .components = 5,
            .a = reg(0),
            .b = reg(5),
            .immediate = (bc.MatrixDimensions{ .rows = 2, .inner = 0, .columns = 3 }).encode(),
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
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %infinite: bool = is_inf %scalar
        \\            %nan: vec2[bool] = is_nan %vector2
        \\            %selected: vec2[u32] = select %nan, %unsigned2, %unsigned2
        \\            %absolute_result: f32 = absolute %scalar
        \\            %normalized: vec2[f32] = normalize %vector2
        \\            %angle: f32 = atan2 %scalar, %scalar
        \\            %smooth: f32 = smooth_step %scalar, %scalar, %scalar
        \\            %remainder: f32 = float_remainder %scalar, %scalar
        \\            %dot_result: f32 = dot %vector2, %vector2
        \\            %outer: mat3x2[f32] = outer_product %vector2, %vector3
        \\            %transposed: mat2x3[f32] = transpose %matrix
        \\            %signed: vec2[i32] = convert float_to_signed %vector2
        \\            %unsigned: vec3[u32] = convert float_to_unsigned %vector3
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    const expected = [_]bc.Opcode{
        .is_inf,
        .is_nan,
        .select,
        .absolute,
        .normalize,
        .atan2,
        .smooth_step,
        .float_remainder,
        .dot,
        .outer_product,
        .transpose,
        .float_to_signed,
        .float_to_unsigned,
        .return_void,
    };
    try std.testing.expectEqual(expected.len, program.code.len);

    for (program.code, expected) |instruction, opcode|
        try std.testing.expectEqual(opcode, instruction.opcode);

    try std.testing.expectEqual(@as(u16, 2), program.code[1].components);
    try std.testing.expectEqual(@as(u32, 1), program.code[2].immediate);
    try std.testing.expectEqual(@as(u16, 2), program.code[4].components);
    try std.testing.expectEqual(@as(u16, 2), program.code[8].components);
    try std.testing.expectEqual(@as(u16, 6), program.code[9].components);
    try std.testing.expectEqual(bc.MatrixDimensions{ .rows = 2, .inner = 0, .columns = 3 }, bc.MatrixDimensions.decode(program.code[9].immediate));
    try std.testing.expectEqual(bc.MatrixDimensions{ .rows = 2, .inner = 0, .columns = 3 }, bc.MatrixDimensions.decode(program.code[10].immediate));
}
