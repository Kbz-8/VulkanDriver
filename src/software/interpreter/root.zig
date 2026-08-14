//! Software bytecode interpreter for the backend-agnostic shader IR.

pub const bytecode = @import("bytecode.zig");
pub const Program = @import("Program.zig");
pub const Runtime = @import("Runtime.zig");

pub const Outcome = Runtime.Outcome;
pub const RunOptions = Runtime.RunOptions;
pub const RuntimeError = Runtime.RuntimeError;

comptime {
    _ = @import("test/test.zig");
}
