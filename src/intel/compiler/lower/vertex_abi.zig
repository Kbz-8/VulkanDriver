const std = @import("std");
const Builder = @import("../ir/Builder.zig");
const ids = @import("../ir/id.zig");
const instruction = @import("../ir/instruction.zig");
const operand = @import("../ir/operand.zig");
const program_ir = @import("../ir/program.zig");
const validator = @import("../ir/validator.zig");

pub const InputComponent = struct {
    location: u32,
    component: u8,
    payload_grf_offset: u16,
};

pub const Layout = struct {
    input_components: []const InputComponent,
    position_urb_offset: u16,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidProgram,
    UnsupportedTarget,
    MissingVertexPayload,
    InvalidLayout,
    UnsupportedStageIo,
    MissingPosition,
    ExistingUrbWrite,
};

pub fn run(allocator: std.mem.Allocator, program: *program_ir.Program, layout: Layout) Error!void {
    validator.validate(program) catch return Error.InvalidProgram;
    if (program.properties.stage_io_lowered)
        return;

    if (!program.properties.common_ir_lowered or !program.properties.block_parameters_lowered or
        program.properties.registers_allocated or program.properties.messages_lowered)
        return Error.InvalidProgram;
    if (program.device_info.generation != .gen9 or program.stage != .vertex or
        program.dispatch_width != .simd8 or program.device_info.grf_size_bytes != 32)
        return Error.UnsupportedTarget;

    const vertex_payload = program.payload.vertex orelse return Error.MissingVertexPayload;
    try validateLayout(program, vertex_payload, layout);

    var position_components = instruction.ChannelMask{ .x = false, .y = false, .z = false, .w = false };
    var end_thread_count: usize = 0;
    try preflight(program, layout, &position_components, &end_thread_count);
    if (!position_components.x or !position_components.y or !position_components.z or !position_components.w or end_thread_count == 0)
        return Error.MissingPosition;

    var builder = Builder.init(program);
    const position_payload = builder.addVirtualRegister(.{
        .size_bytes = 4 * program.device_info.grf_size_bytes,
        .alignment_bytes = program.device_info.grf_size_bytes,
        .element_type = .f32,
        .lane_count = 4 * @intFromEnum(program.dispatch_width),
        .class = .payload,
        .spillable = false,
        .name = "position_urb_payload",
    }) catch |err| return mapBuilderError(err);

    for (program.blocks.entries.items) |entry| {
        const block = entry orelse continue;
        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.get(instruction_id) orelse return Error.InvalidProgram;
            const replacement: ?instruction.Operation = switch (inst.operation) {
                .load_input => |load| .{ .move = .{
                    .destination = load.destination,
                    .source = .{
                        .register = .{ .physical_grf = try inputPhysicalGrf(program, vertex_payload, layout, load.semantic) },
                        .type = load.destination.type,
                        .region = operand.Region.contiguous(.simd8),
                    },
                } },
                .store_output => |store| blk: {
                    const component = try positionComponent(store.semantic);
                    break :blk .{ .move = .{
                        .destination = .{
                            .register = .{ .virtual = position_payload },
                            .type = .f32,
                            .region = .{ .byte_offset = @as(u16, component) * program.device_info.grf_size_bytes },
                        },
                        .source = store.source,
                    } };
                },
                else => null,
            };
            if (replacement) |operation|
                builder.replaceOperation(instruction_id, operation) catch |err| return mapBuilderError(err);
        }
    }

    for (program.blocks.entries.items, 0..) |entry, block_index| {
        const block = entry orelse continue;
        if (block.terminator.? != .end_thread)
            continue;
        _ = builder.appendInstruction(ids.BlockId.fromIndex(block_index), .simd8, null, .{
            .send = .{
                .message = .{ .urb_write = .{
                    .offset = layout.position_urb_offset,
                    .channels = .{},
                    .end_of_thread = true,
                } },
                .payload = .{
                    .base = .{ .virtual = position_payload },
                    .register_count = 4,
                },
            },
        }) catch |err| return mapBuilderError(err);
    }

    program.properties.stage_io_lowered = true;
    validator.validate(program) catch return Error.InvalidProgram;
    _ = allocator;
}

