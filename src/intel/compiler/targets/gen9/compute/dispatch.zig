const std = @import("std");

pub const max_storage_surfaces: usize = 4;
pub const max_surfaces: usize = max_storage_surfaces + 1;
pub const num_workgroups_offset: u32 = max_storage_surfaces * @sizeOf(u32);
const size_table_size: u32 = num_workgroups_offset + 3 * @sizeOf(u32);
pub const page_size: usize = 4096;
pub const surface_state_size: usize = 64;
pub const interface_descriptor_size: usize = 32;

const mocs: u32 = 0x78;
pub const base_address_delta: u32 = 1 | (mocs << 4);
const raw_surface_format: u32 = 0x1ff;

pub const Error = error{
    EmptyBuffer,
    StateTooLarge,
    UnsupportedBufferSize,
    TooManySurfaces,
};

pub const StateLayout = struct {
    size: usize,
    kernel_offset: u32,
    surface_offsets: [max_surfaces]u32,
    surface_address_offsets: [max_surfaces]u32,
    surface_count: u8,
    storage_surface_count: u8,
    size_table_offset: u32,
    binding_table_offset: u32,
    interface_descriptor_offset: u32,
};

pub fn writeState(destination: []u8, kernel: []const u8, buffer_sizes: []const u64, group_count: [3]u32) Error!StateLayout {
    if (buffer_sizes.len > max_storage_surfaces)
        return Error.TooManySurfaces;

    var layout: StateLayout = .{
        .size = 0,
        .kernel_offset = 0,
        .surface_offsets = @splat(0),
        .surface_address_offsets = @splat(0),
        .surface_count = @intCast(buffer_sizes.len + 1),
        .storage_surface_count = @intCast(buffer_sizes.len),
        .size_table_offset = 0,
        .binding_table_offset = 0,
        .interface_descriptor_offset = 0,
    };

    var cursor = alignForward(kernel.len, 64);
    for (buffer_sizes, 0..) |size, index| {
        cursor = alignForward(cursor, surface_state_size);
        layout.surface_offsets[index] = @intCast(cursor);
        layout.surface_address_offsets[index] = @intCast(cursor + 8 * @sizeOf(u32));
        cursor += surface_state_size;
        if (size == 0)
            return Error.EmptyBuffer;
        if (size > std.math.maxInt(u32))
            return Error.UnsupportedBufferSize;
    }

    const size_table_surface = buffer_sizes.len;
    cursor = alignForward(cursor, surface_state_size);
    layout.surface_offsets[size_table_surface] = @intCast(cursor);
    layout.surface_address_offsets[size_table_surface] = @intCast(cursor + 8 * @sizeOf(u32));
    cursor += surface_state_size;

    cursor = alignForward(cursor, 32);
    layout.binding_table_offset = @intCast(cursor);
    cursor += layout.surface_count * @sizeOf(u32);

    cursor = alignForward(cursor, @alignOf(u32));
    layout.size_table_offset = @intCast(cursor);
    cursor += size_table_size;

    cursor = alignForward(cursor, 64);
    layout.interface_descriptor_offset = @intCast(cursor);
    cursor += interface_descriptor_size;
    layout.size = alignForward(cursor, page_size);
    if (layout.size > destination.len or layout.size > page_size)
        return Error.StateTooLarge;

    @memset(destination[0..layout.size], 0);
    @memcpy(destination[layout.kernel_offset .. layout.kernel_offset + kernel.len], kernel);

    for (buffer_sizes, 0..) |size, index| {
        _ = try encodeRawBufferSurface(destination, layout.surface_offsets[index], size);
        putU32(destination, layout.binding_table_offset + @as(u32, @intCast(index * @sizeOf(u32))), layout.surface_offsets[index]);
        putU32(destination, layout.size_table_offset + @as(u32, @intCast(index * @sizeOf(u32))), @intCast(size));
    }
    for (group_count, 0..) |count, component| {
        putU32(destination, layout.size_table_offset + num_workgroups_offset + @as(u32, @intCast(component * @sizeOf(u32))), count);
    }
    _ = try encodeRawBufferSurface(destination, layout.surface_offsets[size_table_surface], size_table_size);
    putU32(destination, layout.binding_table_offset + @as(u32, @intCast(size_table_surface * @sizeOf(u32))), layout.surface_offsets[size_table_surface]);

    const idd = layout.interface_descriptor_offset;
    putU32(destination, idd + 0, layout.kernel_offset);
    putU32(destination, idd + 4, 0);
    putU32(destination, idd + 4 * @sizeOf(u32), @as(u32, layout.surface_count) | layout.binding_table_offset);
    putU32(destination, idd + 6 * @sizeOf(u32), 1);

    return layout;
}

fn encodeRawBufferSurface(destination: []u8, offset: u32, byte_size: u64) Error!void {
    if (byte_size == 0)
        return Error.EmptyBuffer;

    const aligned_size = std.mem.alignForward(u64, byte_size, 4);
    const padded_size = aligned_size + (aligned_size - byte_size);
    if (padded_size == 0 or padded_size > (@as(u64, 1) << 32))
        return Error.UnsupportedBufferSize;
    const length_minus_one: u32 = @intCast(padded_size - 1);

    putU32(destination, offset + 0, (4 << 29) |
        (raw_surface_format << 18) |
        (1 << 16) |
        (1 << 14));
    putU32(destination, offset + 1 * @sizeOf(u32), mocs << 24);
    putU32(destination, offset + 2 * @sizeOf(u32), (length_minus_one & 0x7f) |
        (((length_minus_one >> 7) & 0x3fff) << 16));
    putU32(destination, offset + 3 * @sizeOf(u32), ((length_minus_one >> 21) & 0x7ff) << 21);
}

