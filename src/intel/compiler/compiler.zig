//! Flint-specific shader IR for Intel Gen hardware.
//! This is the mutable, non-SSA layer between the common shader IR and machine code.

pub const device = @import("device.zig");
pub const ir = @import("ir/ir.zig");
pub const lower = @import("lower/lower.zig");
pub const targets = @import("targets/targets.zig");

pub const Builder = ir.Builder;
pub const id = ir.id;
pub const instruction = ir.instruction;
pub const operand = ir.operand;
pub const printer = ir.printer;
pub const program = ir.program;
pub const pseudo = ir.pseudo;
pub const validator = ir.validator;

pub const Program = ir.Program;

const std = @import("std");

test "[ir] basic compute shader" {
    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var shader = Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer shader.deinit();
    var builder = Builder.init(&shader);

    const value = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
        .name = "value",
    });
    const storage = try builder.addStorageBuffer(.{ .set = 0, .binding = 1, .name = "storage" });
    const entry = try builder.addBlock("entry");
    try builder.setEntryBlock(entry);

    _ = try builder.appendInstruction(entry, .simd8, null, .{
        .load_global_invocation_id = .{
            .destination = .{ .register = .{ .virtual = value }, .type = .u32 },
            .component = 0,
        },
    });
    _ = try builder.appendInstruction(entry, .simd8, null, .{
        .store_buffer = .{
            .buffer = storage,
            .byte_offset = .{
                .register = .{ .immediate = .{ .u32 = 0 } },
                .type = .u32,
                .region = operand.Region.broadcast(),
            },
            .source = .{
                .register = .{ .virtual = value },
                .type = .u32,
                .region = operand.Region.contiguous(.simd8),
            },
        },
    });
    try builder.setTerminator(entry, .end_thread);
    try validator.validate(&shader);

    const text = try printer.allocPrint(std.testing.allocator, &shader);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Flint compute program") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@storage = storage_buffer[set(0), binding(1)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load_global_invocation_id %value:u32, component(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_buffer @storage, 0:u32, %value:u32") != null);
}

test "[ir] ID stability after removal" {
    var store: id.Store(id.VirtualFlagId, operand.VirtualFlag) = .{};
    defer store.entries.deinit(std.testing.allocator);

    const first = try store.add(std.testing.allocator, .{ .name = "first" });
    try std.testing.expect(store.remove(first));
    const second = try store.add(std.testing.allocator, .{ .name = "second" });

    try std.testing.expect(first != second);
    try std.testing.expect(store.get(first) == null);
    try std.testing.expectEqualStrings("second", store.get(second).?.name.?);
}
