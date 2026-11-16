const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");
const DescriptorSet = @import("DescriptorSet.zig");
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_update_template;

const Entry = struct {
    binding: u32,
    array_element: u32,
    descriptor_type: vk.DescriptorType,
    offset: usize,
};

owner: *Device,
entries: []Entry,

pub fn create(device: *Device, allocator: std.mem.Allocator, info: *const vk.DescriptorUpdateTemplateCreateInfo) VkError!*Self {
    if (info.template_type != .descriptor_set)
        return VkError.FeatureNotPresent;

    const layout = try NonDispatchable(DescriptorSetLayout).fromHandleObject(info.descriptor_set_layout);
    if (layout.owner != device)
        return VkError.InvalidHandleDrv;

    const source_entries = info.p_descriptor_update_entries[0..info.descriptor_update_entry_count];
    var count: usize = 0;
    for (source_entries) |entry| {
        count = std.math.add(usize, count, entry.descriptor_count) catch return VkError.ValidationFailed;
    }

    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    const entries = allocator.alloc(Entry, count) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(entries);

    var index: usize = 0;
    for (source_entries) |entry| {
        const data_size: usize = switch (entry.descriptor_type) {
            .sampler, .combined_image_sampler, .sampled_image, .storage_image, .input_attachment => @sizeOf(vk.DescriptorImageInfo),
            .uniform_buffer, .storage_buffer, .uniform_buffer_dynamic, .storage_buffer_dynamic => @sizeOf(vk.DescriptorBufferInfo),
            .uniform_texel_buffer, .storage_texel_buffer => @sizeOf(vk.BufferView),
            else => return VkError.FeatureNotPresent,
        };

        var binding: usize = entry.dst_binding;
        var array_element: usize = entry.dst_array_element;
        for (0..entry.descriptor_count) |element| {
            while (true) {
                if (binding >= layout.bindings.len) return VkError.ValidationFailed;
                if (array_element < layout.bindings[binding].array_size) break;
                array_element -= layout.bindings[binding].array_size;
                binding += 1;
            }

            if (layout.bindings[binding].descriptor_type != entry.descriptor_type)
                return VkError.ValidationFailed;

            const displacement = std.math.mul(usize, element, entry.stride) catch return VkError.ValidationFailed;
            const offset = std.math.add(usize, entry.offset, displacement) catch return VkError.ValidationFailed;
            _ = std.math.add(usize, offset, data_size) catch return VkError.ValidationFailed;

            entries[index] = .{
                .binding = @intCast(binding),
                .array_element = @intCast(array_element),
                .descriptor_type = entry.descriptor_type,
                .offset = offset,
            };

            index += 1;
            array_element += 1;
        }
    }

    self.* = .{
        .owner = device,
        .entries = entries,
    };

    return self;
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.entries);
    allocator.destroy(self);
}

pub fn update(self: *const Self, p_set: vk.DescriptorSet, data: *const anyopaque) VkError!void {
    const set = try NonDispatchable(DescriptorSet).fromHandleObject(p_set);
    if (set.owner != self.owner)
        return VkError.InvalidHandleDrv;

    const bytes: [*]const u8 = @ptrCast(data);
    for (self.entries) |entry| {
        var write: vk.WriteDescriptorSet = .{
            .dst_set = p_set,
            .dst_binding = entry.binding,
            .dst_array_element = entry.array_element,
            .descriptor_count = 1,
            .descriptor_type = entry.descriptor_type,
            .p_image_info = undefined,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        switch (entry.descriptor_type) {
            .sampler, .combined_image_sampler, .sampled_image, .storage_image, .input_attachment => {
                const infos = [_]vk.DescriptorImageInfo{load(vk.DescriptorImageInfo, bytes + entry.offset)};
                write.p_image_info = &infos;
                try set.write(write);
            },
            .uniform_buffer, .storage_buffer, .uniform_buffer_dynamic, .storage_buffer_dynamic => {
                const infos = [_]vk.DescriptorBufferInfo{load(vk.DescriptorBufferInfo, bytes + entry.offset)};
                write.p_buffer_info = &infos;
                try set.write(write);
            },
            .uniform_texel_buffer, .storage_texel_buffer => {
                const views = [_]vk.BufferView{load(vk.BufferView, bytes + entry.offset)};
                write.p_texel_buffer_view = &views;
                try set.write(write);
            },
            else => return VkError.FeatureNotPresent,
        }
    }
}

fn load(comptime T: type, bytes: [*]const u8) T {
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
    return value;
}
