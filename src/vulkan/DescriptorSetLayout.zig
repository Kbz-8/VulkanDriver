const std = @import("std");
const vk = @import("vulkan");

const VulkanAllocator = @import("VulkanAllocator.zig");

const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");
const Sampler = @import("Sampler.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_set_layout;

const BindingLayout = struct {
    descriptor_type: vk.DescriptorType,
    dynamic_index: usize,
    array_size: usize,

    /// This slice points to an array located after the binding layouts array
    immutable_samplers: []const *const Sampler,

    driver_data: *anyopaque,
};

owner: *Device,

/// Memory containing actual binding layouts array and immutable samplers array
heap: []u8,

bindings: []BindingLayout,

dynamic_offset_count: usize,
dynamic_descriptor_count: usize,

/// Shader stages affected by this descriptor set
stages: vk.ShaderStageFlags,

ref_count: std.atomic.Value(usize),

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.DescriptorSetLayoutCreateInfo) VkError!Self {
    const command_allocator = VulkanAllocator.from(allocator).cloneWithScope(.command).allocator();

    var binding_count: usize = 0;
    var immutable_samplers_count: usize = 0;

    if (info.p_bindings) |binding_infos| {
        for (binding_infos, 0..info.binding_count) |binding, _| {
            binding_count = @max(binding_count, binding.binding + 1);
            if (bindingHasImmutableSamplers(binding)) {
                immutable_samplers_count += binding.descriptor_count;
            }
        }
    }

    const size = (binding_count * @sizeOf(BindingLayout)) + (immutable_samplers_count * @sizeOf(*Sampler));

    // Clean way to put the immutable samplers array right after the binding layouts one
    const heap = allocator.alloc(u8, size) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(heap);

    var local_heap = std.heap.FixedBufferAllocator.init(heap);
    const local_allocator = local_heap.allocator();

    const bindings = local_allocator.alloc(BindingLayout, binding_count) catch return VkError.OutOfHostMemory;
    const immutable_samplers = local_allocator.alloc(*const Sampler, immutable_samplers_count) catch return VkError.OutOfHostMemory;
    var immutable_samplers_offset: usize = 0;

    for (bindings) |*binding| {
        binding.* = .{
            .descriptor_type = .sampler,
            .array_size = 0,
            .dynamic_index = 0,
            .immutable_samplers = &.{},
            .driver_data = undefined,
        };
    }

    var stages: vk.ShaderStageFlags = .{};
    var dynamic_descriptor_count: usize = 0;
    var dynamic_offset_count: usize = 0;

    if (info.p_bindings) |binding_infos| {
        const sorted_bindings = command_allocator.dupe(vk.DescriptorSetLayoutBinding, binding_infos[0..info.binding_count]) catch return VkError.OutOfHostMemory;
        defer command_allocator.free(sorted_bindings);
        std.mem.sort(vk.DescriptorSetLayoutBinding, sorted_bindings, .{}, sortBindings);

        for (sorted_bindings) |binding_info| {
            const binding_index = binding_info.binding;

            const descriptor_count = switch (binding_info.descriptor_type) {
                .inline_uniform_block => 1,
                else => binding_info.descriptor_count,
            };

            const binding_immutable_samplers = if (bindingHasImmutableSamplers(binding_info)) blk: {
                const base = binding_info.p_immutable_samplers orelse return VkError.ValidationFailed;
                const binding_immutable_samplers = immutable_samplers[immutable_samplers_offset .. immutable_samplers_offset + descriptor_count];
                immutable_samplers_offset += descriptor_count;
                for (binding_immutable_samplers, base[0..descriptor_count]) |*dst, src| {
                    dst.* = try NonDispatchable(Sampler).fromHandleObject(src);
                }
                break :blk binding_immutable_samplers;
            } else &.{};

            const dynamic_index = dynamic_descriptor_count;
            if (bindingHasDynamicOffset(binding_info)) {
                dynamic_descriptor_count += descriptor_count;
                dynamic_offset_count += descriptor_count;
            }

            bindings[binding_index] = .{
                .descriptor_type = binding_info.descriptor_type,
                .array_size = descriptor_count,
                .dynamic_index = dynamic_index,
                .immutable_samplers = binding_immutable_samplers,
                .driver_data = undefined,
            };

            stages = stages.merge(binding_info.stage_flags);
        }
    }

    return .{
        .owner = device,
        .heap = heap,
        .bindings = bindings,
        .dynamic_offset_count = dynamic_offset_count,
        .dynamic_descriptor_count = dynamic_descriptor_count,
        .stages = stages,
        .ref_count = std.atomic.Value(usize).init(1),
        .vtable = undefined,
    };
}

fn sortBindings(_: @TypeOf(.{}), lhs: vk.DescriptorSetLayoutBinding, rhs: vk.DescriptorSetLayoutBinding) bool {
    return lhs.binding < rhs.binding;
}

inline fn bindingHasImmutableSamplers(binding: vk.DescriptorSetLayoutBinding) bool {
    return switch (binding.descriptor_type) {
        .sampler, .combined_image_sampler => binding.p_immutable_samplers != null,
        else => false,
    };
}

inline fn bindingHasDynamicOffset(binding: vk.DescriptorSetLayoutBinding) bool {
    return switch (binding.descriptor_type) {
        .uniform_buffer_dynamic, .storage_buffer_dynamic => true,
        else => false,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.unref(allocator);
}

pub inline fn drop(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.heap);
    self.vtable.destroy(self, allocator);
}

pub inline fn ref(self: *Self) void {
    _ = self.ref_count.fetchAdd(1, .monotonic);
}

pub inline fn unref(self: *Self, allocator: std.mem.Allocator) void {
    if (self.ref_count.fetchSub(1, .release) == 1) {
        self.drop(allocator);
    }
}
