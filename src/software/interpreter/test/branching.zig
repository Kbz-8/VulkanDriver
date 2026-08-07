const std = @import("std");
const shader_ir = @import("shader_ir");

const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ir = shader_ir.ir;

fn i32Bits(value: i32) u32 {
    return @bitCast(value);
}

test "[interpreter] branches with block parameters" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\ shader vertex @main
        \\ {
        \\     @input: i32 = input[location(0), component(0), index(0)]
        \\     @output: i32 = output[location(0), component(0), index(0)]
        \\
        \\     %one: constant i32 = 1
        \\     %ten: constant i32 = 10
        \\
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             %value: i32 = load_interface @input
        \\             %condition: bool = cmp_signed_less %value, %ten
        \\             conditional_branch %condition, .less(), .greater_equal()
        \\
        \\         .less():
        \\             %incremented: i32 = integer_add %value, %one
        \\             branch .merge(%incremented)
        \\
        \\         .greater_equal():
        \\             %decremented: i32 = integer_subtract %value, %one
        \\             branch .merge(%decremented)
        \\
        \\         .merge(%merged: i32):
        \\             store_interface @output, %merged
        \\             return
        \\     }
        \\ }
    );

    const input = ir.id.InterfaceVariableId.fromIndex(0);
    const output = ir.id.InterfaceVariableId.fromIndex(1);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    module.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try runtime.writeInput(&program, input, &.{i32Bits(5)});
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    var result: [1]u32 = undefined;
    try runtime.readOutput(&program, output, &result);
    try std.testing.expectEqual(@as(i32, 6), @as(i32, @bitCast(result[0])));

    try runtime.writeInput(&program, input, &.{i32Bits(20)});
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try runtime.readOutput(&program, output, &result);
    try std.testing.expectEqual(@as(i32, 19), @as(i32, @bitCast(result[0])));
}
