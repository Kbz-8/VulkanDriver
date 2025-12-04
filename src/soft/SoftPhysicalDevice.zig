const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const root = @import("lib.zig");
const cpuinfo = @import("cpuinfo");

const SoftDevice = @import("SoftDevice.zig");

const VkError = base.VkError;
const VulkanAllocator = base.VulkanAllocator;

const Self = @This();
pub const Interface = base.PhysicalDevice;

// Device name should always be the same so avoid reprocessing it multiple times
var device_name = [_]u8{0} ** vk.MAX_PHYSICAL_DEVICE_NAME_SIZE;

interface: Interface,

pub fn create(allocator: std.mem.Allocator, instance: *const base.Instance) VkError!*Self {
    const command_allocator = VulkanAllocator.from(allocator).cloneWithScope(.command).allocator();

    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, instance);

    interface.dispatch_table = &.{
        .createDevice = createDevice,
        .getFormatProperties = getFormatProperties,
        .getImageFormatProperties = getImageFormatProperties,
        .getSparseImageFormatProperties = getSparseImageFormatProperties,
        .release = destroy,
    };

    interface.props.api_version = @bitCast(root.VULKAN_VERSION);
    interface.props.driver_version = @bitCast(root.DRIVER_VERSION);
    interface.props.device_id = root.DEVICE_ID;
    interface.props.device_type = .cpu;
    interface.props.limits = .{
        .max_image_dimension_1d = 4096,
        .max_image_dimension_2d = 4096,
        .max_image_dimension_3d = 256,
        .max_image_dimension_cube = 4096,
        .max_image_array_layers = 256,
        .max_texel_buffer_elements = 65536,
        .max_uniform_buffer_range = 16384,
        .max_storage_buffer_range = 134217728,
        .max_push_constants_size = 128,
        .max_memory_allocation_count = std.math.maxInt(u32),
        .max_sampler_allocation_count = 4096,
        .buffer_image_granularity = 131072,
        .sparse_address_space_size = 0,
        .max_bound_descriptor_sets = 4,
        .max_per_stage_descriptor_samplers = 16,
        .max_per_stage_descriptor_uniform_buffers = 12,
        .max_per_stage_descriptor_storage_buffers = 4,
        .max_per_stage_descriptor_sampled_images = 16,
        .max_per_stage_descriptor_storage_images = 4,
        .max_per_stage_descriptor_input_attachments = 4,
        .max_per_stage_resources = 128,
        .max_descriptor_set_samplers = 96,
        .max_descriptor_set_uniform_buffers = 72,
        .max_descriptor_set_uniform_buffers_dynamic = 8,
        .max_descriptor_set_storage_buffers = 24,
        .max_descriptor_set_storage_buffers_dynamic = 4,
        .max_descriptor_set_sampled_images = 96,
        .max_descriptor_set_storage_images = 24,
        .max_descriptor_set_input_attachments = 4,
        .max_vertex_input_attributes = 16,
        .max_vertex_input_bindings = 16,
        .max_vertex_input_attribute_offset = 2047,
        .max_vertex_input_binding_stride = 2048,
        .max_vertex_output_components = 64,
        .max_tessellation_generation_level = 0,
        .max_tessellation_patch_size = 0,
        .max_tessellation_control_per_vertex_input_components = 0,
        .max_tessellation_control_per_vertex_output_components = 0,
        .max_tessellation_control_per_patch_output_components = 0,
        .max_tessellation_control_total_output_components = 0,
        .max_tessellation_evaluation_input_components = 0,
        .max_tessellation_evaluation_output_components = 0,
        .max_geometry_shader_invocations = 0,
        .max_geometry_input_components = 0,
        .max_geometry_output_components = 0,
        .max_geometry_output_vertices = 0,
        .max_geometry_total_output_components = 0,
        .max_fragment_input_components = 64,
        .max_fragment_output_attachments = 4,
        .max_fragment_dual_src_attachments = 0,
        .max_fragment_combined_output_resources = 4,
        .max_compute_shared_memory_size = 16384,
        .max_compute_work_group_count = .{ 65535, 65535, 65535 },
        .max_compute_work_group_invocations = 128,
        .max_compute_work_group_size = .{ 128, 128, 64 },
        .sub_pixel_precision_bits = 4,
        .sub_texel_precision_bits = 4,
        .mipmap_precision_bits = 4,
        .max_draw_indexed_index_value = 4294967295,
        .max_draw_indirect_count = 65535,
        .max_sampler_lod_bias = 2.0,
        .max_sampler_anisotropy = 1.0,
        .max_viewports = 1,
        .max_viewport_dimensions = .{ 4096, 4096 },
        .viewport_bounds_range = .{ -8192.0, 8191.0 },
        .viewport_sub_pixel_bits = 0,
        .min_memory_map_alignment = 64,
        .min_texel_buffer_offset_alignment = 256,
        .min_uniform_buffer_offset_alignment = 256,
        .min_storage_buffer_offset_alignment = 256,
        .min_texel_offset = -8,
        .max_texel_offset = 7,
        .min_texel_gather_offset = 0,
        .max_texel_gather_offset = 0,
        .min_interpolation_offset = 0.0,
        .max_interpolation_offset = 0.0,
        .sub_pixel_interpolation_offset_bits = 0,
        .max_framebuffer_width = 4096,
        .max_framebuffer_height = 4096,
        .max_framebuffer_layers = 256,
        .framebuffer_color_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .framebuffer_depth_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .framebuffer_stencil_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .framebuffer_no_attachments_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .max_color_attachments = 4,
        .sampled_image_color_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .sampled_image_integer_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .sampled_image_depth_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .sampled_image_stencil_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .storage_image_sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .max_sample_mask_words = 1,
        .timestamp_compute_and_graphics = .false,
        .timestamp_period = 1.0,
        .max_clip_distances = 0,
        .max_cull_distances = 0,
        .max_combined_clip_and_cull_distances = 0,
        .discrete_queue_priorities = 2,
        .point_size_range = .{ 1.0, 1.0 },
        .line_width_range = .{ 1.0, 1.0 },
        .point_size_granularity = 0.0,
        .line_width_granularity = 0.0,
        .strict_lines = .false,
        .standard_sample_locations = .true,
        .optimal_buffer_copy_offset_alignment = 1,
        .optimal_buffer_copy_row_pitch_alignment = 1,
        .non_coherent_atom_size = 256,
    };

    interface.mem_props.memory_type_count = 1;
    interface.mem_props.memory_types[0] = .{
        .heap_index = 0,
        .property_flags = .{
            .device_local_bit = true,
            .host_visible_bit = true,
            .host_coherent_bit = true,
            .host_cached_bit = true,
        },
    };
    interface.mem_props.memory_heap_count = 1;
    interface.mem_props.memory_heaps[0] = .{
        .size = std.process.totalSystemMemory() catch 0,
        .flags = .{}, // Host memory
    };

    interface.features = .{
        .robust_buffer_access = .true,
        .shader_float_64 = .true,
        .shader_int_64 = .true,
        .shader_int_16 = .true,
    };

    var queue_family_props = [_]vk.QueueFamilyProperties{
        .{
            .queue_flags = .{ .graphics_bit = true, .compute_bit = true, .transfer_bit = true },
            .queue_count = 1,
            .timestamp_valid_bits = 0,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
        .{
            .queue_flags = .{ .graphics_bit = true },
            .queue_count = 1,
            .timestamp_valid_bits = 0,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
        .{
            .queue_flags = .{ .transfer_bit = true },
            .queue_count = 1,
            .timestamp_valid_bits = 0,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
        // TODO: maybe add a compute specialized queue
    };
    interface.queue_family_props.appendSlice(allocator, queue_family_props[0..]) catch return VkError.OutOfHostMemory;

    if (device_name[0] == 0) {
        // TODO: use Pytorch's cpuinfo someday
        const info = cpuinfo.get(command_allocator) catch return VkError.InitializationFailed;
        defer info.deinit(command_allocator);

        var writer = std.Io.Writer.fixed(device_name[0 .. vk.MAX_PHYSICAL_DEVICE_NAME_SIZE - 1]);
        writer.print("{s} [" ++ root.DRIVER_NAME ++ " StrollDriver]", .{info.name}) catch return VkError.InitializationFailed;
    }

    @memcpy(&interface.props.device_name, &device_name);

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn createDevice(interface: *Interface, allocator: std.mem.Allocator, infos: *const vk.DeviceCreateInfo) VkError!*base.Device {
    const device = try SoftDevice.create(interface, allocator, infos);
    return &device.interface;
}

pub fn getFormatProperties(interface: *Interface, format: vk.Format) VkError!vk.FormatProperties {
    _ = interface;
    _ = format;
    return .{};
}

pub fn getImageFormatProperties(
    interface: *Interface,
    format: vk.Format,
    image_type: vk.ImageType,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
) VkError!vk.ImageFormatProperties {
    _ = interface;
    _ = format;
    _ = image_type;
    _ = tiling;
    _ = usage;
    _ = flags;
    return .{
        .max_extent = undefined,
        .max_mip_levels = 1,
        .max_array_layers = 6,
        .sample_counts = .{ .@"1_bit" = true, .@"4_bit" = true },
        .max_resource_size = 0,
    };
}

pub fn getSparseImageFormatProperties(
    interface: *Interface,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
) VkError!vk.SparseImageFormatProperties {
    _ = interface;
    _ = format;
    _ = image_type;
    _ = samples;
    _ = tiling;
    _ = usage;
    _ = flags;
    return undefined;
}
