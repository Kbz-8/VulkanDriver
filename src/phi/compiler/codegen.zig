const shader_ir = @import("shader_ir").ir;
const Analysis = @import("analysis.zig").Analysis;
const Error = @import("errors.zig").Error;
const Encoder = @import("imci/encoder.zig").Encoder;

pub const Options = struct {
    dispatch_width: u8 = 16,
};

pub fn emitComputeKernel(
    _: *Encoder,
    _: *const shader_ir.module.Module,
    _: *const Analysis,
    _: Options,
) Error!void {
    return error.CodeGenerationNotImplemented;
}
