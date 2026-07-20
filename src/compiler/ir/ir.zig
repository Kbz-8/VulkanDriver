//! ## Intermediate Representation
//!
//! The IR is the compiler's target-independent shader representation. It keeps
//! shader structure explicit while hiding SPIR-V's binary encoding and large
//! instruction surface.
//!
//! `module.Module` owns types, constants, values, instructions, blocks, functions,
//! interfaces, and resources in typed ID stores. Values are in SSA form: each value
//! is defined by a constant, parameter, instruction, or `undef`.
//!
//! Control flow is represented with basic blocks and terminators. Phi-like values
//! are modeled as block parameters, with branch edge arguments supplying incoming
//! values. Blocks can also record structured selection or loop metadata.
//!
//! Use `Builder` to construct modules, `validator.validate` to check invariants,
//! `cfg` for control-flow queries, `Rewriter` for common edits, and
//! `parser`/`printer` for the textual IR format used by tests and debugging.
//!
//! Here's a simple text representation of a shader module that `parser.Parser` and `printer` can handle/produce:
//! ```
//! shader vertex @main
//! {
//!     @color: vec4[f32] = input[location(0), component(0), index(0)]
//!     @out_color: vec4[f32] = output[location(0), component(0), index(0)]
//!     %0: constant bool = true
//!     %1: constant f32 = bits(0x3f800000)
//!
//!     fn @main() -> void
//!     {
//!         .entry():
//!             %3: vec4[f32] = load_interface @color
//!             conditional_branch %0, .pass(), .merge(%3)
//!
//!         .pass():
//!             %4: vec4[f32] = composite_construct %1, %1, %1, %1
//!             branch .merge(%4)
//!
//!         .merge(%2: vec4[f32]):
//!             store_interface @out_color, %2
//!             return
//!     }
//! }
//! ```

pub const Builder = @import("Builder.zig");
pub const Rewriter = @import("Rewriter.zig");
pub const cfg = @import("cfg.zig");
pub const constant = @import("constant.zig");
pub const id = @import("id.zig");
pub const instruction = @import("instruction.zig");
pub const module = @import("module.zig");
pub const parser = @import("parser/parser.zig");
pub const pass_manager = @import("pass_manager.zig");
pub const printer = @import("printer.zig");
pub const types = @import("type.zig");
pub const validator = @import("validator/validator.zig");
pub const value = @import("value.zig");
pub const visitor = @import("visitor.zig");
