const std = @import("std");
const ir = @import("../../ir/ir.zig");
const glsl_std_450 = @import("glsl_std_450/glsl_std_450.zig");

pub const types = @import("types.zig");
pub const Set = types.Set;
pub const Invocation = types.Invocation;
pub const Emitter = types.Emitter;

pub fn classify(name: []const u8) Set {
    if (std.mem.eql(u8, name, "GLSL.std.450"))
        return .glsl_std_450;
    if (std.mem.startsWith(u8, name, "NonSemantic."))
        return .{ .non_semantic = name };
    return .{ .unsupported = name };
}

pub fn validateSupported(set: Set) !void {
    switch (set) {
        .glsl_std_450 => {},
        .non_semantic => |name| {
            std.log.scoped(.spirv_translator).err("unsupported non-semantic extended instruction set '{s}'", .{name});
            return error.UnsupportedExtendedInstructionSet;
        },
        .unsupported => |name| {
            std.log.scoped(.spirv_translator).err("unsupported extended instruction set '{s}'", .{name});
            return error.UnsupportedExtendedInstructionSet;
        },
    }
}

pub fn translate(set: Set, emitter: *Emitter, invocation: Invocation) !ir.id.ValueId {
    try validateSupported(set);
    return switch (set) {
        .glsl_std_450 => glsl_std_450.translate(emitter, invocation),
        .non_semantic, .unsupported => unreachable,
    };
}
