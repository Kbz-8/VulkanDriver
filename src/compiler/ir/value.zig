const ids = @import("id.zig");

pub const TypeId = ids.TypeId;
pub const ConstantId = ids.ConstantId;
pub const InstructionId = ids.InstructionId;
pub const FunctionId = ids.FunctionId;
pub const BlockId = ids.BlockId;

pub const FunctionParameterDefinition = struct {
    function: FunctionId,
    index: u32,
};

pub const BlockParameterDefinition = struct {
    block: BlockId,
    index: u32,
};

pub const Definition = union(enum) {
    constant: ConstantId,
    function_parameter: FunctionParameterDefinition,
    block_parameter: BlockParameterDefinition,
    instruction: InstructionId,
    undef,
};

pub const Value = struct {
    type: TypeId,
    definition: Definition,
    name: ?[]const u8 = null,
};
