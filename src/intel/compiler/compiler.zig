//! Flint-specific shader IR for Intel Gen hardware.
//! This is the mutable, non-SSA layer between the common shader IR and machine code.

pub const device = @import("device.zig");
pub const ir = @import("ir/ir.zig");
pub const lower = @import("lower/lower.zig");

pub const id = ir.id;
pub const instruction = ir.instruction;
pub const operand = ir.operand;
pub const printer = ir.printer;
pub const program = ir.program;
pub const validator = ir.validator;

pub const Program = ir.Program;
pub const Stage = ir.Stage;

const std = @import("std");

test "Flint IR foundation" {
    // ; Flint program:
    // ;   .stage: vertex
    // ;   .generation: gen9
    // ;   .platform: skylake
    // ;   .dispatch_width: simd8
    //
    // %position: vgrf f32[8] = class(varying), size(32), alignment(32), spillable
    // %urb_payload: vgrf u32[16] = class(payload), size(64), alignment(32)
    //
    // .entry:
    //     [simd8] load_input %position:f32, location(0), component(0)
    //     [simd8] multiply %position:f32, %position:f32, 1:f32
    //     [simd8] mov %position:f32, %position:f32[byte=4, broadcast]
    //     [simd8] store_output builtin(position), component(0), %position:f32
    //     [simd8] send urb_write[offset(0), channels(xyzw), end_of_thread], payload(%urb_payload[2])
    //     end_thread

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var shader = Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer shader.deinit();

    const position = try shader.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .f32,
        .lane_count = 8,
        .class = .varying,
        .name = "position",
    });
    const urb_payload = try shader.addVirtualRegister(.{
        .size_bytes = 64,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 16,
        .class = .payload,
        .spillable = false,
        .name = "urb_payload",
    });
    const entry = try shader.addBlock("entry");
    try shader.setEntryBlock(entry);

    _ = try shader.appendInstruction(entry, .simd8, null, .{
        .load_input = .{
            .destination = .{
                .register = .{ .virtual = position },
                .type = .f32,
            },
            .semantic = .{
                .location = .{
                    .location = 0,
                },
            },
        },
    });
    _ = try shader.appendInstruction(entry, .simd8, null, .{
        .binary = .{
            .opcode = .multiply,
            .destination = .{
                .register = .{ .virtual = position },
                .type = .f32,
            },
            .lhs = .{
                .register = .{ .virtual = position },
                .type = .f32,
                .region = operand.Region.contiguous(.simd8),
            },
            .rhs = .{
                .register = .{
                    .immediate = .{ .f32 = 1.0 },
                },
                .type = .f32,
                .region = operand.Region.broadcast(),
            },
        },
    });
    _ = try shader.appendInstruction(entry, .simd8, null, .{
        .move = .{
            .destination = .{
                .register = .{ .virtual = position },
                .type = .f32,
            },
            .source = .{
                .register = .{ .virtual = position },
                .type = .f32,
                .region = .{
                    .byte_offset = 4,
                    .vertical_stride = 0,
                    .width = 1,
                    .horizontal_stride = 0,
                },
            },
        },
    });
    _ = try shader.appendInstruction(entry, .simd8, null, .{
        .store_output = .{
            .semantic = .{
                .builtin = .{ .builtin = .position },
            },
            .source = .{
                .register = .{ .virtual = position },
                .type = .f32,
                .region = operand.Region.contiguous(.simd8),
            },
        },
    });
    _ = try shader.appendInstruction(entry, .simd8, null, .{
        .send = .{
            .message = .{
                .urb_write = .{
                    .offset = 0,
                    .end_of_thread = true,
                },
            },
            .payload = .{
                .base = .{ .virtual = urb_payload },
                .register_count = 2,
            },
        },
    });
    try shader.setTerminator(entry, .end_thread);

    shader.properties.instructions_selected = true;
    try validator.validate(&shader);

    try std.testing.expectEqual(entry, shader.entry_block.?);
    try std.testing.expect(shader.properties.instructions_selected);

    const text = try printer.allocPrint(std.testing.allocator, &shader);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Flint program") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "vertex") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gen9") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skylake") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "simd8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%position: vgrf f32[8]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[simd8] multiply %position:f32, %position:f32, 1:f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[simd8] mov %position:f32, %position:f32[byte=4, broadcast]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "send urb_write[offset(0), channels(xyzw), end_of_thread], payload(%urb_payload[2])") != null);
}

test "ID stability after removal" {
    var store: id.Store(id.VirtualFlagId, operand.VirtualFlag) = .{};
    defer store.entries.deinit(std.testing.allocator);

    const first = try store.add(std.testing.allocator, .{ .name = "first" });
    try std.testing.expect(store.remove(first));
    const second = try store.add(std.testing.allocator, .{ .name = "second" });

    try std.testing.expect(first != second);
    try std.testing.expect(store.get(first) == null);
    try std.testing.expectEqualStrings("second", store.get(second).?.name.?);
}

test {
    _ = lower;
}
