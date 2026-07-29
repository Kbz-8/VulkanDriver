const std = @import("std");
const spirv = @import("spirv.zig");

const Self = @This();

pub const Error = error{
    HeaderTooShort,
    InvalidMagic,
    ByteSwappedModule,
    InvalidVersion,
    InvalidIdBound,
    InvalidSchema,
    ZeroWordInstruction,
    TruncatedInstruction,
    UnterminatedString,
};

pub const Header = struct {
    version: u32,
    generator: u32,
    bound: u32,
    schema: u32,

    pub inline fn major(self: Header) u8 {
        return @truncate(self.version >> 16);
    }

    pub inline fn minor(self: Header) u8 {
        return @truncate(self.version >> 8);
    }
};

pub const Instruction = struct {
    opcode: spirv.Opcode,
    operands: []const u32,
    word_offset: usize,

    pub fn operand(self: Instruction, index: usize) ?u32 {
        return if (index < self.operands.len) self.operands[index] else null;
    }
};

pub const Iterator = struct {
    words: []const u32,
    cursor: usize = spirv.header_word_count,

    pub fn next(self: *Iterator) Error!?Instruction {
        if (self.cursor == self.words.len)
            return null;

        const first_word = self.words[self.cursor];
        const word_count: usize = first_word >> 16;

        if (word_count == 0)
            return error.ZeroWordInstruction;
        if (word_count > self.words.len - self.cursor)
            return error.TruncatedInstruction;

        const instruction: Instruction = .{
            .opcode = @enumFromInt(@as(u16, @truncate(first_word))),
            .operands = self.words[self.cursor + 1 .. self.cursor + word_count],
            .word_offset = self.cursor,
        };
        self.cursor += word_count;
        return instruction;
    }
};

words: []const u32,
header: Header,

pub fn init(words: []const u32) Error!Self {
    if (words.len < spirv.header_word_count)
        return error.HeaderTooShort;
    if (words[0] == spirv.byte_swapped_magic_number)
        return error.ByteSwappedModule;
    if (words[0] != spirv.magic_number)
        return error.InvalidMagic;

    const header: Header = .{
        .version = words[1],
        .generator = words[2],
        .bound = words[3],
        .schema = words[4],
    };

    if (header.major() != 1 or header.minor() > 6 or (header.version & 0xff00_00ff) != 0)
        return error.InvalidVersion;
    if (header.bound == 0)
        return error.InvalidIdBound;
    if (header.schema != 0)
        return error.InvalidSchema;

    var self: Self = .{ .words = words, .header = header };
    var instruction_iterator = self.iterator();
    while (try instruction_iterator.next()) |_| {}
    return self;
}

pub fn iterator(self: Self) Iterator {
    return .{ .words = self.words };
}

pub fn literalStringWordCount(words: []const u32) Error!usize {
    for (words, 0..) |word, word_index| {
        inline for (0..4) |byte_index| {
            if (@as(u8, @truncate(word >> (byte_index * 8))) == 0)
                return word_index + 1;
        }
    }
    return error.UnterminatedString;
}

pub fn literalStringEquals(words: []const u32, expected: []const u8) Error!bool {
    var byte_cursor: usize = 0;
    for (words) |word| {
        inline for (0..4) |byte_index| {
            const byte: u8 = @truncate(word >> (byte_index * 8));

            if (byte == 0)
                return byte_cursor == expected.len;
            if (byte_cursor >= expected.len or byte != expected[byte_cursor])
                return false;

            byte_cursor += 1;
        }
    }
    return error.UnterminatedString;
}

pub fn copyLiteralString(allocator: anytype, words: []const u32) ![]u8 {
    const word_count = try literalStringWordCount(words);
    var byte_count: usize = 0;
    outer: for (words[0..word_count]) |word| {
        inline for (0..4) |byte_index| {
            if (@as(u8, @truncate(word >> (byte_index * 8))) == 0)
                break :outer;

            byte_count += 1;
        }
    }

    const result = try allocator.alloc(u8, byte_count);
    var cursor: usize = 0;
    outer: for (words[0..word_count]) |word| {
        inline for (0..4) |byte_index| {
            const byte: u8 = @truncate(word >> (byte_index * 8));
            if (byte == 0)
                break :outer;

            result[cursor] = byte;
            cursor += 1;
        }
    }
    return result;
}

