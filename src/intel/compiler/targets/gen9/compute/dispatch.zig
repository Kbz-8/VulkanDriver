const std = @import("std");

pub const max_surfaces: usize = 4;
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
    binding_table_offset: u32,
    interface_descriptor_offset: u32,
};

pub fn writeState(destination: []u8, kernel: []const u8, buffer_sizes: []const u64) Error!StateLayout {
    if (buffer_sizes.len > max_surfaces)
        return Error.TooManySurfaces;

    var layout: StateLayout = .{
        .size = 0,
        .kernel_offset = 0,
        .surface_offsets = @splat(0),
        .surface_address_offsets = @splat(0),
        .surface_count = @intCast(buffer_sizes.len),
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
    }

    cursor = alignForward(cursor, 32);
    layout.binding_table_offset = @intCast(cursor);
    cursor += buffer_sizes.len * @sizeOf(u32);

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
    }

    const idd = layout.interface_descriptor_offset;
    putU32(destination, idd + 0, layout.kernel_offset);
    putU32(destination, idd + 4, 0);
    putU32(destination, idd + 4 * @sizeOf(u32), @as(u32, @intCast(buffer_sizes.len)) | layout.binding_table_offset);
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
