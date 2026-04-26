const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");
const PipelineCache = @import("PipelineCache.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .pipeline;

owner: *Device,

vtable: *const VTable,
bind_point: vk.PipelineBindPoint,
stages: vk.ShaderStageFlags,
mode: union(enum) {
    compute: struct {},
    graphics: struct {
        input_assembly: struct {
            binding_description: ?[]vk.VertexInputBindingDescription,
            attribute_description: ?[]vk.VertexInputAttributeDescription,
            topology: vk.PrimitiveTopology,
        },
    },
},

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn initCompute(device: *Device, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!Self {
    _ = allocator;
    _ = cache;

    return .{
        .owner = device,
        .vtable = undefined,
        .bind_point = .compute,
        .stages = info.stage.stage,
        .mode = .{ .compute = .{} },
    };
}

pub fn initGraphics(device: *Device, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!Self {
    _ = cache;

    var stages: vk.ShaderStageFlags = .{};
    if (info.p_stages) |p_stages| {
        for (p_stages[0..info.stage_count]) |stage| {
            stages = stages.merge(stage.stage);
        }
    }

    return .{
        .owner = device,
        .vtable = undefined,
        .bind_point = .graphics,
        .stages = stages,
        .mode = .{
            .graphics = .{
                .input_assembly = .{
                    .binding_description = blk: {
                        if (info.p_vertex_input_state) |vertex_input_state| {
                            if (vertex_input_state.p_vertex_binding_descriptions) |vertex_binding_descriptions| {
                                break :blk allocator.dupe(vk.VertexInputBindingDescription, vertex_binding_descriptions[0..vertex_input_state.vertex_binding_description_count]) catch return VkError.OutOfHostMemory;
                            }
                        } else {
                            return VkError.ValidationFailed;
                        }
                        break :blk null;
                    },
                    .attribute_description = blk: {
                        if (info.p_vertex_input_state) |vertex_input_state| {
                            if (vertex_input_state.p_vertex_attribute_descriptions) |vertex_attribute_descriptions| {
                                break :blk allocator.dupe(vk.VertexInputAttributeDescription, vertex_attribute_descriptions[0..vertex_input_state.vertex_attribute_description_count]) catch return VkError.OutOfHostMemory;
                            }
                        } else {
                            return VkError.ValidationFailed;
                        }
                        break :blk null;
                    },
                    .topology = if (info.p_input_assembly_state) |state| state.topology else return VkError.ValidationFailed,
                },
            },
        },
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    switch (self.mode) {
        .compute => {},
        .graphics => |graphics| {
            if (graphics.input_assembly.binding_description) |binding_description| {
                allocator.free(binding_description);
            }
            if (graphics.input_assembly.attribute_description) |attribute_description| {
                allocator.free(attribute_description);
            }
        },
    }
    self.vtable.destroy(self, allocator);
}
