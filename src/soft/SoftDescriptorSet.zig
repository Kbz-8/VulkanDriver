const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const Device = base.Device;
const Buffer = base.Buffer;

const SoftBuffer = @import("SoftBuffer.zig");

const NonDispatchable = base.NonDispatchable;

const Self = @This();
pub const Interface = base.DescriptorSet;

const DescriptorBuffer = struct {
    object: ?*SoftBuffer,
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
};

const Descriptor = union(enum) {
    buffer: []DescriptorBuffer,
    image: struct {},
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
                .storage_buffer, .storage_buffer_dynamic => @sizeOf(DescriptorBuffer),
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
            .storage_buffer, .storage_buffer_dynamic => descriptor.* = .{
                .buffer = local_allocator.alloc(DescriptorBuffer, binding.array_size) catch return VkError.OutOfHostMemory,
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

pub fn copy(interface: *Interface, copy_data: vk.CopyDescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = copy_data;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.free(self.heap);
    allocator.destroy(self);
}

pub fn write(interface: *Interface, write_data: vk.WriteDescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    switch (write_data.descriptor_type) {
        .storage_buffer, .storage_buffer_dynamic => {
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
        else => {
            self.descriptors[write_data.dst_binding] = .{ .unsupported = .{} };
            base.unsupported("descriptor type {s} for writting", .{@tagName(write_data.descriptor_type)});
        },
    }
}
