const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const FlintDeviceMemory = @import("FlintDeviceMemory.zig");

const Self = @This();

memory: *FlintDeviceMemory,
offset: vk.DeviceSize,
size: vk.DeviceSize,

pub fn fromBuffer(buffer: *base.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!Self {
    const base_memory = buffer.memory orelse return VkError.InvalidDeviceMemoryDrv;
    const bound, const bound_overflow = @addWithOverflow(offset, size);
    if (bound_overflow != 0 or bound > buffer.size) return VkError.ValidationFailed;

    const memory_offset, const memory_offset_overflow = @addWithOverflow(buffer.offset, offset);
    if (memory_offset_overflow != 0) return VkError.ValidationFailed;

    return fromMemory(base_memory, memory_offset, size);
}

pub fn fromImage(image: *base.Image, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!Self {
    const base_memory = image.memory orelse return VkError.InvalidDeviceMemoryDrv;
    const memory_offset, const memory_offset_overflow = @addWithOverflow(image.memory_offset, offset);
    if (memory_offset_overflow != 0) return VkError.ValidationFailed;

    return fromMemory(base_memory, memory_offset, size);
}

pub fn fromMemory(base_memory: *base.DeviceMemory, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!Self {
    const memory: *FlintDeviceMemory = @alignCast(@fieldParentPtr("interface", base_memory));
    if (offset > base_memory.size or size > base_memory.size - offset)
        return VkError.ValidationFailed;

    return .{
        .memory = memory,
        .offset = offset,
        .size = size,
    };
}