fn validateLayout(program: *const program_ir.Program, vertex_payload: program_ir.VertexPayload, layout: Layout) Error!void {
    if (vertex_payload.first_attribute_grf.byte_offset != 0 or vertex_payload.attribute_grf_count == 0)
        return Error.InvalidLayout;
    if (@as(u32, vertex_payload.first_attribute_grf.number) + vertex_payload.attribute_grf_count > program.device_info.grf_count)
        return Error.InvalidLayout;

    for (layout.input_components, 0..) |mapping, index| {
        if (mapping.component > 3 or mapping.payload_grf_offset >= vertex_payload.attribute_grf_count)
            return Error.InvalidLayout;
        for (layout.input_components[0..index]) |previous| {
            if (previous.location == mapping.location and previous.component == mapping.component)
                return Error.InvalidLayout;
        }
    }
}

fn preflight(program: *const program_ir.Program, layout: Layout, position_components: *instruction.ChannelMask, end_thread_count: *usize) Error!void {
    for (program.blocks.entries.items) |entry| {
        const block = entry orelse continue;
        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.get(instruction_id) orelse return Error.InvalidProgram;
            switch (inst.operation) {
                .load_input => |load| {
                    if (inst.execution_size != .simd8 or findInput(layout, load.semantic) == null)
                        return Error.UnsupportedStageIo;
                },
                .store_output => |store| {
                    if (inst.execution_size != .simd8 or store.source.type != .f32)
                        return Error.UnsupportedStageIo;
                    switch (try positionComponent(store.semantic)) {
                        0 => position_components.x = true,
                        1 => position_components.y = true,
                        2 => position_components.z = true,
                        3 => position_components.w = true,
                        else => unreachable,
                    }
                },
                .send => |send| switch (send.message) {
                    .urb_write => return Error.ExistingUrbWrite,
                },
                else => {},
            }
        }
        switch (block.terminator orelse return Error.InvalidProgram) {
            .end_thread => end_thread_count.* += 1,
            else => {},
        }
    }
}

fn findInput(layout: Layout, semantic: instruction.InterfaceSemantic) ?InputComponent {
    const location = switch (semantic) {
        .location => |location| location,
        .builtin => return null,
    };
    for (layout.input_components) |mapping| {
        if (mapping.location == location.location and mapping.component == location.component)
            return mapping;
    }
    return null;
}

fn inputPhysicalGrf(program: *const program_ir.Program, vertex_payload: program_ir.VertexPayload, layout: Layout, semantic: instruction.InterfaceSemantic) Error!operand.PhysicalGrf {
    const mapping = findInput(layout, semantic) orelse return Error.UnsupportedStageIo;
    const number = @as(u32, vertex_payload.first_attribute_grf.number) + mapping.payload_grf_offset;
    if (number >= program.device_info.grf_count)
        return Error.InvalidLayout;
    return .{ .number = @intCast(number) };
}

fn positionComponent(semantic: instruction.InterfaceSemantic) Error!u8 {
    return switch (semantic) {
        .builtin => |builtin| if (builtin.builtin == .position and builtin.component <= 3)
            builtin.component
        else
            Error.UnsupportedStageIo,
        .location => Error.UnsupportedStageIo,
    };
}

fn mapBuilderError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.InvalidProgram,
    };
}

