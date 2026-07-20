const std = @import("std");
const ids = @import("../id.zig");
const inst_ir = @import("../instruction.zig");
const module_ir = @import("../module.zig");
const type_ir = @import("../type.zig");
const validator = @import("../validator/validator.zig");
const Lexer = @import("Lexer.zig");

const ast = @import("ast.zig");
const lowerer = @import("lower.zig");

pub const Error = error{
    UnexpectedToken,
    InvalidNumber,
    InvalidStage,
    InvalidType,
    InvalidOpcode,
    InvalidSemantic,
    DuplicateValue,
    DuplicateName,
    UnknownValue,
    UnknownConstant,
    UnknownInterface,
    UnknownFunction,
    UnknownBlock,
    MissingTerminator,
    MissingResultType,
    InvalidResult,
    InvalidCompositeIndex,
};

pub const max_file_size = 64 * 1024 * 1024;

const ValueRef = ast.ValueRef;
const ParsedModule = ast.ParsedModule;
const ParsedInterface = ast.ParsedInterface;
const ParsedConstantValue = ast.ParsedConstantValue;
const ParsedConstant = ast.ParsedConstant;
const ParsedParameter = ast.ParsedParameter;
const ParsedInstruction = ast.ParsedInstruction;
const ParsedBlock = ast.ParsedBlock;
const ParsedFunction = ast.ParsedFunction;
const ParsedEdge = ast.ParsedEdge;
const ParsedTerminator = ast.ParsedTerminator;
const ParsedOperation = ast.ParsedOperation;
const Token = Lexer.Token;
const TokenTag = Lexer.TokenTag;

