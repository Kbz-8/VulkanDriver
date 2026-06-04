const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const Device = base.Device;
const Buffer = base.Buffer;
const BufferView = base.BufferView;
const ImageView = base.ImageView;
const Sampler = base.Sampler;

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

const DescriptorSampler = struct {
    object: ?*SoftSampler,
};

const DescriptorTexel = struct {
    object: ?*SoftBufferView,
};

const Descriptor = union(enum) {
    buffer: []DescriptorBuffer,
    texture: []DescriptorTexture,
    image: []DescriptorImage,
    sampler: []DescriptorSampler,
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
                .uniform_buffer_dynamic,
                .storage_buffer,
                .storage_buffer_dynamic,
                => @sizeOf(DescriptorBuffer),

                .sampled_image,
                .storage_image,
                .input_attachment,
                => @sizeOf(DescriptorImage),

                .sampler,
                => @sizeOf(DescriptorSampler),

                .storage_texel_buffer,
                .uniform_texel_buffer,
                => @sizeOf(DescriptorTexel),

                .combined_image_sampler,
                => @sizeOf(DescriptorTexture),

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
            .uniform_buffer_dynamic,
            .storage_buffer,
            .storage_buffer_dynamic,
            => descriptor.* = blk: {
                const desc: Descriptor = .{
                    .buffer = local_allocator.alloc(DescriptorBuffer, binding.array_size) catch return VkError.OutOfHostMemory,
                };
                for (desc.buffer[0..]) |*d| {
                    d.* = .{
                        .object = null,
                        .offset = 0,
                        .size = 0,
                    };
                }
                break :blk desc;
            },

            .sampled_image,
            .storage_image,
            .input_attachment,
            => descriptor.* = blk: {
                const desc: Descriptor = .{
                    .image = local_allocator.alloc(DescriptorImage, binding.array_size) catch return VkError.OutOfHostMemory,
                };
                for (desc.image[0..]) |*d| {
                    d.* = .{ .object = null };
                }
                break :blk desc;
            },

            .sampler,
            => descriptor.* = blk: {
                const desc: Descriptor = .{
                    .sampler = local_allocator.alloc(DescriptorSampler, binding.array_size) catch return VkError.OutOfHostMemory,
                };
                for (desc.sampler[0..], 0..) |*d, i| {
                    d.* = .{
                        .object = if (i < binding.immutable_samplers.len)
                            @as(*SoftSampler, @alignCast(@fieldParentPtr("interface", @constCast(binding.immutable_samplers[i]))))
                        else
                            null,
                    };
                }
                break :blk desc;
            },

            .storage_texel_buffer,
            .uniform_texel_buffer,
            => descriptor.* = blk: {
                const desc: Descriptor = .{
                    .texel_buffer = local_allocator.alloc(DescriptorTexel, binding.array_size) catch return VkError.OutOfHostMemory,
                };
                for (desc.texel_buffer[0..]) |*d| {
                    d.* = .{ .object = null };
                }
                break :blk desc;
            },

            .combined_image_sampler,
            => descriptor.* = blk: {
                const desc: Descriptor = .{
                    .texture = local_allocator.alloc(DescriptorTexture, binding.array_size) catch return VkError.OutOfHostMemory,
                };
                for (desc.texture[0..], 0..) |*d, i| {
                    d.* = .{
                        .sampler = if (i < binding.immutable_samplers.len)
                            @as(*SoftSampler, @alignCast(@fieldParentPtr("interface", @constCast(binding.immutable_samplers[i]))))
                        else
                            null,
                        .view = null,
                    };
                }
                break :blk desc;
            },

            else => descriptor.* = .{ .unsupported = .{} },
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

fn descriptorLen(descriptor: Descriptor) usize {
    return switch (descriptor) {
        .buffer => |buffer| buffer.len,
        .image => |image| image.len,
        .sampler => |sampler| sampler.len,
        .texel_buffer => |texel_buffer| texel_buffer.len,
        .texture => |texture| texture.len,
        .unsupported => 0,
    };
}

fn advanceToAvailableDescriptor(descriptors: []const Descriptor, binding: *usize, array_element: *usize) bool {
    while (binding.* < descriptors.len) {
        switch (descriptors[binding.*]) {
            .unsupported => return true,
            else => {},
        }

        const len = descriptorLen(descriptors[binding.*]);
        if (array_element.* < len) return true;
        if (array_element.* > len) return false;

        binding.* += 1;
        array_element.* = 0;
    }

    return false;
}

fn copyDescriptorRange(dst_desc: *Descriptor, dst_array_element: usize, src_desc: Descriptor, src_array_element: usize, descriptor_count: usize) bool {
    switch (dst_desc.*) {
        .buffer => |dst_buffer| {
            const src_buffer = switch (src_desc) {
                .buffer => |buffer| buffer,
                else => return false,
            };
            @memcpy(
                dst_buffer[dst_array_element .. dst_array_element + descriptor_count],
                src_buffer[src_array_element .. src_array_element + descriptor_count],
            );
        },

        .image => |dst_image| {
            const src_image = switch (src_desc) {
                .image => |image| image,
                else => return false,
            };
            @memcpy(
                dst_image[dst_array_element .. dst_array_element + descriptor_count],
                src_image[src_array_element .. src_array_element + descriptor_count],
            );
        },

        .sampler => |dst_sampler| {
            const src_sampler = switch (src_desc) {
                .sampler => |sampler| sampler,
                else => return false,
            };
            @memcpy(
                dst_sampler[dst_array_element .. dst_array_element + descriptor_count],
                src_sampler[src_array_element .. src_array_element + descriptor_count],
            );
        },

        .texel_buffer => |dst_texel_buffer| {
            const src_texel_buffer = switch (src_desc) {
                .texel_buffer => |texel_buffer| texel_buffer,
                else => return false,
            };
            @memcpy(
                dst_texel_buffer[dst_array_element .. dst_array_element + descriptor_count],
                src_texel_buffer[src_array_element .. src_array_element + descriptor_count],
            );
        },

        .texture => |dst_texture| {
            const src_texture = switch (src_desc) {
                .texture => |texture| texture,
                else => return false,
            };
            @memcpy(
                dst_texture[dst_array_element .. dst_array_element + descriptor_count],
                src_texture[src_array_element .. src_array_element + descriptor_count],
            );
        },

        .unsupported => return false,
    }

    return true;
}

fn copyDescriptorRangePreservingImmutableSamplers(self: *Self, dst_binding: usize, dst_desc: *Descriptor, dst_array_element: usize, src_desc: Descriptor, src_array_element: usize, descriptor_count: usize) bool {
    const immutable_samplers = self.interface.layout.bindings[dst_binding].immutable_samplers;
    if (immutable_samplers.len == 0) {
        return copyDescriptorRange(dst_desc, dst_array_element, src_desc, src_array_element, descriptor_count);
    }

    const dst_texture = switch (dst_desc.*) {
        .texture => |texture| texture,
        else => return copyDescriptorRange(dst_desc, dst_array_element, src_desc, src_array_element, descriptor_count),
    };
    const src_texture = switch (src_desc) {
        .texture => |texture| texture,
        else => return false,
    };

    for (0..descriptor_count) |i| {
        const dst_index = dst_array_element + i;
        const src_index = src_array_element + i;
        dst_texture[dst_index].view = src_texture[src_index].view;
        if (dst_index < immutable_samplers.len) {
            dst_texture[dst_index].sampler = @as(*SoftSampler, @alignCast(@fieldParentPtr("interface", @constCast(immutable_samplers[dst_index]))));
        }
    }

    return true;
}

pub fn copy(interface: *Interface, src_interface: *const Interface, data: vk.CopyDescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const src: *const Self = @alignCast(@fieldParentPtr("interface", src_interface));

    var dst_binding: usize = @intCast(data.dst_binding);
    var src_binding: usize = @intCast(data.src_binding);
    var dst_array_element: usize = @intCast(data.dst_array_element);
    var src_array_element: usize = @intCast(data.src_array_element);
    var descriptor_count: usize = @intCast(data.descriptor_count);

    while (descriptor_count > 0) {
        if (!advanceToAvailableDescriptor(self.descriptors, &dst_binding, &dst_array_element) or
            !advanceToAvailableDescriptor(src.descriptors, &src_binding, &src_array_element))
        {
            return;
        }

        const dst_desc = &self.descriptors[dst_binding];
        const src_desc = src.descriptors[src_binding];
        const dst_len = descriptorLen(dst_desc.*);
        const src_len = descriptorLen(src_desc);
        if (dst_len == 0 or src_len == 0) {
            base.unsupported("descriptor type for copy", .{});
            return;
        }

        const dst_remaining = dst_len - dst_array_element;
        const src_remaining = src_len - src_array_element;
        const copy_count = @min(descriptor_count, dst_remaining, src_remaining);

        if (!self.copyDescriptorRangePreservingImmutableSamplers(dst_binding, dst_desc, dst_array_element, src_desc, src_array_element, copy_count)) {
            base.unsupported("descriptor type for copy", .{});
            return;
        }

        descriptor_count -= copy_count;
        dst_array_element += copy_count;
        src_array_element += copy_count;
    }
}

pub fn write(interface: *Interface, write_data: vk.WriteDescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    switch (write_data.descriptor_type) {
        .uniform_buffer,
        .uniform_buffer_dynamic,
        .storage_buffer,
        .storage_buffer_dynamic,
        => {
            for (write_data.p_buffer_info, 0..write_data.descriptor_count) |buffer_info, i| {
                const desc = &self.descriptors[write_data.dst_binding].buffer[write_data.dst_array_element + i];
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

        .sampled_image,
        .storage_image,
        .input_attachment,
        => {
            for (write_data.p_image_info, 0..write_data.descriptor_count) |image_info, i| {
                const desc = &self.descriptors[write_data.dst_binding].image[write_data.dst_array_element + i];
                desc.* = .{ .object = null };
                if (image_info.image_view != .null_handle) {
                    const image_view = try NonDispatchable(ImageView).fromHandleObject(image_info.image_view);
                    desc.object = @as(*SoftImageView, @alignCast(@fieldParentPtr("interface", image_view)));
                }
            }
        },

        .sampler,
        => {
            for (write_data.p_image_info, 0..write_data.descriptor_count) |image_info, i| {
                const desc = &self.descriptors[write_data.dst_binding].sampler[write_data.dst_array_element + i];
                const immutable_samplers = self.interface.layout.bindings[write_data.dst_binding].immutable_samplers;
                const array_element = write_data.dst_array_element + i;
                desc.* = .{
                    .object = if (array_element < immutable_samplers.len)
                        @as(*SoftSampler, @alignCast(@fieldParentPtr("interface", @constCast(immutable_samplers[array_element]))))
                    else
                        null,
                };
                if (immutable_samplers.len == 0 and image_info.sampler != .null_handle) {
                    const sampler = try NonDispatchable(Sampler).fromHandleObject(image_info.sampler);
                    desc.object = @as(*SoftSampler, @alignCast(@fieldParentPtr("interface", sampler)));
                }
            }
        },

        .storage_texel_buffer,
        .uniform_texel_buffer,
        => {
            for (write_data.p_texel_buffer_view, 0..write_data.descriptor_count) |view, i| {
                const desc = &self.descriptors[write_data.dst_binding].texel_buffer[write_data.dst_array_element + i];
                desc.* = .{ .object = null };
                if (view != .null_handle) {
                    const buffer_view = try NonDispatchable(BufferView).fromHandleObject(view);
                    desc.object = @as(*SoftBufferView, @alignCast(@fieldParentPtr("interface", buffer_view)));
                }
            }
        },

        .combined_image_sampler,
        => {
            for (write_data.p_image_info, 0..write_data.descriptor_count) |image_info, i| {
                const desc = &self.descriptors[write_data.dst_binding].texture[write_data.dst_array_element + i];
                const immutable_samplers = self.interface.layout.bindings[write_data.dst_binding].immutable_samplers;
                const array_element = write_data.dst_array_element + i;
                desc.* = .{
                    .sampler = if (array_element < immutable_samplers.len)
                        @as(*SoftSampler, @alignCast(@fieldParentPtr("interface", @constCast(immutable_samplers[array_element]))))
                    else
                        null,
                    .view = null,
                };
                if (image_info.image_view != .null_handle) {
                    const image_view = try NonDispatchable(ImageView).fromHandleObject(image_info.image_view);
                    desc.view = @as(*SoftImageView, @alignCast(@fieldParentPtr("interface", image_view)));
                }
                if (immutable_samplers.len == 0 and image_info.sampler != .null_handle) {
                    const sampler = try NonDispatchable(Sampler).fromHandleObject(image_info.sampler);
                    desc.sampler = @as(*SoftSampler, @alignCast(@fieldParentPtr("interface", sampler)));
                }
            }
        },

        else => {
            self.descriptors[write_data.dst_binding] = .{ .unsupported = .{} };
            base.unsupported("descriptor type {s} for writting", .{@tagName(write_data.descriptor_type)});
        },
    }
}
