//! ## Shader compiler infrastructure.
//!
//! This module exposes the project-specific intermediate representation in
//! `ir` and the SPIR-V frontend in `spirv`.
//!
//! Together they form the first stage of the compiler pipeline: SPIR-V binary
//! modules are decoded, translated into a smaller and easier-to-transform IR,
//! validated, and then made available to later optimization or code-generation
//! transformers.

pub const ir = @import("ir/ir.zig");
pub const spirv = @import("spirv/root.zig");

test {
    _ = ir;
    _ = spirv;
}
