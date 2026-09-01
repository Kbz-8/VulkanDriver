const std = @import("std");
const CodeBuffer = @import("../code_buffer.zig").CodeBuffer;
const Error = @import("../errors.zig").Error;
const encoding = @import("encoding.zig");
const registers = @import("registers.zig");

pub const Encoder = struct {
    code: CodeBuffer,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .code = CodeBuffer.init(allocator) };
    }

    pub fn deinit(self: *Encoder) void {
        self.code.deinit();
        self.* = undefined;
    }

    pub fn prologue(_: *Encoder, _: u32) Error!void {
        return Error.CodeGenerationNotImplemented;
    }

    pub fn epilogue(_: *Encoder) Error!void {
        return Error.CodeGenerationNotImplemented;
    }

    pub fn moveVector(_: *Encoder, _: registers.Zmm, _: encoding.VectorSource, _: ?registers.Mask) Error!void {
        return Error.CodeGenerationNotImplemented;
    }

    pub fn addVector(_: *Encoder, _: encoding.VectorElement, _: registers.Zmm, _: registers.Zmm, _: encoding.VectorSource, _: ?registers.Mask) Error!void {
        return Error.CodeGenerationNotImplemented;
    }

    pub fn compareVector(_: *Encoder, _: encoding.VectorElement, _: encoding.Condition, _: registers.Mask, _: registers.Zmm, _: encoding.VectorSource, _: registers.Mask) Error!void {
        return Error.CodeGenerationNotImplemented;
    }

    pub fn gather(_: *Encoder, _: encoding.VectorElement, _: registers.Zmm, _: registers.Gpr, _: registers.Zmm, _: registers.Mask) Error!void {
        return Error.CodeGenerationNotImplemented;
    }

    pub fn scatter(_: *Encoder, _: encoding.VectorElement, _: registers.Gpr, _: registers.Zmm, _: registers.Zmm, _: registers.Mask) Error!void {
        return Error.CodeGenerationNotImplemented;
    }
};
