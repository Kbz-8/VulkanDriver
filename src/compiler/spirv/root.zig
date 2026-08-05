//! ## SPIR-V frontend
//!
//! This namespace contains the SPIR-V parser and translator used to import shader
//! modules into the compiler IR.
//!
//! `Parser` validates borrowed SPIR-V words, while `SourceModule` owns and
//! structurally validates words that need to outlive an API call. `spec` exposes a
//! minimalistic SPIR-V header translation.
//!
//! Use `translator.instantiate` to lower one entry point from a retained source
//! module. `translator.translate` remains as a convenience wrapper for borrowed
//! words.

pub const Parser = @import("Parser.zig");
pub const SourceModule = @import("SourceModule.zig");
pub const translator = @import("translator.zig");
pub const spec = @import("spirv.zig");

test {
    _ = Parser;
    _ = SourceModule;
    _ = translator;
}
