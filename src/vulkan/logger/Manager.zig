const std = @import("std");
const DebugStack = @import("DebugStack.zig");

const Self = @This();

indent_enabled: bool,
indent_level: usize,
debug_stack: DebugStack,

pub const init: Self = .{
    .indent_enabled = true,
    .indent_level = 0,
    .debug_stack = .empty,
};

pub fn indent(self: *Self) void {
    const new_indent_level, const has_overflown = @addWithOverflow(self.indent_level, 1);
    if (has_overflown == 0) {
        self.indent_level = new_indent_level;
    }
}

pub fn unindent(self: *Self) void {
    const new_indent_level, const has_overflown = @subWithOverflow(self.indent_level, 1);
    if (has_overflown == 0) {
        self.indent_level = new_indent_level;
    }
    loop: while (self.debug_stack.getLastOrNull()) |last| {
        if (last.indent_level >= self.indent_level) {
            _ = self.debug_stack.popBack();
        } else {
            break :loop;
        }
    }
}

pub inline fn enableIndent(self: *Self) void {
    self.indent_enabled = true;
}

pub inline fn disableIndent(self: *Self) void {
    self.indent_enabled = false;
}

pub inline fn deinit(self: *Self) void {
    self.debug_stack.deinit();
}