test "SPIR-V: parser validates module headers" {
    const short = [_]u32{ spirv.magic_number, 0x0001_0000, 0, 1 };
    try std.testing.expectError(error.HeaderTooShort, Self.init(&short));

    var invalid_magic = validHeader(0x0001_0000);
    invalid_magic[0] = 0x1234_5678;
    try std.testing.expectError(error.InvalidMagic, Self.init(&invalid_magic));

    var byte_swapped = validHeader(0x0001_0000);
    byte_swapped[0] = spirv.byte_swapped_magic_number;
    try std.testing.expectError(error.ByteSwappedModule, Self.init(&byte_swapped));

    var invalid_major = validHeader(0x0002_0000);
    try std.testing.expectError(error.InvalidVersion, Self.init(&invalid_major));

    var invalid_minor = validHeader(0x0001_0700);
    try std.testing.expectError(error.InvalidVersion, Self.init(&invalid_minor));

    var invalid_reserved_bits = validHeader(0x0101_0001);
    try std.testing.expectError(error.InvalidVersion, Self.init(&invalid_reserved_bits));

    var zero_bound = validHeader(0x0001_0000);
    zero_bound[3] = 0;
    try std.testing.expectError(error.InvalidIdBound, Self.init(&zero_bound));

    var nonzero_schema = validHeader(0x0001_0000);
    nonzero_schema[4] = 1;
    try std.testing.expectError(error.InvalidSchema, Self.init(&nonzero_schema));

    var version_1_6 = validHeader(0x0001_0600);
    version_1_6[2] = 0xfeed_beef;
    version_1_6[3] = 42;
    const parser = try Self.init(&version_1_6);
    try std.testing.expectEqual(@as(u8, 1), parser.header.major());
    try std.testing.expectEqual(@as(u8, 6), parser.header.minor());
    try std.testing.expectEqual(@as(u32, 0xfeed_beef), parser.header.generator);
    try std.testing.expectEqual(@as(u32, 42), parser.header.bound);

    var instruction_iterator = parser.iterator();
    try std.testing.expectEqual(@as(?Instruction, null), try instruction_iterator.next());
}

test "SPIR-V: parser iterates instructions and operands" {
    const words = [_]u32{
        spirv.magic_number,
        0x0001_0000,
        0,
        8,
        0,
        instructionWord(.nop, 1),
        instructionWord(.i_add, 5),
        1,
        2,
        3,
        4,
    };
    const parser = try Self.init(&words);
    var instruction_iterator = parser.iterator();

    const nop = (try instruction_iterator.next()).?;
    try std.testing.expectEqual(spirv.Opcode.nop, nop.opcode);
    try std.testing.expectEqual(@as(usize, spirv.header_word_count), nop.word_offset);
    try std.testing.expectEqual(@as(usize, 0), nop.operands.len);
    try std.testing.expectEqual(@as(?u32, null), nop.operand(0));

    const add = (try instruction_iterator.next()).?;
    try std.testing.expectEqual(spirv.Opcode.i_add, add.opcode);
    try std.testing.expectEqual(@as(usize, spirv.header_word_count + 1), add.word_offset);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, add.operands);
    try std.testing.expectEqual(@as(?u32, 1), add.operand(0));
    try std.testing.expectEqual(@as(?u32, 4), add.operand(3));
    try std.testing.expectEqual(@as(?u32, null), add.operand(4));
    try std.testing.expectEqual(@as(?Instruction, null), try instruction_iterator.next());
}

test "SPIR-V: parser literal string helpers" {
    const empty = [_]u32{0};
    try std.testing.expectEqual(@as(usize, 1), try literalStringWordCount(&empty));
    try std.testing.expect(try literalStringEquals(&empty, ""));

    const abc = [_]u32{0x0063_6261};
    try std.testing.expectEqual(@as(usize, 1), try literalStringWordCount(&abc));
    try std.testing.expect(try literalStringEquals(&abc, "abc"));
    try std.testing.expect(!try literalStringEquals(&abc, "ab"));
    try std.testing.expect(!try literalStringEquals(&abc, "abcd"));

    const main = [_]u32{ 0x6e69_616d, 0 };
    try std.testing.expectEqual(@as(usize, 2), try literalStringWordCount(&main));
    try std.testing.expect(try literalStringEquals(&main, "main"));
    try std.testing.expect(!try literalStringEquals(&main, "Main"));

    const copy = try copyLiteralString(std.testing.allocator, &main);
    defer std.testing.allocator.free(copy);
    try std.testing.expectEqualStrings("main", copy);

    const unterminated = [_]u32{0x6463_6261};
    try std.testing.expectError(error.UnterminatedString, literalStringWordCount(&unterminated));
    try std.testing.expectError(error.UnterminatedString, literalStringEquals(&unterminated, "abcd"));
    try std.testing.expectError(error.UnterminatedString, copyLiteralString(std.testing.allocator, &unterminated));
}

test "SPIR-V: parser rejects malformed instruction framing" {
    const words = [_]u32{
        spirv.magic_number,
        0x0001_0000,
        0,
        2,
        0,
        instructionWord(.nop, 0),
    };
    try std.testing.expectError(error.ZeroWordInstruction, Self.init(&words));

    const truncated = [_]u32{
        spirv.magic_number,
        0x0001_0000,
        0,
        2,
        0,
        instructionWord(.i_add, 5),
        1,
    };
    try std.testing.expectError(error.TruncatedInstruction, Self.init(&truncated));
}

fn validHeader(version: u32) [spirv.header_word_count]u32 {
    return .{ spirv.magic_number, version, 0, 1, 0 };
}

fn instructionWord(opcode: spirv.Opcode, word_count: u16) u32 {
    return (@as(u32, word_count) << 16) | @intFromEnum(opcode);
}
