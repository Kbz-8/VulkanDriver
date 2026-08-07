const std = @import("std");
const shader_ir = @import("shader_ir");

const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ir = shader_ir.ir;

test "[interpreter] loop back edges copy block arguments in parallel" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\ shader compute @main
        \\ {
        \\     @output_a: u32 = output[location(0), component(0), index(0)]
        \\     @output_b: u32 = output[location(1), component(0), index(0)]
        \\
        \\     %zero: constant u32 = 0
        \\     %one: constant u32 = 1
        \\     %two: constant u32 = 2
        \\     %three: constant u32 = 3
        \\
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             branch .loop(%one, %two, %zero)
        \\
        \\         .loop(%a: u32, %b: u32, %index: u32):
        \\             %condition: bool = cmp_unsigned_less %index, %three
        \\             conditional_branch %condition, .body(), .exit(%a, %b)
        \\
        \\         .body():
        \\             %next_index: u32 = integer_add %index, %one
        \\             branch .loop(%b, %a, %next_index)
        \\
        \\         .exit(%final_a: u32, %final_b: u32):
        \\             store_interface @output_a, %final_a
        \\             store_interface @output_b, %final_b
        \\             return
        \\     }
        \\ }
    );
    defer module.deinit();

    const output_a = ir.id.InterfaceVariableId.fromIndex(0);
    const output_b = ir.id.InterfaceVariableId.fromIndex(1);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    var a: [1]u32 = undefined;
    var b: [1]u32 = undefined;
    try runtime.readOutput(&program, output_a, &a);
    try runtime.readOutput(&program, output_b, &b);
    try std.testing.expectEqual(@as(u32, 2), a[0]);
    try std.testing.expectEqual(@as(u32, 1), b[0]);
}
