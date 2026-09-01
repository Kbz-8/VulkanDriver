const shader_ir = @import("shader_ir").ir;
const registers = @import("imci/registers.zig");

pub const ActiveMask = union(enum) {
    full,
    register: registers.Mask,
    spilled: u32,
};

pub const Region = union(enum) {
    block: shader_ir.id.BlockId,
    selection: struct {
        header: shader_ir.id.BlockId,
        merge: shader_ir.id.BlockId,
    },
    loop: struct {
        header: shader_ir.id.BlockId,
        merge: shader_ir.id.BlockId,
        continue_block: shader_ir.id.BlockId,
    },
};

pub const State = struct {
    active_mask: ActiveMask = .full,
    loop_depth: u16 = 0,
    selection_depth: u16 = 0,
};
