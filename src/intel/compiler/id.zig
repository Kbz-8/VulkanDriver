const shared_ids = @import("shader_ir").ir.id;

pub const FunctionTag = opaque {};
pub const BlockTag = opaque {};
pub const InstructionTag = opaque {};
pub const VirtualRegisterTag = opaque {};
pub const VirtualFlagTag = opaque {};

pub const FunctionId = shared_ids.Id(FunctionTag);
pub const BlockId = shared_ids.Id(BlockTag);
pub const InstructionId = shared_ids.Id(InstructionTag);
pub const VirtualRegisterId = shared_ids.Id(VirtualRegisterTag);
pub const VirtualFlagId = shared_ids.Id(VirtualFlagTag);

pub const Id = shared_ids.Id;
pub const Store = shared_ids.Store;
