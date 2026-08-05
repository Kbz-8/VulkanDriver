const std = @import("std");
const Parser = @import("Parser.zig");

const Self = @This();

words: []u32,
parsed: Parser,

pub const Error = std.mem.Allocator.Error || Parser.Error;

pub fn init(allocator: std.mem.Allocator, words: []const u32) Error!Self {
    const owned_words = try allocator.dupe(u32, words);
    errdefer allocator.free(owned_words);

    return .{
        .words = owned_words,
        .parsed = try Parser.init(owned_words),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.words);
    self.* = undefined;
}

pub fn code(self: *const Self) []const u32 {
    return self.words;
}

pub fn parser(self: *const Self) Parser {
    return self.parsed;
}

test "SPIR-V: source module owns and validates its words" {
    var words = [_]u32{
        0x07230203,
        0x00010000,
        0,
        1,
        0,
    };

    var source = try Self.init(std.testing.allocator, &words);
    defer source.deinit(std.testing.allocator);

    words[0] = 0;
    try std.testing.expectEqual(@as(u32, 0x07230203), source.code()[0]);
    try std.testing.expectEqual(@as(u8, 1), source.parser().header.major());
}

test "SPIR-V: source module rejects malformed input" {
    const malformed = [_]u32{ 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidMagic, Self.init(std.testing.allocator, &malformed));
}
