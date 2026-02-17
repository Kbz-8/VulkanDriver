const std = @import("std");
const vk = @import("vulkan");

const VulkanAllocator = @import("VulkanAllocator.zig");

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
    immutable_samplers: []*const Sampler,

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

/// Mesa's common Vulkan runtime states:
///
/// It's often necessary to store a pointer to the descriptor set layout in
/// the descriptor so that any entrypoint which has access to a descriptor
/// set also has the layout. While layouts are often passed into various
/// entrypoints, they're notably missing from vkUpdateDescriptorSets(). In
/// order to implement descriptor writes, you either need to stash a pointer
/// to the descriptor set layout in the descriptor set or you need to copy
/// all of the relevant information.  Storing a pointer is a lot cheaper.
///
/// Because descriptor set layout lifetimes and descriptor set lifetimes are
/// not guaranteed to coincide, we have to reference count if we're going to
/// do this.
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

    var stages: vk.ShaderStageFlags = .{};

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

            bindings[binding_index] = .{
                .descriptor_type = binding_info.descriptor_type,
                .array_size = descriptor_count,
                .dynamic_index = 0,
                .immutable_samplers = immutable_samplers[0..],
                .driver_data = undefined,
            };

            stages = stages.merge(binding_info.stage_flags);
        }
    }

    return .{
        .owner = device,
        .heap = heap,
        .bindings = bindings,
        .dynamic_offset_count = 0,
        .dynamic_descriptor_count = 0,
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