const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    module: ?*module_ir.Module = null,

    fn parseInterface(self: *Parser) !ParsedInterface {
        const name = (try self.expect(.at_name)).text;

        try self.expectDiscard(.colon);
        const ty = try self.parseType();
        try self.expectDiscard(.equal);

        const direction_token = try self.expect(.identifier);
        const direction = std.meta.stringToEnum(module_ir.InterfaceDirection, direction_token.text) orelse return error.InvalidSemantic;
        try self.expectDiscard(.left_square);

        const semantic_name = (try self.expect(.identifier)).text;
        const semantic: module_ir.InterfaceSemantic = if (std.mem.eql(u8, semantic_name, "location")) blk: {
            try self.expectDiscard(.left_paren);
            const location = try self.parseUnsigned(u32, .number);
            try self.expectDiscard(.right_paren);

            try self.expectDiscard(.comma);
            try self.expectIdentifier("component");
            try self.expectDiscard(.left_paren);
            const component = try self.parseUnsigned(u8, .number);
            try self.expectDiscard(.right_paren);

            try self.expectDiscard(.comma);
            try self.expectIdentifier("index");
            try self.expectDiscard(.left_paren);
            const index = try self.parseUnsigned(u8, .number);
            try self.expectDiscard(.right_paren);

            break :blk .{
                .location = .{
                    .location = location,
                    .component = component,
                    .index = index,
                },
            };
        } else if (std.mem.eql(u8, semantic_name, "builtin")) blk: {
            try self.expectDiscard(.left_paren);
            const builtin_name = (try self.expect(.identifier)).text;
            try self.expectDiscard(.right_paren);

            const builtin = std.meta.stringToEnum(module_ir.Builtin, builtin_name) orelse return error.InvalidSemantic;
            break :blk .{ .builtin = builtin };
        } else return error.InvalidSemantic;

        try self.expectDiscard(.right_square);

        return .{
            .direction = direction,
            .name = name,
            .ty = ty,
            .semantic = semantic,
        };
    }

    fn parseConstant(self: *Parser) !ParsedConstant {
        const printed_value = try self.parseValueRef();

        try self.expectDiscard(.colon);
        try self.expectIdentifier("constant");

        const ty = try self.parseType();
        try self.expectDiscard(.equal);

        const token = try self.peek();

        const value: ParsedConstantValue = switch (token.tag) {
            .identifier => blk: {
                const word = (try self.take()).text;
                if (std.mem.eql(u8, word, "true"))
                    break :blk .{ .boolean = true };

                if (std.mem.eql(u8, word, "false"))
                    break :blk .{ .boolean = false };

                if (std.mem.eql(u8, word, "null"))
                    break :blk .null_value;

                if (std.mem.eql(u8, word, "undef"))
                    break :blk .undef;

                if (std.mem.eql(u8, word, "bits")) {
                    try self.expectDiscard(.left_paren);
                    const bits = try self.parseUnsigned(u64, .number);
                    try self.expectDiscard(.right_paren);

                    const ir_type = self.module.?.types.get(ty) orelse return error.InvalidType;

                    break :blk switch (ir_type.*) {
                        .integer => .{
                            .integer_bits = bits,
                        },
                        .floating => .{
                            .float_bits = bits,
                        },
                        else => return error.InvalidType,
                    };
                }
                return error.UnexpectedToken;
            },
            .left_square => .{
                .composite = try self.parseConstantList(),
            },
            .number => try self.parseDirectConstant(ty),
            else => return error.UnexpectedToken,
        };

        return .{
            .printed_value = printed_value,
            .ty = ty,
            .value = value,
        };
    }

    fn parseDirectConstant(self: *Parser, ty: ids.TypeId) !ParsedConstantValue {
        const text = (try self.expect(.number)).text;
        const ir_type = self.module.?.types.get(ty) orelse return error.InvalidType;

        return switch (ir_type.*) {
            .integer => |integer| .{ .integer_bits = try parseIntegerLiteral(integer, text) },
            .floating => |float| .{ .float_bits = try parseFloatLiteral(float.bits, text) },
            else => error.InvalidType,
        };
    }

    fn parseFunction(self: *Parser) !ParsedFunction {
        try self.expectIdentifier("fn");
        const name = (try self.expect(.at_name)).text;
        try self.expectDiscard(.left_paren);

        var parameters: std.ArrayList(ParsedParameter) = .empty;
        if ((try self.peek()).tag != .right_paren) {
            while (true) {
                const printed_value = try self.parseValueRef();
                try self.expectDiscard(.colon);

                const ty = try self.parseType();
                try parameters.append(self.allocator, .{ .printed_value = printed_value, .ty = ty });

                if (!try self.consume(.comma))
                    break;
            }
        }

        try self.expectDiscard(.right_paren);
        try self.expectDiscard(.arrow);

        const return_type = try self.parseType();

        var function: ParsedFunction = .{
            .name = name,
            .return_type = return_type,
            .parameters = parameters,
        };

        try self.expectDiscard(.left_brace);

        while ((try self.peek()).tag != .right_brace) {
            if ((try self.peek()).tag != .dot_name)
                return error.UnexpectedToken;
            try function.blocks.append(self.allocator, try self.parseBlock());
        }

        try self.expectDiscard(.right_brace);

        return function;
    }

    fn parseBlock(self: *Parser) !ParsedBlock {
        var block: ParsedBlock = .{
            .name = (try self.expect(.dot_name)).text,
        };

        try self.expectDiscard(.left_paren);

        if ((try self.peek()).tag != .right_paren) {
            while (true) {
                const printed_value = try self.parseValueRef();

                try self.expectDiscard(.colon);
                const ty = try self.parseType();
                try block.parameters.append(self.allocator, .{ .printed_value = printed_value, .ty = ty });

                if (!try self.consume(.comma))
                    break;
            }
        }

        try self.expectDiscard(.right_paren);
        try self.expectDiscard(.colon);

        while (block.terminator == null) {
            const token = try self.peek();

            if (token.tag == .right_brace or token.tag == .dot_name)
                return error.MissingTerminator;

            if (token.tag == .value_ref) {
                try block.instructions.append(self.allocator, try self.parseInstruction(true));
                continue;
            }

            if (token.tag != .identifier)
                return error.UnexpectedToken;

            if (isTerminatorName(token.text)) {
                block.terminator = try self.parseTerminator();
            } else {
                try block.instructions.append(self.allocator, try self.parseInstruction(false));
            }
        }

        return block;
    }

    fn parseInstruction(self: *Parser, has_result: bool) !ParsedInstruction {
        const printed_result = if (has_result) try self.parseValueRef() else null;
        const result_type = if (has_result and try self.consume(.colon)) try self.parseType() else null;

        if (has_result)
            try self.expectDiscard(.equal);

        return .{
            .printed_result = printed_result,
            .result_type = result_type,
            .operation = try self.parseOperation(),
        };
    }

    fn parseOperation(self: *Parser) !ParsedOperation {
        const name = (try self.expect(.identifier)).text;

        if (std.mem.startsWith(u8, name, "cmp_")) {
            const opcode_name = name["cmp_".len..];
            const opcode = std.meta.stringToEnum(inst_ir.CompareOpcode, opcode_name) orelse return error.InvalidOpcode;
            const lhs = try self.parseValueRef();

            try self.expectDiscard(.comma);

            return .{
                .compare = .{
                    .opcode = opcode,
                    .lhs = lhs,
                    .rhs = try self.parseValueRef(),
                },
            };
        }

        if (std.meta.stringToEnum(inst_ir.UnaryOpcode, name)) |opcode| {
            return .{ .unary = .{ .opcode = opcode, .operand = try self.parseValueRef() } };
        }

        if (std.meta.stringToEnum(inst_ir.BinaryOpcode, name)) |opcode| {
            const lhs = try self.parseValueRef();
            try self.expectDiscard(.comma);
            return .{ .binary = .{ .opcode = opcode, .lhs = lhs, .rhs = try self.parseValueRef() } };
        }

        if (std.mem.eql(u8, name, "select")) {
            const condition = try self.parseValueRef();
            try self.expectDiscard(.comma);
            const true_value = try self.parseValueRef();
            try self.expectDiscard(.comma);
            return .{ .select = .{
                .condition = condition,
                .true_value = true_value,
                .false_value = try self.parseValueRef(),
            } };
        }

        if (std.mem.eql(u8, name, "bitcast"))
            return .{ .bitcast = try self.parseValueRef() };

        if (std.mem.eql(u8, name, "composite_construct"))
            return .{ .composite_construct = try self.parseTrailingValueList() };

        if (std.mem.eql(u8, name, "composite_extract")) {
            const composite = try self.parseValueRef();
            var indices: std.ArrayList(u32) = .empty;

            while (try self.consume(.left_square)) {
                try indices.append(self.allocator, try self.parseUnsigned(u32, .number));
                try self.expectDiscard(.right_square);
            }

            if (indices.items.len == 0)
                return error.InvalidCompositeIndex;
            return .{
                .composite_extract = .{
                    .composite = composite,
                    .indices = indices.items,
                },
            };
        }

        if (std.mem.eql(u8, name, "load_interface"))
            return .{
                .load_interface = (try self.expect(.at_name)).text,
            };

        if (std.mem.eql(u8, name, "store_interface")) {
            const interface_name = (try self.expect(.at_name)).text;
            try self.expectDiscard(.comma);
            return .{
                .store_interface = .{
                    .interface_name = interface_name,
                    .value = try self.parseValueRef(),
                },
            };
        }

        if (std.mem.eql(u8, name, "call")) {
            const function_name = (try self.expect(.at_name)).text;
            try self.expectDiscard(.left_paren);

            const arguments = try self.parseDelimitedValueList(.right_paren);
            try self.expectDiscard(.right_paren);

            return .{
                .call = .{
                    .function_name = function_name,
                    .arguments = arguments,
                },
            };
        }

        return error.InvalidOpcode;
    }

    fn parseTerminator(self: *Parser) !ParsedTerminator {
        const name = (try self.expect(.identifier)).text;

        if (std.mem.eql(u8, name, "branch"))
            return .{ .branch = try self.parseEdge() };

        if (std.mem.eql(u8, name, "conditional_branch")) {
            const condition = try self.parseValueRef();
            try self.expectDiscard(.comma);

            const true_edge = try self.parseEdge();
            try self.expectDiscard(.comma);

            return .{
                .conditional_branch = .{
                    .condition = condition,
                    .true_edge = true_edge,
                    .false_edge = try self.parseEdge(),
                },
            };
        }

        if (std.mem.eql(u8, name, "return")) {
            if ((try self.peek()).tag == .value_ref)
                return .{ .return_value = try self.parseValueRef() };
            return .return_void;
        }

        if (std.mem.eql(u8, name, "discard"))
            return .discard;

        if (std.mem.eql(u8, name, "unreachable"))
            return .unreachable_value;

        return error.UnexpectedToken;
    }

    fn parseEdge(self: *Parser) !ParsedEdge {
        const block_name = (try self.expect(.dot_name)).text;
        try self.expectDiscard(.left_paren);

        const arguments = try self.parseDelimitedValueList(.right_paren);
        try self.expectDiscard(.right_paren);

        return .{
            .block_name = block_name,
            .arguments = arguments,
        };
    }

    fn parseType(self: *Parser) !ids.TypeId {
        const token = try self.expect(.identifier);
        const module = self.module.?;

        if (std.mem.eql(u8, token.text, "void"))
            return module.internType(.void);

        if (std.mem.eql(u8, token.text, "bool"))
            return module.internType(.boolean);

        if (std.mem.startsWith(u8, token.text, "vec")) {
            const length = parseTextUnsigned(u8, token.text[3..]) catch return error.InvalidType;
            try self.expectDiscard(.left_square);

            const element_type = try self.parseType();
            try self.expectDiscard(.right_square);

            return module.internType(.{
                .vector = .{
                    .element_type = element_type,
                    .length = length,
                },
            });
        }

        if (std.mem.eql(u8, token.text, "array")) {
            try self.expectDiscard(.left_square);

            const element_type = try self.parseType();
            try self.expectDiscard(.comma);

            const length = try self.parseUnsigned(u32, .number);
            try self.expectDiscard(.right_square);

            return module.internType(.{
                .array = .{
                    .element_type = element_type,
                    .length = length,
                },
            });
        }

        if (std.mem.eql(u8, token.text, "struct")) {
            try self.expectDiscard(.left_square);
            var members: std.ArrayList(ids.TypeId) = .empty;

            if ((try self.peek()).tag != .right_square) {
                while (true) {
                    try members.append(self.allocator, try self.parseType());
                    if (!try self.consume(.comma))
                        break;
                }
            }

            try self.expectDiscard(.right_square);

            return module.internType(.{
                .structure = .{
                    .members = members.items,
                },
            });
        }

        if (std.mem.eql(u8, token.text, "ptr")) {
            try self.expectDiscard(.left_square);

            const address_name = (try self.expect(.identifier)).text;
            const address_space = std.meta.stringToEnum(type_ir.AddressSpace, address_name) orelse return error.InvalidType;
            try self.expectDiscard(.comma);

            const pointee_type = try self.parseType();
            try self.expectDiscard(.right_square);

            return module.internType(.{
                .pointer = .{
                    .address_space = address_space,
                    .pointee_type = pointee_type,
                },
            });
        }

        if (std.mem.eql(u8, token.text, "resourceHandle")) {
            try self.expectDiscard(.left_square);

            const kind_name = (try self.expect(.identifier)).text;
            const kind = std.meta.stringToEnum(type_ir.ResourceKind, kind_name) orelse return error.InvalidType;

            try self.expectDiscard(.right_square);

            return module.internType(.{
                .resource_handle = .{
                    .kind = kind,
                },
            });
        }

        if (token.text.len > 1 and (token.text[0] == 'i' or token.text[0] == 'u')) {
            const bits = parseTextUnsigned(u16, token.text[1..]) catch return error.InvalidType;
            return module.internType(.{ .integer = .{
                .bits = bits,
                .signedness = if (token.text[0] == 'i') .signed else .unsigned,
            } });
        }

        if (token.text.len > 1 and token.text[0] == 'f') {
            const bits = parseTextUnsigned(u16, token.text[1..]) catch return error.InvalidType;
            return module.internType(.{
                .floating = .{
                    .bits = bits,
                },
            });
        }
        return error.InvalidType;
    }

    fn parseConstantList(self: *Parser) ![]const u32 {
        try self.expectDiscard(.left_square);
        var values: std.ArrayList(u32) = .empty;

        if ((try self.peek()).tag != .right_square) {
            while (true) {
                try values.append(self.allocator, try self.parseUnsigned(u32, .constant_ref));
                if (!try self.consume(.comma))
                    break;
            }
        }

        try self.expectDiscard(.right_square);
        return values.items;
    }

    fn parseTrailingValueList(self: *Parser) ![]const ValueRef {
        var values: std.ArrayList(ValueRef) = .empty;
        if ((try self.peek()).tag != .value_ref)
            return values.items;

        while (true) {
            try values.append(self.allocator, try self.parseValueRef());
            if (!try self.consume(.comma))
                break;
        }

        return values.items;
    }

    fn parseDelimitedValueList(self: *Parser, closing: TokenTag) ![]const ValueRef {
        var values: std.ArrayList(ValueRef) = .empty;
        if ((try self.peek()).tag == closing)
            return values.items;

        while (true) {
            try values.append(self.allocator, try self.parseValueRef());
            if (!try self.consume(.comma))
                break;
        }

        return values.items;
    }

    fn parseValueRef(self: *Parser) !ValueRef {
        return (try self.expect(.value_ref)).text;
    }

    fn parseUnsigned(self: *Parser, comptime T: type, tag: TokenTag) !T {
        const token = try self.expect(tag);
        return parseTextUnsigned(T, token.text) catch error.InvalidNumber;
    }

    fn expectIdentifier(self: *Parser, expected: []const u8) !void {
        const token = try self.expect(.identifier);
        if (!std.mem.eql(u8, token.text, expected))
            return error.UnexpectedToken;
    }

    fn expectDiscard(self: *Parser, tag: TokenTag) !void {
        _ = try self.expect(tag);
    }

    fn expect(self: *Parser, tag: TokenTag) !Token {
        const token = try self.take();
        if (token.tag != tag)
            return error.UnexpectedToken;
        return token;
    }

    fn consume(self: *Parser, tag: TokenTag) !bool {
        if ((try self.peek()).tag != tag)
            return false;
        _ = try self.take();
        return true;
    }

    fn peek(self: *Parser) !Token {
        return self.lexer.peek();
    }

    fn take(self: *Parser) !Token {
        const token = self.lexer.take();
        if (token.tag == .invalid)
            return error.UnexpectedToken;
        return token;
    }
};

