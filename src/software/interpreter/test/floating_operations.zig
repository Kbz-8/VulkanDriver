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
    copyWords(runtime.registers[0..4], &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, 1), runtime.registers[4]);
    try expectWords(&.{ 1, 1, 0, 0 }, runtime.registers[5..9]);
    try expectWords(&.{ 0, 0, 1, 0 }, runtime.registers[9..13]);
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
    copyWords(runtime.registers[0..12], &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try expectWords(&.{ 10, 11, 12, 13 }, runtime.registers[12..16]);
    try expectWords(&.{ 10, 21, 12, 23 }, runtime.registers[16..20]);
}

test "[interpreter] GLSL extended floating operations execute component-wise" {
    const code = [_]bc.Instruction{
        .{ .opcode = .float_absolute, .a = reg(8), .b = reg(0) },
        .{ .opcode = .float_sign, .components = 4, .a = reg(13), .b = reg(0) },
        .{ .opcode = .normalize, .components = 2, .a = reg(9), .b = reg(1) },
        .{ .opcode = .smooth_step, .a = reg(11), .b = reg(3), .c = reg(4), .d = reg(5) },
        .{ .opcode = .atan2, .a = reg(12), .b = reg(6), .c = reg(7) },
        .{ .opcode = .pow, .a = reg(17), .b = reg(1), .c = reg(2) },
        .{ .opcode = .float_max, .a = reg(18), .b = reg(0), .c = reg(4) },
        .{ .opcode = .floor, .a = reg(19), .b = reg(0) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 20);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

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
    copyWords(runtime.registers[0..8], &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(f32, 2.25), try bitsF32(runtime.registers[8]));
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), try bitsF32(runtime.registers[9]), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), try bitsF32(runtime.registers[10]), 0.00001);
    try std.testing.expectEqual(@as(f32, 0.15625), try bitsF32(runtime.registers[11]));
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), try bitsF32(runtime.registers[12]), 0.00001);
    try expectWords(&.{ f32Bits(-1.0), f32Bits(1.0), f32Bits(1.0), f32Bits(0.0) }, runtime.registers[13..17]);
    try std.testing.expectEqual(@as(f32, 81.0), try bitsF32(runtime.registers[17]));
    try std.testing.expectEqual(@as(f32, 1.0), try bitsF32(runtime.registers[18]));
    try std.testing.expectEqual(@as(f32, -3.0), try bitsF32(runtime.registers[19]));
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
        for (inputs, 0..) |input, i| runtime.registers[i] = f32Bits(input);
        try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
        try expectExpResult(results[0], try bitsF32(runtime.registers[4]));
        for (results, runtime.registers[5..9]) |result, actual|
            try expectExpResult(result, try bitsF32(actual));
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
            const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
            @memset(registers[4..9], f32Bits(-99));
            const inputs = [_]f32{ -0.5, @as(f32, @floatFromInt(lane)), -std.math.inf(f32), std.math.nan(f32) };
            for (inputs, 0..) |input, i| registers[i] = f32Bits(input);
        }
        const outcome = try runtime.runWave(&program, .{});
        try std.testing.expectEqual(mask, outcome.returned_mask);
        if (mask == Runtime.full_lane_mask)
            try std.testing.expect(runtime.fastPathExecutedSteps() > 0);
        for (0..Runtime.lane_count) |lane| {
            const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
            if (mask & (@as(Runtime.LaneMask, 1) << @intCast(lane)) == 0) {
                for (registers[4..9]) |actual| try std.testing.expectEqual(@as(bc.Slot, f32Bits(-99)), actual);
                continue;
            }
            try expectExpResult(0.6065306597126334, try bitsF32(registers[4]));
            for (registers[0..4], registers[5..9]) |input, actual|
                try expectExpResult(@exp(try bitsF32(input)), try bitsF32(actual));
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
    try expectExpResult(0.6065306597126334, try bitsF32(runtime.registers[@backingInt(program.code[0].a)]));
    const vector_start = @backingInt(program.code[1].a);
    try expectWords(&.{ f32Bits(1), f32Bits(1) }, runtime.registers[vector_start..][0..2]);
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
    copyWords(runtime.registers[0..6], &values);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    const expected_remainders = [_]f32{ -1.5, 2.0, 3.0 };

    for (runtime.registers[6..9], expected_remainders) |actual, expected|
        try std.testing.expectEqual(expected, try bitsF32(actual));

    try std.testing.expectEqual(@as(f32, -3.0), try bitsF32(runtime.registers[9]));
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
    copyWords(runtime.registers[0..11], &input);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    const expected_outer = [_]f32{ 8, 12, 10, 15, 12, 18 };
    const expected_transpose = [_]f32{ 1, 3, 5, 2, 4, 6 };

    for (runtime.registers[11..17], expected_outer) |actual, expected|
        try std.testing.expectEqual(expected, try bitsF32(actual));

    for (runtime.registers[17..23], expected_transpose) |actual, expected|
        try std.testing.expectEqual(expected, try bitsF32(actual));
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
        \\            %absolute_result: f32 = float_absolute %scalar
        \\            %floor_result: f32 = floor %scalar
        \\            %sign_result: vec2[f32] = float_sign %vector2
        \\            %normalized: vec2[f32] = normalize %vector2
        \\            %angle: f32 = atan2 %scalar, %scalar
        \\            %powered: vec2[f32] = pow %vector2, %vector2
        \\            %maximum: vec2[f32] = float_max %vector2, %vector2
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

    try @import("liveness.zig").makeResultsObservable(&module);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    const expected = [_]bc.Opcode{
        .is_inf,
        .is_nan,
        .select,
        .float_absolute,
        .floor,
        .float_sign,
        .normalize,
        .atan2,
        .pow,
        .float_max,
        .smooth_step,
        .float_remainder,
        .dot,
        .outer_product,
        .transpose,
        .float_to_signed,
        .float_to_unsigned,
        .return_void,
    };
    try std.testing.expectEqual(2 * (expected.len - 1) + 1, program.code.len);
    try std.testing.expectEqual(bc.Opcode.return_void, program.code[program.code.len - 1].opcode);

    for (program.code[0 .. expected.len - 1], expected[0 .. expected.len - 1]) |instruction, opcode|
        try std.testing.expectEqual(opcode, instruction.opcode);

    try std.testing.expectEqual(@as(u16, 2), program.code[1].components);
    try std.testing.expectEqual(@as(u32, 1), program.code[2].immediate);
    try std.testing.expectEqual(@as(u16, 2), program.code[5].components);
    try std.testing.expectEqual(@as(u16, 2), program.code[6].components);
    try std.testing.expectEqual(@as(u16, 2), program.code[8].components);
    try std.testing.expectEqual(@as(u16, 2), program.code[9].components);
    try std.testing.expectEqual(@as(u16, 2), program.code[12].components);
    try std.testing.expectEqual(@as(u16, 6), program.code[13].components);
    try std.testing.expectEqual(bc.MatrixDimensions{ .rows = 2, .inner = 0, .columns = 3 }, bc.MatrixDimensions.decode(program.code[13].immediate));
    try std.testing.expectEqual(bc.MatrixDimensions{ .rows = 2, .inner = 0, .columns = 3 }, bc.MatrixDimensions.decode(program.code[14].immediate));
}

