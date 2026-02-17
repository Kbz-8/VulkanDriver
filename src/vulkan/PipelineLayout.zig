const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");

const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .pipeline_layout;

owner: *Device,

set_count: usize,

set_layouts: [lib.VULKAN_MAX_DESCRIPTOR_SETS]?*DescriptorSetLayout,

dynamic_descriptor_offsets: [lib.VULKAN_MAX_DESCRIPTOR_SETS]usize,

push_ranges_count: usize,
push_ranges: [lib.VULKAN_MAX_PUSH_CONSTANT_RANGES]vk.PushConstantRange,

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

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.PipelineLayoutCreateInfo) VkError!Self {
    _ = allocator;
    var self: Self = .{
        .owner = device,
        .set_count = info.set_layout_count,
        .set_layouts = [_]?*DescriptorSetLayout{null} ** lib.VULKAN_MAX_DESCRIPTOR_SETS,
        .dynamic_descriptor_offsets = [_]usize{0} ** lib.VULKAN_MAX_DESCRIPTOR_SETS,
        .push_ranges_count = info.push_constant_range_count,
        .push_ranges = undefined,
        .ref_count = std.atomic.Value(usize).init(1),
        .vtable = undefined,
    };

    if (info.p_set_layouts) |set_layouts| {
        var dynamic_descriptor_count: usize = 0;
        for (set_layouts, 0..info.set_layout_count) |handle, i| {
            self.dynamic_descriptor_offsets[i] = dynamic_descriptor_count;
            if (handle != .null_handle) {
                const layout = try NonDispatchable(DescriptorSetLayout).fromHandleObject(handle);
                self.set_layouts[i] = layout;
                layout.ref();
                dynamic_descriptor_count += layout.dynamic_descriptor_count;
            }
        }
    }

    return self;
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.unref(allocator);
}

pub inline fn drop(self: *Self, allocator: std.mem.Allocator) void {
    for (self.set_layouts) |set_layout| {
        if (set_layout) |layout| {
            layout.unref(allocator);
        }
    }
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
