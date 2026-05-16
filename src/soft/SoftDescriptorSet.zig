const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const Device = base.Device;
const Buffer = base.Buffer;
const BufferView = base.BufferView;
const ImageView = base.ImageView;

const SoftBuffer = @import("SoftBuffer.zig");
const SoftBufferView = @import("SoftBufferView.zig");
const SoftImageView = @import("SoftImageView.zig");
const SoftSampler = @import("SoftSampler.zig");

const NonDispatchable = base.NonDispatchable;

const Self = @This();
pub const Interface = base.DescriptorSet;

const DescriptorBuffer = struct {
    object: ?*SoftBuffer,
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
};

const DescriptorTexture = struct {
    sampler: ?*SoftSampler,
    view: ?*SoftImageView,
};

const DescriptorImage = struct {
    object: ?*SoftImageView,
};

const DescriptorTexel = struct {
    object: ?*SoftBufferView,
};

const Descriptor = union(enum) {
    buffer: []DescriptorBuffer,
    texture: []DescriptorTexture,
    image: []DescriptorImage,
    texel_buffer: []DescriptorTexel,
    unsupported: struct {},
};

interface: Interface,

/// Memory containing actual binding descriptors and their array
heap: []u8,

descriptors: []Descriptor,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, layout: *base.DescriptorSetLayout) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, layout);

    interface.vtable = &.{
        .copy = copy,
        .destroy = destroy,
        .write = write,
    };

    const heap_size = blk: {
        var size: usize = layout.bindings.len * @sizeOf(Descriptor);
        for (layout.bindings) |binding| {
            const struct_size: usize = switch (binding.descriptor_type) {
                .uniform_buffer,
                .storage_buffer,
                .storage_buffer_dynamic,
                => @sizeOf(DescriptorBuffer),
                .storage_image,
                .input_attachment,
                => @sizeOf(DescriptorImage),
                .storage_texel_buffer,
                .uniform_texel_buffer,
                => @sizeOf(DescriptorTexel),
                else => 0,
            };

            size += binding.array_size * struct_size;
        }
        break :blk size;
    };

    const heap = allocator.alloc(u8, heap_size) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(heap);

    var local_heap = std.heap.FixedBufferAllocator.init(heap);
    const local_allocator = local_heap.allocator();

    const descriptors = local_allocator.alloc(Descriptor, layout.bindings.len) catch return VkError.OutOfHostMemory;
    for (descriptors, layout.bindings) |*descriptor, binding| {
        switch (binding.descriptor_type) {
            .uniform_buffer,
            .storage_buffer,
            .storage_buffer_dynamic,
            => descriptor.* = .{
                .buffer = local_allocator.alloc(DescriptorBuffer, binding.array_size) catch return VkError.OutOfHostMemory,
            },
            .storage_image,
            .input_attachment,
            => descriptor.* = .{
                .image = local_allocator.alloc(DescriptorImage, binding.array_size) catch return VkError.OutOfHostMemory,
            },
            .storage_texel_buffer,
            .uniform_texel_buffer,
            => descriptor.* = .{
                .texel_buffer = local_allocator.alloc(DescriptorTexel, binding.array_size) catch return VkError.OutOfHostMemory,
            },
            else => {},
        }
    }

    self.* = .{
        .interface = interface,
        .heap = heap,
        .descriptors = descriptors,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.free(self.heap);
    allocator.destroy(self);
}

pub fn copy(interface: *Interface, src_interface: *const Interface, data: vk.CopyDescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const src: *const Self = @alignCast(@fieldParentPtr("interface", src_interface));

    const dst_start = @min(@as(usize, @intCast(data.dst_binding)), self.descriptors.len);
    const src_start = @min(@as(usize, @intCast(data.src_binding)), src.descriptors.len);

    const descriptor_count: usize = @intCast(data.descriptor_count);

    const dst_remaining = self.descriptors.len - dst_start;
    const src_remaining = src.descriptors.len - src_start;

    const copy_count = @min(descriptor_count, dst_remaining, src_remaining);

    const dst_slice = self.descriptors[dst_start .. dst_start + copy_count];
    const src_slice = src.descriptors[src_start .. src_start + copy_count];

    for (dst_slice, src_slice) |*dst_desc, src_desc| {
        switch (dst_desc.*) {
            .buffer => |dst_buffer| @memcpy(dst_buffer[0..], src_desc.buffer[0..]),
            .image => |dst_image| @memcpy(dst_image[0..], src_desc.image[0..]),
            .texel_buffer => |dst_texel| @memcpy(dst_texel[0..], src_desc.texel_buffer[0..]),
            else => {
                dst_desc.* = .{ .unsupported = .{} };
                base.unsupported("descriptor type for copy", .{});
            },
        }
    }
}

pub fn write(interface: *Interface, write_data: vk.WriteDescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    switch (write_data.descriptor_type) {
        .uniform_buffer,
        .storage_buffer,
        .storage_buffer_dynamic,
        => {
            for (write_data.p_buffer_info, 0..write_data.descriptor_count) |buffer_info, i| {
                const desc = &self.descriptors[write_data.dst_binding].buffer[i];
                desc.* = .{
                    .object = null,
                    .offset = buffer_info.offset,
                    .size = buffer_info.range,
                };
                if (buffer_info.buffer != .null_handle) {
                    const buffer = try NonDispatchable(Buffer).fromHandleObject(buffer_info.buffer);
                    desc.object = @as(*SoftBuffer, @alignCast(@fieldParentPtr("interface", buffer)));
                    if (desc.size == vk.WHOLE_SIZE) {
                        desc.size = if (buffer.memory) |memory| memory.size - desc.offset else return VkError.InvalidDeviceMemoryDrv;
                    }
                }
            }
        },
        .storage_image,
        .input_attachment,
        => {
            for (write_data.p_image_info, 0..write_data.descriptor_count) |image_info, i| {
                const desc = &self.descriptors[write_data.dst_binding].image[i];
                desc.* = .{ .object = null };
                if (image_info.image_view != .null_handle) {
                    const image_view = try NonDispatchable(ImageView).fromHandleObject(image_info.image_view);
                    desc.object = @as(*SoftImageView, @alignCast(@fieldParentPtr("interface", image_view)));
                }
            }
        },
        .storage_texel_buffer,
        .uniform_texel_buffer,
        => {
            for (write_data.p_texel_buffer_view, 0..write_data.descriptor_count) |view, i| {
                const desc = &self.descriptors[write_data.dst_binding].texel_buffer[i];
                desc.* = .{ .object = null };
                if (view != .null_handle) {
                    const buffer_view = try NonDispatchable(BufferView).fromHandleObject(view);
                    desc.object = @as(*SoftBufferView, @alignCast(@fieldParentPtr("interface", buffer_view)));
                }
            }
        },
        else => {
            self.descriptors[write_data.dst_binding] = .{ .unsupported = .{} };
            base.unsupported("descriptor type {s} for writting", .{@tagName(write_data.descriptor_type)});
        },
    }
}
