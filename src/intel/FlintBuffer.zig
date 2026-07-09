const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const lib = @import("lib.zig");

const VkError = base.VkError;
const Device = base.Device;

const Self = @This();
pub const Interface = base.Buffer;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);
    interface.allowed_memory_types = std.bit_set.IntegerBitSet(32).initEmpty();
    interface.allowed_memory_types.set(0);

    interface.vtable = &.{
        .destroy = destroy,
        .getMemoryRequirements = getMemoryRequirements,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn getMemoryRequirements(interface: *Interface, requirements: *vk.MemoryRequirements) void {
    requirements.alignment = 16;
    if (interface.usage.uniform_texel_buffer_bit or interface.usage.storage_texel_buffer_bit) {
        requirements.alignment = @max(requirements.alignment, interface.owner.physical_device.props.limits.min_texel_buffer_offset_alignment);
    }
    if (interface.usage.storage_buffer_bit) {
        requirements.alignment = @max(requirements.alignment, interface.owner.physical_device.props.limits.min_storage_buffer_offset_alignment);
    }
    if (interface.usage.uniform_buffer_bit) {
        requirements.alignment = @max(requirements.alignment, interface.owner.physical_device.props.limits.min_uniform_buffer_offset_alignment);
    }
}
