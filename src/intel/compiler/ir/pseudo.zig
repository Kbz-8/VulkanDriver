const ids = @import("id.zig");
const operand = @import("operand.zig");

pub const PredicateValue = union(enum) {
    constant: bool,
    dynamic: operand.Predicate,
};

pub const BlockParameter = union(enum) {
    register: ids.VirtualRegisterId,
    flag: ids.VirtualFlagId,
};

pub const EdgeArgument = union(enum) {
    source: operand.Source,
    predicate: PredicateValue,
};

pub const RegisterCopy = struct {
    destination: operand.Destination,
    source: operand.Source,
};

pub const FlagCopy = struct {
    destination: ids.VirtualFlagId,
    source: PredicateValue,
};

/// A simultaneous assignment: every source is read before any destination is
/// written. This pseudo-operation must be eliminated before machine emission.
pub const ParallelCopy = struct {
    register_copies: []const RegisterCopy,
    flag_copies: []const FlagCopy,
};

test "[ir] pseudo: parallel copy ownership and printing" {
    const std = @import("std");
    const Builder = @import("Builder.zig");
    const device = @import("../device.zig");
    const printer = @import("printer.zig");
    const program_ir = @import("program.zig");
    const validator = @import("validator.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const source_register = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
        .name = "source",
    });
    const destination_register = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
        .name = "destination",
    });
    const source_flag = try builder.addVirtualFlag(.{ .name = "source_flag" });
    const destination_flag = try builder.addVirtualFlag(.{ .name = "destination_flag" });
    const entry = try builder.addBlock("entry");

    var register_copies = [_]RegisterCopy{.{
        .destination = .{
            .register = .{ .virtual = destination_register },
            .type = .u32,
        },
        .source = .{
            .register = .{ .virtual = source_register },
            .type = .u32,
            .region = operand.Region.contiguous(.simd8),
        },
    }};
    var flag_copies = [_]FlagCopy{.{
        .destination = destination_flag,
        .source = .{ .dynamic = .{ .flag = .{ .virtual = source_flag } } },
    }};

    const copy_id = try builder.appendInstruction(entry, .simd8, null, .{
        .parallel_copy = .{
            .register_copies = &register_copies,
            .flag_copies = &flag_copies,
        },
    });
    try builder.setTerminator(entry, .end_thread);

    const stored = program.instructions.get(copy_id).?.operation.parallel_copy;
    try std.testing.expect(stored.register_copies.ptr != register_copies[0..].ptr);
    try std.testing.expect(stored.flag_copies.ptr != flag_copies[0..].ptr);

    register_copies[0].source.register = .{ .immediate = .{ .u32 = 42 } };
    flag_copies[0].source = .{ .constant = false };
    try std.testing.expect(stored.register_copies[0].source.register == .virtual);
    try std.testing.expect(stored.flag_copies[0].source == .dynamic);

    try validator.validate(&program);

    const text = try printer.allocPrint(std.testing.allocator, &program);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "parallel_copy [%destination:u32 <- %source:u32, %destination_flag <- (+%source_flag)]",
    ) != null);

    program.properties.parallel_copies_lowered = true;
    try std.testing.expectError(error.UnloweredParallelCopy, validator.validate(&program));
}

test "[ir] pseudo: validator rejects invalid parallel copies" {
    const std = @import("std");
    const Builder = @import("Builder.zig");
    const device = @import("../device.zig");
    const program_ir = @import("program.zig");
    const validator = @import("validator.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const register_id = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const flag_id = try builder.addVirtualFlag(.{});
    const entry = try builder.addBlock("entry");
    const instruction_id = try builder.appendInstruction(entry, .simd8, null, .{
        .parallel_copy = .{
            .register_copies = &.{},
            .flag_copies = &.{},
        },
    });
    try builder.setTerminator(entry, .end_thread);

    try std.testing.expectError(error.EmptyParallelCopy, validator.validate(&program));

    const inst = program.instructions.getMut(instruction_id).?;
    inst.predicate = .{ .flag = .{ .virtual = flag_id } };
    try std.testing.expectError(error.PredicatedParallelCopy, validator.validate(&program));
    inst.predicate = null;

    const duplicate_copy: RegisterCopy = .{
        .destination = .{
            .register = .{ .virtual = register_id },
            .type = .u32,
        },
        .source = .{
            .register = .{ .immediate = .{ .u32 = 1 } },
            .type = .u32,
            .region = operand.Region.broadcast(),
        },
    };
    inst.operation = .{
        .parallel_copy = .{
            .register_copies = &.{ duplicate_copy, duplicate_copy },
            .flag_copies = &.{},
        },
    };
    try std.testing.expectError(error.DuplicateParallelCopyDestination, validator.validate(&program));
}