fn appendTestShaderBody(program: *program_ir.Program, position_component_count: u8) !ids.BlockId {
    var builder = Builder.init(program);
    program.properties.common_ir_lowered = true;
    program.properties.block_parameters_lowered = true;
    program.payload.vertex = .{
        .first_attribute_grf = .{ .number = 4 },
        .attribute_grf_count = 4,
    };

    const attribute = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .f32,
        .lane_count = 8,
        .class = .varying,
        .name = "attribute",
    });
    const entry = try builder.addBlock("entry");
    _ = try builder.appendInstruction(entry, .simd8, null, .{
        .load_input = .{
            .destination = .{ .register = .{ .virtual = attribute }, .type = .f32 },
            .semantic = .{ .location = .{ .location = 2, .component = 1 } },
        },
    });

    for (0..position_component_count) |component| {
        const position = try builder.addVirtualRegister(.{
            .size_bytes = 32,
            .alignment_bytes = 32,
            .element_type = .f32,
            .lane_count = 8,
            .class = .temporary,
            .name = "position",
        });
        _ = try builder.appendInstruction(entry, .simd8, null, .{
            .store_output = .{
                .semantic = .{ .builtin = .{ .builtin = .position, .component = @intCast(component) } },
                .source = .{
                    .register = .{ .virtual = position },
                    .type = .f32,
                    .region = operand.Region.contiguous(.simd8),
                },
            },
        });
    }
    return entry;
}

const test_input_layout = [_]InputComponent{.{
    .location = 2,
    .component = 1,
    .payload_grf_offset = 3,
}};

const test_layout: Layout = .{
    .input_components = &test_input_layout,
    .position_urb_offset = 7,
};

test "vertex ABI: lower explicit input payload and position URB output" {
    const device = @import("../device.zig");
    const printer = @import("../ir/printer.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    program.properties.common_ir_lowered = true;
    program.properties.block_parameters_lowered = true;
    program.payload.vertex = .{
        .first_attribute_grf = .{ .number = 4 },
        .attribute_grf_count = 4,
    };

    const attribute = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .f32,
        .lane_count = 8,
        .class = .varying,
        .name = "attribute",
    });
    const position_names = [_][]const u8{ "position_x", "position_y", "position_z", "position_w" };
    var position: [4]ids.VirtualRegisterId = undefined;
    for (&position, position_names) |*register_id, name| {
        register_id.* = try builder.addVirtualRegister(.{
            .size_bytes = 32,
            .alignment_bytes = 32,
            .element_type = .f32,
            .lane_count = 8,
            .class = .temporary,
            .name = name,
        });
    }

    const entry = try builder.addBlock("entry");
    _ = try builder.appendInstruction(entry, .simd8, null, .{
        .load_input = .{
            .destination = .{ .register = .{ .virtual = attribute }, .type = .f32 },
            .semantic = .{ .location = .{ .location = 2, .component = 1 } },
        },
    });
    for (position, 0..) |register_id, component| {
        _ = try builder.appendInstruction(entry, .simd8, null, .{
            .store_output = .{
                .semantic = .{ .builtin = .{ .builtin = .position, .component = @intCast(component) } },
                .source = .{
                    .register = .{ .virtual = register_id },
                    .type = .f32,
                    .region = operand.Region.contiguous(.simd8),
                },
            },
        });
    }
    try builder.setTerminator(entry, .end_thread);
    try validator.validate(&program);

    const input_layout = [_]InputComponent{.{
        .location = 2,
        .component = 1,
        .payload_grf_offset = 3,
    }};
    try run(std.testing.allocator, &program, .{
        .input_components = &input_layout,
        .position_urb_offset = 7,
    });
    try run(std.testing.allocator, &program, .{
        .input_components = &input_layout,
        .position_urb_offset = 7,
    });

    try std.testing.expect(program.properties.stage_io_lowered);
    try std.testing.expect(!program.properties.messages_lowered);
    try std.testing.expect(!program.properties.instructions_selected);

    const text = try printer.allocPrint(std.testing.allocator, &program);
    defer std.testing.allocator.free(text);
    for ([_][]const u8{
        "[simd8] mov %attribute:f32, r7:f32",
        "[simd8] mov %position_urb_payload:f32, %position_x:f32",
        "[simd8] mov %position_urb_payload:f32[byte=32], %position_y:f32",
        "[simd8] mov %position_urb_payload:f32[byte=64], %position_z:f32",
        "[simd8] mov %position_urb_payload:f32[byte=96], %position_w:f32",
        "send urb_write[offset(7), channels(xyzw), end_of_thread], payload(%position_urb_payload[4])",
    }) |fragment|
        try std.testing.expect(std.mem.indexOf(u8, text, fragment) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load_input") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_output") == null);
}

