const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const NonDispatchable = base.NonDispatchable;

const Self = @This();
pub const Interface = base.DescriptorSet;

pub const DescriptorBuffer = struct {
    buffer: ?*base.Buffer,
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
};

const Descriptor = union(enum) {
    buffer: []DescriptorBuffer,
    unsupported,
};

interface: Interface,
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

    var heap_size = layout.bindings.len * @sizeOf(Descriptor);
    for (layout.bindings) |binding| {
        heap_size += switch (binding.descriptor_type) {
            .uniform_buffer,
            .uniform_buffer_dynamic,
            .storage_buffer,
            .storage_buffer_dynamic,
            => binding.array_size * @sizeOf(DescriptorBuffer),

            else => 0,
        };
    }

    const heap = allocator.alloc(u8, heap_size) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(heap);

    var fixed = std.heap.FixedBufferAllocator.init(heap);
    const descriptors = fixed.allocator().alloc(Descriptor, layout.bindings.len) catch return VkError.OutOfHostMemory;
    for (descriptors, layout.bindings) |*descriptor, binding| {
        descriptor.* = switch (binding.descriptor_type) {
            .uniform_buffer, .uniform_buffer_dynamic, .storage_buffer, .storage_buffer_dynamic => blk: {
                const buffers = fixed.allocator().alloc(DescriptorBuffer, binding.array_size) catch return VkError.OutOfHostMemory;

                for (buffers) |*buffer| {
                    buffer.* = .{
                        .buffer = null,
                        .offset = 0,
                        .size = 0,
                    };
                }

                break :blk .{ .buffer = buffers };
            },
            else => .unsupported,
        };
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

    if (data.dst_binding >= self.descriptors.len or data.src_binding >= src.descriptors.len)
        return VkError.ValidationFailed;

    const dst = switch (self.descriptors[data.dst_binding]) {
        .buffer => |buffers| buffers,
        .unsupported => return VkError.FeatureNotPresent,
    };

    const source = switch (src.descriptors[data.src_binding]) {
        .buffer => |buffers| buffers,
        .unsupported => return VkError.FeatureNotPresent,
    };

    const dst_start: usize = @intCast(data.dst_array_element);
    const src_start: usize = @intCast(data.src_array_element);
    const count: usize = @intCast(data.descriptor_count);

    if (dst_start > dst.len or count > dst.len - dst_start)
        return VkError.ValidationFailed;
    if (src_start > source.len or count > source.len - src_start)
        return VkError.ValidationFailed;

    @memcpy(dst[dst_start .. dst_start + count], source[src_start .. src_start + count]);
}

pub fn write(interface: *Interface, write_data: vk.WriteDescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    switch (write_data.descriptor_type) {
        .uniform_buffer,
        .uniform_buffer_dynamic,
        .storage_buffer,
        .storage_buffer_dynamic,
        => {
            if (write_data.dst_binding >= self.descriptors.len)
                return VkError.ValidationFailed;

            const descriptors = switch (self.descriptors[write_data.dst_binding]) {
                .buffer => |buffers| buffers,
                .unsupported => return VkError.FeatureNotPresent,
            };

            const start: usize = @intCast(write_data.dst_array_element);
            const count: usize = @intCast(write_data.descriptor_count);

            if (start > descriptors.len or count > descriptors.len - start)
                return VkError.ValidationFailed;

            for (write_data.p_buffer_info, 0..write_data.descriptor_count) |buffer_info, index| {
                const descriptor = &descriptors[start + index];
                descriptor.* = .{ .buffer = null, .offset = buffer_info.offset, .size = buffer_info.range };

                if (buffer_info.buffer == .null_handle)
                    continue;

                const buffer = try NonDispatchable(base.Buffer).fromHandleObject(buffer_info.buffer);

                if (descriptor.offset > buffer.size)
                    return VkError.ValidationFailed;
                if (descriptor.size == vk.WHOLE_SIZE)
                    descriptor.size = buffer.size - descriptor.offset;
                if (descriptor.size > buffer.size - descriptor.offset)
                    return VkError.ValidationFailed;

                descriptor.buffer = buffer;
            }
        },

        else => return VkError.FeatureNotPresent,
    }
}

pub fn getBuffer(self: *const Self, binding: u32, array_element: u32) VkError!DescriptorBuffer {
    if (binding >= self.descriptors.len) return VkError.ValidationFailed;
    const buffers = switch (self.descriptors[binding]) {
        .buffer => |items| items,
        .unsupported => return VkError.FeatureNotPresent,
    };
    if (array_element >= buffers.len) return VkError.ValidationFailed;
    return buffers[array_element];
}
