const std = @import("std");
const bc = @import("../bytecode.zig");
const Runtime = @import("../Runtime.zig");

pub fn copyWords(destination: Runtime.LaneView, words: []const u32) void {
    std.debug.assert(destination.len == words.len);
    for (words, 0..) |word, index| {
        destination.at(index).* = word;
    }
}

pub fn expectWords(expected: []const u32, actual: Runtime.LaneView) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |word, index|
        try std.testing.expectEqual(@as(bc.Slot, word), actual.at(index).*);
}
