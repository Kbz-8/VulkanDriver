const std = @import("std");
const bc = @import("../bytecode.zig");

pub fn copyWords(destination: []bc.Slot, words: []const u32) void {
    std.debug.assert(destination.len == words.len);
    for (destination, words) |*slot, word| {
        slot.* = word;
    }
}

pub fn expectWords(expected: []const u32, actual: []const bc.Slot) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |word, slot|
        try std.testing.expectEqual(@as(bc.Slot, word), slot);
}
