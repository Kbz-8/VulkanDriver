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
