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

test "[interpreter] vector floating-point arithmetic" {
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
