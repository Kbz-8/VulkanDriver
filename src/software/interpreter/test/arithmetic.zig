const std = @import("std");
const shader_ir = @import("shader_ir");

const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ir = shader_ir.ir;

fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

fn bitsF32(value: u32) f32 {
    return @bitCast(value);
}

test "[interpreter] vector float arithmetic" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\ shader vertex @main
        \\ {
        \\     @lhs: vec4[f32] = input[location(0), component(0), index(0)]
        \\     @rhs: vec4[f32] = input[location(1), component(0), index(0)]
        \\     @output: vec4[f32] = output[location(0), component(0), index(0)]
        \\
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             %lhs_value: vec4[f32] = load_interface @lhs
        \\             %rhs_value: vec4[f32] = load_interface @rhs
        \\             %product: vec4[f32] = float_multiply %lhs_value, %rhs_value
        \\             store_interface @output, %product
        \\             return
        \\     }
        \\ }
    );
    defer module.deinit();

    const lhs = ir.id.InterfaceVariableId.fromIndex(0);
    const rhs = ir.id.InterfaceVariableId.fromIndex(1);
    const output = ir.id.InterfaceVariableId.fromIndex(2);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try runtime.writeInput(&program, lhs, &.{ f32Bits(2), f32Bits(-3), f32Bits(0.5), f32Bits(8) });
    try runtime.writeInput(&program, rhs, &.{ f32Bits(4), f32Bits(2), f32Bits(6), f32Bits(0.25) });
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));

    var result: [4]u32 = undefined;
    try runtime.readOutput(&program, output, &result);
    const expected = [_]f32{ 8, -6, 3, 2 };
    for (result, expected) |actual, wanted|
        try std.testing.expectEqual(wanted, bitsF32(actual));
}

test "[interpreter] matrix arithmetic uses column-major dimensions" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @lhs: mat2x3[f32] = input[location(0), component(0), index(0)]
        \\    @rhs: mat4x2[f32] = input[location(1), component(0), index(0)]
        \\    @scalar: f32 = input[location(2), component(0), index(0)]
        \\    @columns: vec2[f32] = input[location(3), component(0), index(0)]
        \\    @rows: vec3[f32] = input[location(4), component(0), index(0)]
        \\    @scaled: mat2x3[f32] = output[location(0), component(0), index(0)]
        \\    @matrix_vector: vec3[f32] = output[location(1), component(0), index(0)]
        \\    @vector_matrix: vec2[f32] = output[location(2), component(0), index(0)]
        \\    @matrix_matrix: mat4x3[f32] = output[location(3), component(0), index(0)]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %lhs_value: mat2x3[f32] = load_interface @lhs
        \\            %rhs_value: mat4x2[f32] = load_interface @rhs
        \\            %scalar_value: f32 = load_interface @scalar
        \\            %columns_value: vec2[f32] = load_interface @columns
        \\            %rows_value: vec3[f32] = load_interface @rows
        \\            %scaled_value: mat2x3[f32] = matrix_times_scalar %lhs_value, %scalar_value
        \\            %matrix_vector_value: vec3[f32] = matrix_times_vector %lhs_value, %columns_value
        \\            %vector_matrix_value: vec2[f32] = vector_times_matrix %rows_value, %lhs_value
        \\            %matrix_matrix_value: mat4x3[f32] = matrix_times_matrix %lhs_value, %rhs_value
        \\            store_interface @scaled, %scaled_value
        \\            store_interface @matrix_vector, %matrix_vector_value
        \\            store_interface @vector_matrix, %vector_matrix_value
        \\            store_interface @matrix_matrix, %matrix_matrix_value
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(0), &.{ f32Bits(1), f32Bits(2), f32Bits(3), f32Bits(4), f32Bits(5), f32Bits(6) });
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(1), &.{ f32Bits(1), f32Bits(2), f32Bits(3), f32Bits(4), f32Bits(5), f32Bits(6), f32Bits(7), f32Bits(8) });
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(2), &.{f32Bits(2)});
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(3), &.{ f32Bits(10), f32Bits(20) });
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(4), &.{ f32Bits(7), f32Bits(8), f32Bits(9) });
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));

    const expected = [_][]const f32{
        &.{ 2, 4, 6, 8, 10, 12 },
        &.{ 90, 120, 150 },
        &.{ 50, 122 },
        &.{ 9, 12, 15, 19, 26, 33, 29, 40, 51, 39, 54, 69 },
    };
    for (expected, 5..) |wanted, output_index| {
        var result: [12]u32 = undefined;
        try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(output_index), result[0..wanted.len]);
        for (result[0..wanted.len], wanted) |actual, value|
            try std.testing.expectEqual(value, bitsF32(actual));
    }
}

test "[interpreter] vector times scalar broadcasts" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @vector: vec4[f32] = input[location(0), component(0), index(0)]
        \\    @scalar: f32 = input[location(1), component(0), index(0)]
        \\    @output: vec4[f32] = output[location(0), component(0), index(0)]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %vector_value: vec4[f32] = load_interface @vector
        \\            %scalar_value: f32 = load_interface @scalar
        \\            %product: vec4[f32] = vector_times_scalar %vector_value, %scalar_value
        \\            store_interface @output, %product
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(0), &.{ f32Bits(2), f32Bits(-3), f32Bits(0.5), f32Bits(8) });
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(1), &.{f32Bits(4)});
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));

    var result: [4]u32 = undefined;
    try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(2), &result);
    const expected = [_]f32{ 8, -12, 2, 32 };
    for (result, expected) |actual, wanted|
        try std.testing.expectEqual(wanted, bitsF32(actual));
}
