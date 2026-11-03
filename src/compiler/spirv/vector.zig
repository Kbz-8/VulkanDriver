const ir = @import("../ir/ir.zig");

pub fn splat(builder: *ir.Builder, block: ir.id.BlockId, result_type: ir.id.TypeId, scalar: ir.id.ValueId) !ir.id.ValueId {
    const ty = builder.module.types.get(result_type) orelse return error.InvalidInstruction;
    if (ty.* != .vector or ty.vector.length < 2 or ty.vector.length > 4)
        return error.InvalidInstruction;

    const vector = ty.vector;
    if (builder.module.typeOf(scalar) != vector.element_type)
        return error.InvalidInstruction;

    const element = builder.module.types.get(vector.element_type) orelse return error.InvalidInstruction;
    switch (element.*) {
        .boolean, .integer, .floating => {},
        else => return error.InvalidInstruction,
    }

    const elements: [4]ir.id.ValueId = @splat(scalar);

    return (try builder.appendInstruction(block, result_type, .{
        .composite_construct = .{
            .elements = elements[0..vector.length],
        },
    }, null)).?;
}

pub fn scale(builder: *ir.Builder, block: ir.id.BlockId, result_type: ir.id.TypeId, vector: ir.id.ValueId, scalar: ir.id.ValueId, name: ?[]const u8) !ir.id.ValueId {
    const ty = builder.module.types.get(result_type) orelse return error.InvalidInstruction;
    if (ty.* != .vector or builder.module.typeOf(vector) != result_type)
        return error.InvalidInstruction;

    const element = builder.module.types.get(ty.vector.element_type) orelse return error.InvalidInstruction;
    if (element.* != .floating)
        return error.InvalidInstruction;

    const factor = try splat(builder, block, result_type, scalar);

    return (try builder.appendInstruction(block, result_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = vector,
            .rhs = factor,
        },
    }, name)).?;
}
