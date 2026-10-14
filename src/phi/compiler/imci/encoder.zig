const std = @import("std");
const CodeBuffer = @import("../code_buffer.zig").CodeBuffer;
const Error = @import("../errors.zig").Error;
const encoding = @import("encoding.zig");
const registers = @import("registers.zig");
const instruction = @import("instruction.zig");

pub const Encoder = struct {
    const Self = @This();

    code: CodeBuffer,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .code = CodeBuffer.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.code.deinit();
        self.* = undefined;
    }

    /// C ABI entry: launcher sets rdi/rsi/rdx; nothing to emit
    pub fn prologue(_: *Self, workgroup: u32) Error!void {
        _ = workgroup;
        return .ok;
    }

    /// C ABI exit: ret
    pub fn epilogue(self: *Self) Error!void {
        return self.ret();
    }

    pub fn ret(self: *Self) Error!void {
        try self.code.emitByte(0xC3);
        return .ok;
    }

    pub fn jmp(self: *Self, label: CodeBuffer.Label) Error!void {
        const start = self.code.offset();
        try self.code.emitByte(0xEB); // jmp rel8
        try self.code.emitByte(0); // rel8 placeholder
        try self.code.addFixup(start + 1, 1, start + 2, label);
        return .ok;
    }

    pub fn jcc(self: *Self, cond: encoding.Condition, label: CodeBuffer.Label) Error!void {
        const start = self.code.offset();
        try self.code.emitByte(jccOpcode(cond));
        try self.code.emitByte(0); // rel8 placeholder
        try self.code.addFixup(start + 1, 1, start + 2, label);
        return .ok;
    }

    fn emitMvex(_: *Self, instr: instruction.Instruction) Error!void {
        _ = instr;
        return Error.CodeGenerationNotImplemented;
    }

    pub fn moveVector(self: *Self, dest: registers.Zmm, src: encoding.VectorSource, mask: ?registers.Mask) Error!void {
        return self.emitMvex(.{
            .opcode = .vkmove,
            .dest = dest,
            .src0 = src,
            .mask = mask,
        });
    }

    pub fn addVector(self: *Self, element: encoding.VectorElement, dest: registers.Zmm, src0: registers.Zmm, src1: encoding.VectorSource, mask: ?registers.Mask) Error!void {
        return self.emitMvex(.{
            .opcode = addOpcode(element),
            .dest = dest,
            .src0 = src0,
            .src1 = src1,
            .element = element,
            .mask = mask,
        });
    }

    pub fn compareVector(
        self: *Self,
        element: encoding.VectorElement,
        cond: encoding.Condition,
        src_mask: registers.Mask,
        dest: registers.Zmm,
        src: encoding.VectorSource,
        write_mask: registers.Mask,
    ) Error!void {
        _ = src_mask;
        return self.emitMvex(.{
            .opcode = .vcmp,
            .element = element,
            .cond = cond,
            .dest = dest,
            .src0 = src,
            .mask = write_mask,
        });
    }

    pub fn gather(self: *Self, element: encoding.VectorElement, dest: registers.Zmm, gpr: registers.Gpr, src: registers.Zmm, mask: registers.Mask) Error!void {
        return self.emitMvex(.{
            .opcode = .vgather,
            .element = element,
            .dest = dest,
            .src0 = .{ .register = src },
            .gpr = gpr,
            .mask = mask,
        });
    }

    pub fn scatter(self: *Self, element: encoding.VectorElement, gpr: registers.Gpr, dest: registers.Zmm, src: registers.Zmm, mask: registers.Mask) Error!void {
        return self.emitMvex(.{
            .opcode = .vscatter,
            .element = element,
            .dest = dest,
            .src0 = .{ .register = src },
            .gpr = gpr,
            .mask = mask,
        });
    }

    fn addOpcode(element: encoding.VectorElement) instruction.OpCode {
        return switch (element) {
            .i32, .u32, .f32 => .vadd32,
            .i64, .u64, .f64 => .vadd64,
        };
    }

    fn jccOpcode(cond: encoding.Condition) u8 {
        return switch (cond) {
            .equal => 0x74,
            .not_equal => 0x75,
            .less => 0x7C,
            .less_equal => 0x7A,
            .greater => 0x7B,
            .greater_equal => 0x7F,
        };
    }
};