fn isTerminatorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "branch") or
        std.mem.eql(u8, name, "conditional_branch") or
        std.mem.eql(u8, name, "return") or
        std.mem.eql(u8, name, "discard") or
        std.mem.eql(u8, name, "unreachable");
}

fn parseIntegerLiteral(integer: type_ir.IntegerType, text: []const u8) !u64 {
    if (integer.bits == 0 or integer.bits > 64)
        return error.InvalidType;

    if (integer.signedness == .unsigned) {
        const value = std.fmt.parseInt(u64, text, 10) catch return error.InvalidNumber;
        if (integer.bits < 64) {
            const shift: u6 = @intCast(integer.bits);
            const maximum = (@as(u64, 1) << shift) - 1;
            if (value > maximum)
                return error.InvalidNumber;
        }
        return value;
    }

    const value = std.fmt.parseInt(i64, text, 10) catch return error.InvalidNumber;
    if (integer.bits < 64) {
        const sign_shift: u6 = @intCast(integer.bits - 1);
        const magnitude = @as(i64, 1) << sign_shift;
        if (value < -magnitude or value > magnitude - 1)
            return error.InvalidNumber;

        const width: u6 = @intCast(integer.bits);
        const mask = (@as(u64, 1) << width) - 1;
        return @as(u64, @bitCast(value)) & mask;
    }

    return @bitCast(value);
}

