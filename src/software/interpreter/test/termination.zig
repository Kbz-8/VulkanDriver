const std = @import("std");
const shader_ir = @import("shader_ir");

const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ir = shader_ir.ir;

test "[interpreter] fragment discard is an execution outcome" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\ shader fragment @main
        \\ {
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             discard
        \\     }
        \\ }
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try std.testing.expectEqual(Runtime.Outcome.discarded, try runtime.run(&program, .{}));
}

test "[interpreter] execution budget stops an infinite loop" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\ shader compute @main
        \\ {
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             branch .loop()
        \\         .loop():
        \\             branch .loop()
        \\     }
        \\ }
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try std.testing.expectError(Runtime.RuntimeError.StepLimitExceeded, runtime.run(&program, .{ .max_steps = 8 }));
}
