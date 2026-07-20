const std = @import("std");

const Self = @This();

source: []const u8,
cursor: usize = 0,
lookahead: ?Token = null,

pub const TokenTag = enum {
    eof,
    invalid,
    identifier,
    number,
    value_ref,
    constant_ref,
    at_name,
    dot_name,
    left_brace,
    right_brace,
    left_paren,
    right_paren,
    left_square,
    right_square,
    colon,
    comma,
    equal,
    arrow,
};

pub const Token = struct {
    tag: TokenTag,
    text: []const u8,
};

pub fn init(source: []const u8) Self {
    return .{
        .source = source,
    };
}

pub fn peek(self: *Self) Token {
    if (self.lookahead == null)
        self.lookahead = self.lex();
    return self.lookahead.?;
}

pub fn take(self: *Self) Token {
    const token = self.peek();
    self.lookahead = null;
    return token;
}

fn lex(self: *Self) Token {
    while (self.cursor < self.source.len and std.ascii.isWhitespace(self.source[self.cursor]))
        self.cursor += 1;

    if (self.cursor == self.source.len) {
        return .{
            .tag = .eof,
            .text = self.source[self.cursor..self.cursor],
        };
    }

    const start = self.cursor;
    const byte = self.source[self.cursor];
    self.cursor += 1;

    switch (byte) {
        '{' => return self.simpleToken(.left_brace, start),
        '}' => return self.simpleToken(.right_brace, start),
        '(' => return self.simpleToken(.left_paren, start),
        ')' => return self.simpleToken(.right_paren, start),
        '[' => return self.simpleToken(.left_square, start),
        ']' => return self.simpleToken(.right_square, start),
        ':' => return self.simpleToken(.colon, start),
        ',' => return self.simpleToken(.comma, start),
        '=' => return self.simpleToken(.equal, start),
        '-', '+' => {
            if (byte == '-' and self.cursor < self.source.len and self.source[self.cursor] == '>') {
                self.cursor += 1;
                return .{
                    .tag = .arrow,
                    .text = self.source[start..self.cursor],
                };
            }

            if (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor]))
                return self.numberToken(start);

            return self.simpleToken(.invalid, start);
        },
        '%', '@', '.' => {
            const tag: TokenTag = switch (byte) {
                '%' => .value_ref,
                '@' => .at_name,
                '.' => .dot_name,
                else => unreachable,
            };
            const content_start = self.cursor;

            if (byte == '%' and self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) {
                while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) self.cursor += 1;
            } else {
                while (self.cursor < self.source.len and isNameByte(self.source[self.cursor])) self.cursor += 1;
            }

            if (self.cursor == content_start)
                return self.simpleToken(.invalid, start);

            return .{
                .tag = tag,
                .text = self.source[content_start..self.cursor],
            };
        },
        '#' => {
            const number_start = self.cursor;
            while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor]))
                self.cursor += 1;

            if (self.cursor == number_start)
                return self.simpleToken(.invalid, start);

            return .{
                .tag = .constant_ref,
                .text = self.source[number_start..self.cursor],
            };
        },
        else => {},
    }

    if (std.ascii.isDigit(byte))
        return self.numberToken(start);

    if (isNameStart(byte)) {
        while (self.cursor < self.source.len and isNameByte(self.source[self.cursor]))
            self.cursor += 1;

        return .{
            .tag = .identifier,
            .text = self.source[start..self.cursor],
        };
    }

    return self.simpleToken(.invalid, start);
}

fn numberToken(self: *Self, start: usize) Token {
    var number_start = start;
    if (self.source[number_start] == '-' or self.source[number_start] == '+')
        number_start += 1;

    self.cursor = number_start;

    if (self.source[number_start] == '0' and number_start + 1 < self.source.len and self.source[number_start + 1] == 'x') {
        self.cursor = number_start + 2;
        while (self.cursor < self.source.len and std.ascii.isHex(self.source[self.cursor]))
            self.cursor += 1;
    } else {
        while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor]))
            self.cursor += 1;

        if (self.cursor < self.source.len and self.source[self.cursor] == '.') {
            self.cursor += 1;
            while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor]))
                self.cursor += 1;
        }

        if (self.cursor < self.source.len and (self.source[self.cursor] == 'e' or self.source[self.cursor] == 'E')) {
            self.cursor += 1;
            if (self.cursor < self.source.len and (self.source[self.cursor] == '-' or self.source[self.cursor] == '+'))
                self.cursor += 1;
            while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor]))
                self.cursor += 1;
        }
    }

    return .{
        .tag = .number,
        .text = self.source[start..self.cursor],
    };
}

fn simpleToken(self: *Self, tag: TokenTag, start: usize) Token {
    return .{
        .tag = tag,
        .text = self.source[start..self.cursor],
    };
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