pub const ccStatePointers = [_]u32{
    0x780e0000,
    0,
};

pub const pipelineSelectGpgpu = [_]u32{0x69040302};

pub fn pipeControl(bits: u32) [6]u32 {
    return .{ 0x7a000004, bits, 0, 0, 0, 0 };
}

pub const pipe_control = struct {
    pub const state_invalidate: u32 = 1 << 2;
    pub const constant_invalidate: u32 = 1 << 3;
    pub const dc_flush: u32 = 1 << 5;
    pub const texture_invalidate: u32 = 1 << 10;
    pub const instruction_invalidate: u32 = 1 << 11;
    pub const render_target_flush: u32 = 1 << 12;
    pub const depth_flush: u32 = 1 << 0;
    pub const cs_stall: u32 = 1 << 20;
};

pub fn stateBaseAddress() [19]u32 {
    var words: [19]u32 = @splat(0);
    words[0] = 0x61010011;
    words[3] = mocs << 16;
    words[4] = base_address_delta;
    words[6] = base_address_delta;
    words[10] = base_address_delta;
    words[13] = (1 << 12) | 1;
    words[15] = (1 << 12) | 1;
    return words;
}

pub fn mediaVfeState() [9]u32 {
    var words: [9]u32 = @splat(0);
    words[0] = 0x70000007;
    words[3] = (1 << 16) | (2 << 8);
    words[5] = 2 << 16;
    return words;
}

pub fn interfaceDescriptorLoad(offset: u32) [4]u32 {
    return .{ 0x70020002, 0, interface_descriptor_size, offset };
}

pub fn gpgpuWalker(group_count: [3]u32, right_mask: u32) [15]u32 {
    var words: [15]u32 = @splat(0);
    words[0] = 0x7105000d;
    words[7] = group_count[0];
    words[10] = group_count[1];
    words[12] = group_count[2];
    words[13] = right_mask;
    words[14] = 0xffffffff;
    return words;
}

pub const mediaStateFlush = [_]u32{ 0x70040000, 0 };

fn alignForward(value: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, value, alignment);
}

fn putU32(destination: []u8, offset: u32, value: u32) void {
    std.mem.writeInt(u32, destination[offset..][0..@sizeOf(u32)], value, .little);
}

test "[gen9] dispatch: fixed size-table ABI includes workgroup counts" {
    const buffer_sizes = [_]u64{ 4096, 8192, 16384, 32768 };
    const group_count: [3]u32 = .{ 7, 11, 13 };
    try std.testing.expectEqual(@as(u32, 16), num_workgroups_offset);
    try std.testing.expectEqual(@as(u32, 28), size_table_size);

    for (0..max_storage_surfaces + 1) |buffer_count| {
        var state: [page_size]u8 = undefined;
        const layout = try writeState(&state, &.{ 0xaa, 0xbb }, buffer_sizes[0..buffer_count], group_count);
        for (0..max_storage_surfaces) |index| {
            const actual = std.mem.readInt(u32, state[layout.size_table_offset + index * @sizeOf(u32) ..][0..4], .little);
            const expected: u32 = if (index < buffer_count) @intCast(buffer_sizes[index]) else 0;
            try std.testing.expectEqual(expected, actual);
        }
        for (group_count, 0..) |expected, component| {
            const actual = std.mem.readInt(u32, state[layout.size_table_offset + num_workgroups_offset + component * @sizeOf(u32) ..][0..4], .little);
            try std.testing.expectEqual(expected, actual);
        }
        const surface_offset = layout.surface_offsets[buffer_count];
        try std.testing.expectEqual(@as(u32, 27), std.mem.readInt(u32, state[surface_offset + 8 ..][0..4], .little));
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, state[surface_offset + 12 ..][0..4], .little));
        try std.testing.expect(layout.size_table_offset + size_table_size <= layout.interface_descriptor_offset);
    }
}

test "[gen9] dispatch: walker preserves multidimensional group counts with one active lane" {
    const words = gpgpuWalker(.{ 7, 11, 13 }, 1);
    try std.testing.expectEqual(@as(u32, 7), words[7]);
    try std.testing.expectEqual(@as(u32, 11), words[10]);
    try std.testing.expectEqual(@as(u32, 13), words[12]);
    try std.testing.expectEqual(@as(u32, 1), words[13]);
    try std.testing.expectEqual(@as(u32, 0), words[4]);
    for ([_]usize{ 5, 8, 11 }) |index|
        try std.testing.expectEqual(@as(u32, 0), words[index]);
}

test "[gen9] dispatch: interface descriptor exposes internal size-table surface" {
    var state: [page_size]u8 = undefined;
    const layout = try writeState(&state, &.{ 0xaa, 0xbb }, &.{ 4096, 8192 }, .{ 1, 1, 1 });

    try std.testing.expectEqual(@as(u8, 3), layout.surface_count);

    const descriptor_binding_table = std.mem.readInt(
        u32,
        state[layout.interface_descriptor_offset + 4 * @sizeOf(u32) ..][0..@sizeOf(u32)],
        .little,
    );
    try std.testing.expectEqual(layout.binding_table_offset | @as(u32, layout.surface_count), descriptor_binding_table);

    for (0..layout.surface_count) |index| {
        const entry = std.mem.readInt(
            u32,
            state[layout.binding_table_offset + index * @sizeOf(u32) ..][0..@sizeOf(u32)],
            .little,
        );
        try std.testing.expectEqual(layout.surface_offsets[index], entry);
    }
}
