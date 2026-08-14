const std = @import("std");
const compute = @import("compute/compute.zig");
const shared = @import("../../ir/validator.zig");
const instruction = @import("../../ir/instruction.zig");
const operand = @import("../../ir/operand.zig");
const program_ir = @import("../../ir/program.zig");

pub const Error = shared.Error || compute.Error || error{
    UnsupportedGeneration,
    UnsupportedDispatchWidth,
    UnsupportedGrfSize,
    UnsupportedExecutionSize,
    UnsupportedDataType,
    InvalidPhysicalFlag,
    InvalidBindingTableIndex,
    InvalidPayloadLayout,
};

pub fn validate(program: *const program_ir.Program) Error!void {
    try shared.validate(program);

    if (program.device_info.generation != .gen9)
        return Error.UnsupportedGeneration;
    try compute.validateWorkgroupSize(program.workgroup_size);
    if (program.dispatch_width != .simd8 or !program.device_info.supportsDispatch(.simd8))
        return Error.UnsupportedDispatchWidth;
    if (program.device_info.grf_size_bytes != 32)
        return Error.UnsupportedGrfSize;

    for (program.blocks.entries.items) |block_entry| {
        const block = block_entry orelse continue;
        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.get(instruction_id) orelse return Error.InvalidInstruction;
            switch (inst.execution_size) {
                .simd1, .simd8 => {},
                else => return Error.UnsupportedExecutionSize,
            }
            try validateInstruction(inst.*);
        }
        try validateTerminator(block.terminator.?);
    }

    for (program.virtual_registers.entries.items) |entry| {
        const register = entry orelse continue;
        if (!register.element_type.isInitialTargetType())
            return Error.UnsupportedDataType;
    }

    try validatePayload(program);
}

fn validateInstruction(inst: instruction.Instruction) Error!void {
    if (inst.predicate) |predicate|
        try validateFlag(predicate.flag);
    switch (inst.operation) {
        .load_global_invocation_id => |op| try validateDestination(op.destination),
        .load_buffer => |op| {
            try validateBufferReference(op.buffer);
            try validateDestination(op.destination);
            try validateSource(op.byte_offset);
        },
        .store_buffer => |op| {
            try validateBufferReference(op.buffer);
            try validateSource(op.byte_offset);
            try validateSource(op.source);
        },
        .move => |op| {
            try validateDestination(op.destination);
            try validateSource(op.source);
        },
        .binary => |op| {
            try validateDestination(op.destination);
            try validateSource(op.lhs);
            try validateSource(op.rhs);
        },
        .compare => |op| {
            try validateFlag(op.destination);
            try validateSource(op.lhs);
            try validateSource(op.rhs);
        },
        .parallel_copy => |copy| {
            for (copy.register_copies) |item| {
                try validateDestination(item.destination);
                try validateSource(item.source);
            }
            for (copy.flag_copies) |item| switch (item.source) {
                .constant => {},
                .dynamic => |predicate| try validateFlag(predicate.flag),
            };
        },
    }
}

fn validateBufferReference(reference: instruction.BufferReference) Error!void {
    switch (reference) {
        .logical => {},
        .binding_table => |index| if (index >= compute.resource_layout.max_storage_buffers)
            return Error.InvalidBindingTableIndex,
    }
}

fn validateSource(source: operand.Source) Error!void {
    try validateType(source.type);
    switch (source.register) {
        .immediate => |immediate| try validateImmediate(immediate),
        else => {},
    }
}

fn validateDestination(destination: operand.Destination) Error!void {
    try validateType(destination.type);
}

fn validateType(data_type: operand.DataType) Error!void {
    if (!data_type.isInitialTargetType())
        return Error.UnsupportedDataType;
}

fn validateImmediate(immediate: operand.Immediate) Error!void {
    switch (immediate) {
        .u32, .i32, .f32 => {},
    }
}

fn validateTerminator(terminator: instruction.Terminator) Error!void {
    switch (terminator) {
        .conditional_branch => |branch| {
            try validateFlag(branch.predicate.flag);
            try validateEdge(branch.true_edge);
            try validateEdge(branch.false_edge);
        },
        .jump => |edge| try validateEdge(edge),
        else => {},
    }
}

fn validateEdge(edge: instruction.Edge) Error!void {
    for (edge.arguments) |argument| switch (argument) {
        .source => {},
        .predicate => |predicate_value| switch (predicate_value) {
            .constant => {},
            .dynamic => |predicate| try validateFlag(predicate.flag),
        },
    };
}

fn validateFlag(flag: operand.FlagRef) Error!void {
    switch (flag) {
        .virtual => {},
        .physical => |physical| if (physical.register != 0 or physical.subregister > 1)
            return Error.InvalidPhysicalFlag,
    }
}

fn validatePayload(program: *const program_ir.Program) Error!void {
    if (program.payload.header_grf) |header| {
        if (header.number != 0 or header.byte_offset != 0)
            return Error.InvalidPayloadLayout;
    }
}

test "[gen9] validator: layer target legality over shared structural validation" {
    const Builder = @import("../../ir/Builder.zig");
    const device = @import("../../device.zig");

    const gen11_device: device.DeviceInfo = .{
        .generation = .gen11,
        .platform = .ice_lake,
        .pci_device_id = 0x8a52,
        .grf_count = 128,
        .supports_simd16 = true,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, gen11_device, .simd16);
    defer program.deinit();
    var builder = Builder.init(&program);
    const entry = try builder.addBlock("entry");
    try builder.setTerminator(entry, .end_thread);

    try shared.validate(&program);
    try std.testing.expectError(Error.UnsupportedGeneration, validate(&program));

    program.device_info.generation = .gen9;
    try std.testing.expectError(Error.UnsupportedDispatchWidth, validate(&program));
}