test "vertex ABI: reject invalid layout and incomplete position" {
    const device = @import("../device.zig");
    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var invalid_layout_program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer invalid_layout_program.deinit();
    var invalid_layout_builder = Builder.init(&invalid_layout_program);
    const invalid_layout_entry = try appendTestShaderBody(&invalid_layout_program, 4);
    try invalid_layout_builder.setTerminator(invalid_layout_entry, .end_thread);

    const out_of_range_input = [_]InputComponent{.{
        .location = 2,
        .component = 1,
        .payload_grf_offset = 4,
    }};
    try std.testing.expectError(Error.InvalidLayout, run(std.testing.allocator, &invalid_layout_program, .{
        .input_components = &out_of_range_input,
        .position_urb_offset = 7,
    }));

    const duplicate_inputs = [_]InputComponent{
        test_input_layout[0],
        test_input_layout[0],
    };
    try std.testing.expectError(Error.InvalidLayout, run(std.testing.allocator, &invalid_layout_program, .{
        .input_components = &duplicate_inputs,
        .position_urb_offset = 7,
    }));
    try std.testing.expect(!invalid_layout_program.properties.stage_io_lowered);

    var incomplete_program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer incomplete_program.deinit();
    var incomplete_builder = Builder.init(&incomplete_program);
    const incomplete_entry = try appendTestShaderBody(&incomplete_program, 3);
    try incomplete_builder.setTerminator(incomplete_entry, .end_thread);

    try std.testing.expectError(Error.MissingPosition, run(std.testing.allocator, &incomplete_program, test_layout));
    try std.testing.expect(!incomplete_program.properties.stage_io_lowered);
}

test "vertex ABI: reject an existing logical URB write" {
    const device = @import("../device.zig");
    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);
    const entry = try appendTestShaderBody(&program, 4);
    const payload = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .payload,
        .spillable = false,
        .name = "existing_payload",
    });
    _ = try builder.appendInstruction(entry, .simd8, null, .{
        .send = .{
            .message = .{ .urb_write = .{ .offset = 0 } },
            .payload = .{
                .base = .{ .virtual = payload },
                .register_count = 1,
            },
        },
    });
    try builder.setTerminator(entry, .end_thread);

    try std.testing.expectError(Error.ExistingUrbWrite, run(std.testing.allocator, &program, test_layout));
    try std.testing.expect(!program.properties.stage_io_lowered);
}

test "vertex ABI: append an EOT URB write to every shader exit" {
    const device = @import("../device.zig");
    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .vertex, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);
    const entry = try appendTestShaderBody(&program, 4);
    const first_exit = try builder.addBlock("first_exit");
    const second_exit = try builder.addBlock("second_exit");
    const condition = try builder.addVirtualFlag(.{ .name = "condition" });
    try builder.setTerminator(entry, .{ .conditional_branch = .{
        .predicate = .{ .flag = .{ .virtual = condition } },
        .true_edge = try builder.edge(first_exit, &.{}),
        .false_edge = try builder.edge(second_exit, &.{}),
    } });
    try builder.setTerminator(first_exit, .end_thread);
    try builder.setTerminator(second_exit, .end_thread);

    try run(std.testing.allocator, &program, test_layout);

    var urb_write_count: usize = 0;
    for (program.blocks.entries.items) |block_entry| {
        const block = block_entry orelse continue;
        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.get(instruction_id).?;
            switch (inst.operation) {
                .send => |send| switch (send.message) {
                    .urb_write => |urb_write| {
                        try std.testing.expect(urb_write.end_of_thread);
                        try std.testing.expectEqual(@as(u16, 7), urb_write.offset);
                        urb_write_count += 1;
                    },
                },
                else => {},
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), urb_write_count);
    try validator.validate(&program);
}
