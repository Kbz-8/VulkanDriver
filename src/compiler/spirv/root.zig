//! ## SPIR-V frontend
//!
//! This namespace contains the SPIR-V parser and translator used to import shader
//! modules into the compiler IR.
//!
//! `Parser` validates the SPIR-V header and iterates over binary instructions.
//! `spec` exposes a minimalistic SPIR-V header translation.
//!
//! The main entry point is `translator.translate`, which finds the requested entry
//! point, maps its execution model to an IR shader stage, lowers supported types,
//! constants, interfaces, instructions, and structured control flow, then validates
//! the generated IR module.

pub const Parser = @import("Parser.zig");
pub const translator = @import("translator.zig");
pub const spec = @import("spirv.zig");
