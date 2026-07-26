//! Backend-specific shader IR for Intel Gen hardware.
//! This is the mutable, non-SSA layer between the shared shader IR and machine  encoding.

pub const device = @import("device.zig");
pub const id = @import("id.zig");
pub const instruction = @import("instruction.zig");
pub const lower = @import("lower.zig");
pub const operand = @import("operand.zig");
pub const printer = @import("printer.zig");
pub const program = @import("program.zig");
pub const validator = @import("validator.zig");

pub const Function = program.Function;
pub const FunctionId = id.FunctionId;
pub const Program = program.Program;
pub const Stage = program.Stage;

const std = @import("std");

test "Flint IR foundation" {
    // ; Flint program:
    // ;   .stage: vertex
    // ;   .generation: gen9
    // ;   .platform: skylake
    // ;   .dispatch_width: simd8
    // ;   .entry: @main
    //
    // %position: vgrf f32[8] = class(varying), size(32), alignment(32), spillable(true)
    // %urb_payload: vgrf u32[16] = class(payload), size(64), alignment(32), spillable(false)
    //
    // fn @main() -> void
    // {
    //     .entry:
    //         [simd8] %position.0<1>:f32 = load_input location(0), component(0)
    //         [simd8] %position.0<1>:f32 = multiply %position.0<8;8,1>:f32, 1:f32
    //         [simd8] store_output builtin(position), component(0), %position.0<8;8,1>:f32
    //         [simd8] send urb_write[offset(0), channels(xyzw), end_of_thread], payload(%urb_payload.0[2])
    //         end_thread
    //
    // }

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var shader = Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer shader.deinit();

    const main = try shader.addFunction(null, "main");
    try shader.setEntryFunction(main);

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
    const entry = try shader.addBlock(main, "entry");

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

    try std.testing.expectEqual(main, shader.entry_function.?);
    try std.testing.expectEqual(entry, shader.functions.get(main).?.entry_block.?);
    try std.testing.expect(shader.properties.instructions_selected);

    const text = try printer.allocPrint(std.testing.allocator, &shader);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Flint program") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "vertex") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gen9") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skylake") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "simd8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@main") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%position: vgrf f32[8]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[simd8] %position.0<1>:f32 = multiply %position.0<8;8,1>:f32, 1:f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "send urb_write[offset(0), channels(xyzw), end_of_thread], payload(%urb_payload.0[2])") != null);
}

test "Flint IR function calls" {
    // ; Flint program:
    // ;   .stage: vertex
    // ;   .generation: gen9
    // ;   .platform: skylake
    // ;   .dispatch_width: simd8
    // ;   .entry: @main
    //
    // %value: vgrf u32[8] = class(temporary), size(32), alignment(32), spillable(true)
    // %result: vgrf u32[8] = class(temporary), size(32), alignment(32), spillable(true)
    //
    // fn @main() -> void
    // {
    //     .entry:
    //         [simd8] %result.0<1>:u32 = call @identity(1:u32)
    //         end_thread
    //
    // }
    //
    // fn @identity(%value: u32) -> u32
    // {
    //     .entry:
    //         return %value.0<8;8,1>:u32
    //
    // }

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var shader = Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer shader.deinit();

    const main = try shader.addFunction(null, "main");
    const identity = try shader.addFunction(.u32, "identity");
    try shader.setEntryFunction(main);

    const parameter = try shader.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
        .name = "value",
    });
    const result = try shader.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
        .name = "result",
    });
    try shader.addFunctionParameter(identity, parameter);

    const main_entry = try shader.addBlock(main, "entry");
    const identity_entry = try shader.addBlock(identity, "entry");

    const call_id = try shader.appendInstruction(main_entry, .simd8, null, .{
        .call = .{
            .function = identity,
            .destination = .{
                .register = .{ .virtual = result },
                .type = .u32,
            },
            .arguments = &.{
                .{
                    .register = .{ .immediate = .{ .u32 = 1 } },
                    .type = .u32,
                    .region = operand.Region.broadcast(),
                },
            },
        },
    });
    try shader.setTerminator(main_entry, .end_thread);
    try shader.setTerminator(identity_entry, .{ .return_value = .{
        .register = .{ .virtual = parameter },
        .type = .u32,
        .region = operand.Region.contiguous(.simd8),
    } });

    try validator.validate(&shader);

    const call = shader.instructions.get(call_id).?.operation.call;
    try std.testing.expectEqual(identity, call.function);
    try std.testing.expectEqual(@as(usize, 1), call.arguments.len);

    const text = try printer.allocPrint(std.testing.allocator, &shader);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn @identity(%value: u32) -> u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[simd8] %result.0<1>:u32 = call @identity(1:u32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "return %value.0<8;8,1>:u32") != null);
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
