const std = @import("std");
const base = @import("base");
const shader_ir = @import("shader_ir");

const Shader = @import("Shader.zig");

const VkError = base.VkError;
const ir = shader_ir.ir;

pub fn dispatch(shader: *Shader, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const local_size = shader.workgroup_size orelse return VkError.ValidationFailed;
    const local_xy = std.math.mul(usize, local_size[0], local_size[1]) catch return VkError.ValidationFailed;
    const local_count = std.math.mul(usize, local_xy, local_size[2]) catch return VkError.ValidationFailed;
    if (shader.runtimes.len == 0)
        return VkError.InvalidPipelineDrv;

    const global_id = findGlobalInvocationId(&shader.program);
    var runtime = &shader.runtimes[0].runtime;
    for (0..group_count_z) |group_z| {
        for (0..group_count_y) |group_y| {
            for (0..group_count_x) |group_x| {
                for (0..local_count) |local_index| {
                    if (global_id) |variable| {
                        const local_z = local_index / local_xy;
                        const local_remainder = local_index - local_z * local_xy;
                        const local_y = local_remainder / local_size[0];
                        const local_x = local_remainder - local_y * local_size[0];
                        runtime.writeInput(&shader.program, variable, &.{
                            (base_group_x + @as(u32, @intCast(group_x))) * local_size[0] + @as(u32, @intCast(local_x)),
                            (base_group_y + @as(u32, @intCast(group_y))) * local_size[1] + @as(u32, @intCast(local_y)),
                            (base_group_z + @as(u32, @intCast(group_z))) * local_size[2] + @as(u32, @intCast(local_z)),
                        }) catch return VkError.Unknown;
                    }
                    _ = runtime.run(&shader.program, .{}) catch return VkError.Unknown;
                }
            }
        }
    }
}

fn findGlobalInvocationId(program: *const @import("Program.zig")) ?ir.id.InterfaceVariableId {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction == .input and binding.semantic == .builtin and binding.semantic.builtin == .global_invocation_id)
            return ir.id.InterfaceVariableId.fromIndex(index);
    }
    return null;
}
