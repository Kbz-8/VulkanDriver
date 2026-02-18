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

const Descriptor = union(enum) {
    buffer: struct {
        object: ?*SoftBuffer,
        offset: vk.DeviceSize,
        size: vk.DeviceSize,
    },
    image: struct {},
};

interface: Interface,

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

    const descriptors = allocator.alloc(Descriptor, layout.bindings.len) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(descriptors);

    self.* = .{
        .interface = interface,
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
    allocator.free(self.descriptors);
    allocator.destroy(self);
}

pub fn write(interface: *Interface, write_data: vk.WriteDescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    switch (write_data.descriptor_type) {
        .storage_buffer, .storage_buffer_dynamic => {
            for (write_data.p_buffer_info, 0..write_data.descriptor_count) |buffer_info, i| {
                const desc = &self.descriptors[write_data.dst_binding + i];
                desc.* = .{
                    .buffer = .{
                        .object = null,
                        .offset = buffer_info.offset,
                        .size = buffer_info.range,
                    },
                };
                if (buffer_info.buffer != .null_handle) {
                    const buffer = try NonDispatchable(Buffer).fromHandleObject(buffer_info.buffer);
                    desc.buffer.object = @as(*SoftBuffer, @alignCast(@fieldParentPtr("interface", buffer)));
                }
            }
        },
        else => base.unsupported("descriptor type {s} for writting", .{@tagName(write_data.descriptor_type)}),
    }
}
