const std = @import("std");

const bytecode = @import("../bytecode.zig");

test "[interpreter] bytecode instruction size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(bytecode.Instruction));
}

comptime {
    _ = @import("arithmetic.zig");
    _ = @import("branching.zig");
    _ = @import("conversion.zig");
    _ = @import("image_sampling.zig");
    _ = @import("loops.zig");
    _ = @import("resources.zig");
    _ = @import("storage_buffers.zig");
    _ = @import("termination.zig");
}
