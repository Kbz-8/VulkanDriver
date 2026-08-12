const std = @import("std");
const shader_ir = @import("shader_ir");

const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ir = shader_ir.ir;

const copy_shader =
    \\ shader compute @main
    \\ {
    \\     @source: vec4[u32] = storage_buffer[set(2), binding(3)]
    \\     @destination: vec4[u32] = storage_buffer[set(4), binding(5)]
    \\
    \\     %source_offset: constant u32 = 1
    \\     %destination_offset: constant u32 = 2
    \\
    \\     fn @main() -> void
    \\     {
    \\         .entry():
    \\             %value: vec4[u32] = load_buffer @source, %source_offset
    \\             store_buffer @destination, %destination_offset, %value
    \\             return
    \\     }
    \\ }
;

const scalar_shader =
    \\ shader compute @main
    \\ {
    \\     @source: u32 = storage_buffer[set(0), binding(0)]
    \\     @destination: u32 = storage_buffer[set(0), binding(1)]
    \\
    \\     %zero: constant u32 = 0
    \\     %one: constant u32 = 1
    \\
    \\     fn @main() -> void
    \\     {
    \\         .entry():
    \\             %loaded: u32 = load_buffer @source, %zero
    \\             %value: u32 = integer_add %loaded, %one
    \\             store_buffer @destination, %zero, %value
    \\             return
    \\     }
    \\ }
;

const bounds_shader =
    \\ shader compute @main
    \\ {
    \\     @buffer: vec2[u32] = storage_buffer[set(0), binding(0)]
    \\
    \\     %offset: constant u32 = 1
    \\     %first: constant u32 = bits(0x11223344)
    \\     %second: constant u32 = bits(0x55667788)
    \\
    \\     fn @main() -> void
    \\     {
    \\         .entry():
    \\             %value: vec2[u32] = composite_construct %first, %second
    \\             store_buffer @buffer, %offset, %value
    \\             return
    \\     }
    \\ }
;

test "[interpreter] storage-buffer vector load and store use portable little-endian words" {
    var module = try ir.parser.parseString(std.testing.allocator, copy_shader);
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const source_id = ir.id.ResourceId.fromIndex(0);
    const destination_id = ir.id.ResourceId.fromIndex(1);
    try std.testing.expectEqual(@as(u32, 2), program.resourceBinding(source_id).?.set);
    try std.testing.expectEqual(@as(u32, 3), program.resourceBinding(source_id).?.binding);
    try std.testing.expectEqual(@as(u32, 4), program.resourceBinding(destination_id).?.set);
    try std.testing.expectEqual(@as(u32, 5), program.resourceBinding(destination_id).?.binding);

    var source = [_]u8{ 0xff, 0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x90, 0x04, 0x03, 0x02, 0x01, 0xdd, 0xcc, 0xbb, 0xaa };
    var destination = [_]u8{0xcc} ** 20;
    const resources = [_]?[]u8{ source[0..], destination[0..] };

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{ .resource_buffers = &resources }));
    try std.testing.expectEqualSlices(u8, source[1..17], destination[2..18]);
    try std.testing.expectEqual(@as(u8, 0xcc), destination[0]);
    try std.testing.expectEqual(@as(u8, 0xcc), destination[1]);
    try std.testing.expectEqual(@as(u8, 0xcc), destination[18]);
    try std.testing.expectEqual(@as(u8, 0xcc), destination[19]);
}

test "[interpreter] storage-buffer scalar load and store interpret little-endian words" {
    var module = try ir.parser.parseString(std.testing.allocator, scalar_shader);
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    var source = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    var destination = [_]u8{0} ** 4;
    const resources = [_]?[]u8{ source[0..], destination[0..] };
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{ .resource_buffers = &resources }));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x79, 0x56, 0x34, 0x12 }, &destination);
}

test "[interpreter] storage-buffer accesses report unbound and out-of-bounds resources" {
    var module = try ir.parser.parseString(std.testing.allocator, bounds_shader);
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try std.testing.expectError(Runtime.RuntimeError.ResourceNotBound, runtime.run(&program, .{}));

    var buffer = [_]u8{0xa5} ** 8;
    const resources = [_]?[]u8{buffer[0..]};
    try std.testing.expectError(Runtime.RuntimeError.BufferOutOfBounds, runtime.run(&program, .{ .resource_buffers = &resources }));
    const unchanged = [_]u8{0xa5} ** 8;
    try std.testing.expectEqualSlices(u8, &unchanged, &buffer);
}