test "[interpreter] length scalar absolute value and vector magnitude, dynamic extraction" {
    const code = [_]bc.Instruction{
        .{ .opcode = .length, .a = reg(5), .b = reg(0) },
        .{ .opcode = .length, .components = 2, .a = reg(6), .b = reg(1) },
        .{ .opcode = .vector_extract_dynamic, .components = 2, .a = reg(7), .b = reg(1), .c = reg(3) },
        .{ .opcode = .vector_extract_dynamic, .components = 2, .a = reg(8), .b = reg(1), .c = reg(4) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 9);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    copyWords(runtime.registers[0..5], &[_]u32{ f32Bits(-7), f32Bits(3), f32Bits(4), 0, 1 });
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try expectWords(&.{ f32Bits(7), f32Bits(5), f32Bits(3), f32Bits(4) }, runtime.registers[5..9]);
    runtime.registers[3] = @as(u32, @bitCast(@as(i32, -1)));
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, 0), runtime.registers[7]);
    runtime.registers[3] = 2;
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, 0), runtime.registers[7]);
    runtime.registers[3] = 0;
    runtime.registers[4] = std.math.maxInt(u32);
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, f32Bits(3)), runtime.registers[7]);
    try std.testing.expectEqual(@as(bc.Slot, 0), runtime.registers[8]);
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
            const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
            registers[0] = f32Bits(value[0]);
            registers[1] = f32Bits(value[1]);
            registers[7] = @intCast(lane * 4);
        }
        @memset(&buffer, 0xaa);
        const outcome = try runtime.runWave(&program, .{ .resource_buffers = &.{&buffer} });
        try std.testing.expectEqual(Runtime.full_lane_mask, outcome.returned_mask);
        for (0..Runtime.lane_count) |lane| {
            const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
            try expectWords(&.{ f32Bits(3), f32Bits(5), f32Bits(3) }, registers[4..7]);
            const expected_scalar = [_]f32{ 17, 32, 32, 47 };
            try std.testing.expectEqual(@as(bc.Slot, f32Bits(expected_scalar[lane % 4])), registers[9]);
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
    for ([_]bc.Opcode{ .d_pdx, .d_pdy }) |opcode| {
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
        const differences: [4][2]f32 = if (opcode == .d_pdx)
            .{ .{ -8, -3 }, .{ -8, -3 }, .{ 12, -7 }, .{ 12, -7 } }
        else
            .{ .{ -5, 12 }, .{ 15, 8 }, .{ -5, 12 }, .{ 15, 8 } };
        var buffer: [Runtime.lane_count * 4]u8 = undefined;
        // The extra case leaves the second quad wholly inactive on eight-lane waves.
        for (0..Runtime.lane_count + 1) |case| {
            const observable_lane = case % Runtime.lane_count;
            const execution_mask: Runtime.LaneMask = if (case == Runtime.lane_count) 0b1111 else Runtime.full_lane_mask;
            runtime.resetWave(&program, execution_mask, @as(Runtime.LaneMask, 1) << @intCast(observable_lane));
            for (0..Runtime.lane_count) |lane| {
                const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
                @memset(registers, 0xaaaaaaaa);
                const scale: f32 = @floatFromInt(lane / 4 + 1);
                registers[0] = f32Bits(values[lane % 4][0] * scale);
                registers[1] = f32Bits(values[lane % 4][1] * scale);
                registers[7] = @intCast(lane * 4);
            }
            @memset(&buffer, 0xaa);
            const outcome = try runtime.runWave(&program, .{ .resource_buffers = &.{&buffer} });
            try std.testing.expectEqual(execution_mask, outcome.returned_mask);
            for (0..Runtime.lane_count) |lane| {
                const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
                const scale: f32 = @floatFromInt(lane / 4 + 1);
                const expected = [2]u32{ f32Bits(differences[lane % 4][0] * scale * scale), f32Bits(differences[lane % 4][1] * scale * scale) };
                if ((execution_mask & (@as(Runtime.LaneMask, 1) << @intCast(lane))) != 0) {
                    try expectWords(&expected, registers[2..4]);
                    try expectWords(&expected, registers[4..6]);
                    try std.testing.expectEqual(@as(bc.Slot, expected[0]), registers[0]);
                    try std.testing.expectEqual(@as(bc.Slot, expected[0]), registers[6]);
                } else {
                    try expectWords(&@as([5]u32, @splat(0xaaaaaaaa)), registers[2..7]);
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
    for ([_]bc.Opcode{ .d_pdx, .d_pdy }) |opcode| {
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
        \\            %ls: f32 = length %scalar
        \\            %lv: f32 = length %vector
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
    const expected = [_]bc.Opcode{ .length, .length, .fwidth, .fwidth, .vector_extract_dynamic, .vector_extract_dynamic, .return_void };
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
    for ([_]bc.Opcode{ .fwidth, .d_pdx, .d_pdy }) |opcode| {
        code[6].opcode = opcode;
        for (0..3) |flip| {
            runtime.resetWave(&program, Runtime.full_lane_mask, 1);
            var values: [Runtime.lane_count]f32 = undefined;
            for (0..Runtime.lane_count) |lane| {
                const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
                // On wide waves the last case lets the second quad finish while the first waits
                registers[0] = @intFromBool((lane + flip) % 2 == 0 or (flip == 2 and lane >= 4));
                const value: f32 = @floatFromInt(lane % 4 + 1);
                registers[1] = f32Bits(value);
                registers[2] = f32Bits(2);
                values[lane] = if (registers[0] != 0) value * 2 else (value + 2) * 2;
            }
            const outcome = try runtime.runWave(&program, .{ .max_steps = 100 });
            try std.testing.expectEqual(Runtime.full_lane_mask, outcome.returned_mask);
            for (0..Runtime.lane_count) |lane| {
                const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
                const dx = values[lane | 1] - values[lane & ~@as(usize, 1)];
                const dy = values[lane | 2] - values[lane & ~@as(usize, 2)];
                const expected = switch (opcode) {
                    .d_pdx => dx,
                    .d_pdy => dy,
                    .fwidth => @abs(dx) + @abs(dy),
                    else => unreachable,
                };
                try std.testing.expectEqual(@as(bc.Slot, f32Bits(expected)), registers[4]);
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
    for ([_]bc.Opcode{ .fwidth, .d_pdx, .d_pdy }) |opcode| {
        code[0].opcode = opcode;
        for ([_]bc.Opcode{ .return_void, .discard, .control_barrier, .fwidth, .d_pdx, .d_pdy, .jump_edge }) |peer_opcode| {
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
        const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
        registers[0] = f32Bits(3);
        registers[1] = f32Bits(4);
        registers[2] = index;
        registers[4] = @intCast(lane * 4);
    }
    const outcome = try runtime.runWave(&program, .{ .resource_buffers = &.{&buffer} });
    try std.testing.expectEqual(@as(Runtime.LaneMask, 0b1111), outcome.returned_mask);
    try std.testing.expectEqual(f32Bits(4), std.mem.readInt(u32, buffer[0..4], .little));
    try std.testing.expectEqualSlices(u8, &@as([12]u8, @splat(0xaa)), buffer[4..]);
    const widths = [_]f32{ 8, 4, 4, 0 };
    for (widths, 0..) |width, lane| {
        const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
        try std.testing.expectEqual(@as(bc.Slot, if (lane == 0) f32Bits(4) else @as(u32, 0)), registers[3]);
        try std.testing.expectEqual(@as(bc.Slot, f32Bits(width)), registers[5]);
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
    runtime.registers[2] = std.math.maxInt(u32);
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
        const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
        copyWords(registers[0..9], &[_]u32{ f32Bits(-1), f32Bits(0.5), f32Bits(2), f32Bits(0), f32Bits(0), f32Bits(0), f32Bits(1), f32Bits(1), f32Bits(1) });
    }
    _ = try runtime.runWave(&program, .{});
    for (0..Runtime.lane_count) |lane| {
        const registers = runtime.register_backing[lane * program.register_count ..][0..program.register_count];
        try expectWords(&.{ f32Bits(0), f32Bits(0.5), f32Bits(1) }, registers[12..15]);
    }
}