fn parseFloatLiteral(bits: u16, text: []const u8) !u64 {
    return switch (bits) {
        16 => blk: {
            const value = std.fmt.parseFloat(f16, text) catch return error.InvalidNumber;
            break :blk @as(u16, @bitCast(value));
        },
        32 => blk: {
            const value = std.fmt.parseFloat(f32, text) catch return error.InvalidNumber;
            break :blk @as(u32, @bitCast(value));
        },
        64 => blk: {
            const value = std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
            break :blk @as(u64, @bitCast(value));
        },
        else => error.InvalidType,
    };
}

fn parseTextUnsigned(comptime T: type, text: []const u8) !T {
    const base: u8 = if (std.mem.startsWith(u8, text, "0x")) 16 else 10;
    const digits = if (base == 16) text[2..] else text;

    if (digits.len == 0)
        return error.InvalidNumber;

    return std.fmt.parseInt(T, digits, base);
}

pub fn parseString(backing_allocator: std.mem.Allocator, source: []const u8) !module_ir.Module {
    var temporary = std.heap.ArenaAllocator.init(backing_allocator);
    defer temporary.deinit();
    const temporary_allocator = temporary.allocator();

    var parser: Parser = .{
        .lexer = .init(source),
        .allocator = temporary_allocator,
    };

    try parser.expectIdentifier("shader");
    const stage_token = try parser.expect(.identifier);
    const stage = std.meta.stringToEnum(module_ir.Stage, stage_token.text) orelse return error.InvalidStage;

    var module = module_ir.Module.init(backing_allocator, stage);
    errdefer module.deinit();
    parser.module = &module;

    const entry_point_name = if ((try parser.peek()).tag == .at_name)
        (try parser.take()).text
    else
        null;

    try parser.expectDiscard(.left_brace);

    var parsed: ParsedModule = .{ .entry_point_name = entry_point_name };
    while ((try parser.peek()).tag != .right_brace) {
        const token = try parser.peek();
        switch (token.tag) {
            .value_ref => try parsed.constants.append(temporary_allocator, try parser.parseConstant()),
            .at_name => try parsed.interfaces.append(temporary_allocator, try parser.parseInterface()),
            .identifier => {
                if (std.mem.eql(u8, token.text, "fn")) {
                    try parsed.functions.append(temporary_allocator, try parser.parseFunction());
                } else {
                    return error.UnexpectedToken;
                }
            },
            else => return error.UnexpectedToken,
        }
    }
    try parser.expectDiscard(.right_brace);
    try parser.expectDiscard(.eof);

    try lowerer.lower(temporary_allocator, &module, &parsed);
    try validator.validate(&module);
    return module;
}

pub fn parseFile(backing_allocator: std.mem.Allocator, io: std.Io, path: []const u8) !module_ir.Module {
    return parseFileInDir(backing_allocator, io, std.Io.Dir.cwd(), path);
}

pub fn parseFileInDir(backing_allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8) !module_ir.Module {
    const file = try directory.openFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = @splat(0);
    var reader = file.reader(io, &buffer);

    const source = try reader.interface.allocRemaining(backing_allocator, .limited(max_file_size));
    defer backing_allocator.free(source);

    return parseString(backing_allocator, source);
}
