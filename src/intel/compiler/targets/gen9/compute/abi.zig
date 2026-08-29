const operand = @import("../../../ir/operand.zig");
const program_ir = @import("../../../ir/program.zig");

pub const Error = error{
    InvalidPayloadLayout,
};

const thread_header: operand.PhysicalGrf = .{
    .number = 0,
    .byte_offset = 0,
};

pub fn run(program: *program_ir.Program) Error!void {
    if (program.properties.compute_abi_lowered)
        return;

    if (program.payload.header_grf) |header| {
        if (header.number != thread_header.number or header.byte_offset != thread_header.byte_offset)
            return Error.InvalidPayloadLayout;
    }
    if (program.program_data.payload_grf_count > 1)
        return Error.InvalidPayloadLayout;

    program.payload.header_grf = thread_header;
    program.program_data.payload_grf_count = 1;
    program.properties.compute_abi_lowered = true;
}

const std = @import("std");
const device = @import("../../../device.zig");

const test_device: device.DeviceInfo = .{
    .generation = .gen9,
    .platform = .skylake,
    .pci_device_id = 0x1912,
    .grf_count = 128,
};

test "[gen9] compute ABI: reserve thread header" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    try run(&program);

    try std.testing.expectEqual(thread_header, program.payload.header_grf.?);
    try std.testing.expectEqual(@as(u16, 1), program.program_data.payload_grf_count);
    try std.testing.expect(program.properties.compute_abi_lowered);

    try run(&program);
    try std.testing.expectEqual(@as(u16, 1), program.program_data.payload_grf_count);
}

test "[gen9] compute ABI: reject conflicting payload" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    program.payload.header_grf = .{ .number = 1 };

    try std.testing.expectError(Error.InvalidPayloadLayout, run(&program));
    try std.testing.expect(!program.properties.compute_abi_lowered);
}
