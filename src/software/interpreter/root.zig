//! Software bytecode interpreter for the backend-agnostic shader IR.
//!
//! This first slice supports allocation-free scalar execution of 32-bit scalar
//! and vector arithmetic, interface I/O, control flow, and block parameters.

pub const bytecode = @import("bytecode.zig");
pub const Program = @import("Program.zig");
pub const Runtime = @import("Runtime.zig");

pub const Outcome = Runtime.Outcome;
pub const RunOptions = Runtime.RunOptions;
pub const RuntimeError = Runtime.RuntimeError;

comptime {
    _ = @import("test/test.zig");
}
