const std = @import("std");
const shader_ir = @import("shader_ir").ir;
const Error = @import("errors.zig").Error;

pub const Label = enum(u32) { _ };

pub const Fixup = struct {
    displacement_offset: usize,
    instruction_end: usize,
    target: Label,
};

pub const BlockLabel = struct {
    block: shader_ir.id.BlockId,
    label: Label,
};

pub const CodeBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    label_offsets: std.ArrayList(?usize) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,

    pub fn init(allocator: std.mem.Allocator) CodeBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CodeBuffer) void {
        self.bytes.deinit(self.allocator);
        self.label_offsets.deinit(self.allocator);
        self.fixups.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn offset(self: *const CodeBuffer) usize {
        return self.bytes.items.len;
    }

    pub fn emitByte(self: *CodeBuffer, byte: u8) std.mem.Allocator.Error!void {
        try self.bytes.append(self.allocator, byte);
    }

    pub fn emitBytes(self: *CodeBuffer, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    pub fn createLabel(self: *CodeBuffer) std.mem.Allocator.Error!Label {
        const label: Label = @enumFromInt(self.label_offsets.items.len);
        try self.label_offsets.append(self.allocator, null);
        return label;
    }

    pub fn bindLabel(self: *CodeBuffer, label: Label) Error!void {
        const index = @intFromEnum(label);
        if (index >= self.label_offsets.items.len or self.label_offsets.items[index] != null)
            return error.EncodingFailed;
        self.label_offsets.items[index] = self.offset();
    }

    pub fn resolveFixups(_: *CodeBuffer) Error!void {
        return error.CodeGenerationNotImplemented;
    }

    pub fn toOwnedSlice(self: *CodeBuffer) std.mem.Allocator.Error![]u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }
};
