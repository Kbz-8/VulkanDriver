const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const root = @import("lib.zig");
const cpuinfo = @cImport(@cInclude("cpuinfo.h"));

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
        .getSparseImageFormatProperties2 = getSparseImageFormatProperties2,
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
        .max_bound_descriptor_sets = base.VULKAN_MAX_DESCRIPTOR_SETS,
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
        .texture_compression_etc2 = .true,
        .texture_compression_bc = .true,
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
        const name = blk: {
            if (cpuinfo.cpuinfo_initialize()) {
                const package = cpuinfo.cpuinfo_get_package(0).*;
                const non_sentinel_name = package.name[0..(std.mem.len(@as([*:0]const u8, @ptrCast(&package.name))))];
                break :blk std.fmt.allocPrint(command_allocator, "{s} ({d} threads)", .{ non_sentinel_name, package.processor_count }) catch return VkError.OutOfHostMemory;
            }
            break :blk command_allocator.dupe(u8, "Unkown") catch return VkError.OutOfHostMemory;
        };
        defer command_allocator.free(name);

        var writer = std.Io.Writer.fixed(device_name[0 .. vk.MAX_PHYSICAL_DEVICE_NAME_SIZE - 1]);
        writer.print("{s} [" ++ root.DRIVER_NAME ++ " StrollDriver]", .{name}) catch return VkError.InitializationFailed;
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
    var properties: vk.FormatProperties = .{};

    switch (format) {
        // Formats which can be sampled *and* filtered
        .r4g4b4a4_unorm_pack16,
        .b4g4r4a4_unorm_pack16,
        .a4r4g4b4_unorm_pack16,
        .a4b4g4r4_unorm_pack16,
        .r5g6b5_unorm_pack16,
        .b5g6r5_unorm_pack16,
        .r5g5b5a1_unorm_pack16,
        .b5g5r5a1_unorm_pack16,
        .a1r5g5b5_unorm_pack16,
        .r8_unorm,
        .r8_srgb,
        .r8_snorm,
        .r8g8_unorm,
        .r8g8_srgb,
        .r8g8_snorm,
        .r8g8b8a8_unorm,
        .r8g8b8a8_snorm,
        .r8g8b8a8_srgb,
        .b8g8r8a8_unorm,
        .b8g8r8a8_srgb,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_snorm_pack32,
        .a8b8g8r8_srgb_pack32,
        .a2b10g10r10_unorm_pack32,
        .a2r10g10b10_unorm_pack32,
        .r16_unorm,
        .r16_snorm,
        .r16_sfloat,
        .r16g16_unorm,
        .r16g16_snorm,
        .r16g16_sfloat,
        .r16g16b16a16_unorm,
        .r16g16b16a16_snorm,
        .r16g16b16a16_sfloat,
        .r32_sfloat,
        .r32g32_sfloat,
        .r32g32b32a32_sfloat,
        .b10g11r11_ufloat_pack32,
        .e5b9g9r9_ufloat_pack32,
        .bc1_rgb_unorm_block,
        .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block,
        .bc1_rgba_srgb_block,
        .bc2_unorm_block,
        .bc2_srgb_block,
        .bc3_unorm_block,
        .bc3_srgb_block,
        .bc4_unorm_block,
        .bc4_snorm_block,
        .bc5_unorm_block,
        .bc5_snorm_block,
        .bc6h_ufloat_block,
        .bc6h_sfloat_block,
        .bc7_unorm_block,
        .bc7_srgb_block,
        .etc2_r8g8b8_unorm_block,
        .etc2_r8g8b8_srgb_block,
        .etc2_r8g8b8a1_unorm_block,
        .etc2_r8g8b8a1_srgb_block,
        .etc2_r8g8b8a8_unorm_block,
        .etc2_r8g8b8a8_srgb_block,
        .eac_r11_unorm_block,
        .eac_r11_snorm_block,
        .eac_r11g11_unorm_block,
        .eac_r11g11_snorm_block,
        //.astc_4x_4_unorm_block,
        //.astc_5x_4_unorm_block,
        //.astc_5x_5_unorm_block,
        //.astc_6x_5_unorm_block,
        //.astc_6x_6_unorm_block,
        //.astc_8x_5_unorm_block,
        //.astc_8x_6_unorm_block,
        //.astc_8x_8_unorm_block,
        //.astc_1_0x_5_unorm_block,
        //.astc_1_0x_6_unorm_block,
        //.astc_1_0x_8_unorm_block,
        //.astc_1_0x_10_unorm_block,
        //.astc_1_2x_10_unorm_block,
        //.astc_1_2x_12_unorm_block,
        //.astc_4x_4_srgb_block,
        //.astc_5x_4_srgb_block,
        //.astc_5x_5_srgb_block,
        //.astc_6x_5_srgb_block,
        //.astc_6x_6_srgb_block,
        //.astc_8x_5_srgb_block,
        //.astc_8x_6_srgb_block,
        //.astc_8x_8_srgb_block,
        //.astc_1_0x_5_srgb_block,
        //.astc_1_0x_6_srgb_block,
        //.astc_1_0x_8_srgb_block,
        //.astc_1_0x_10_srgb_block,
        //.astc_1_2x_10_srgb_block,
        //.astc_1_2x_12_srgb_block,
        .d16_unorm,
        .d32_sfloat,
        .d32_sfloat_s8_uint,
        => {
            properties.optimal_tiling_features.blit_src_bit = true;
            properties.optimal_tiling_features.sampled_image_bit = true;
            properties.optimal_tiling_features.transfer_dst_bit = true;
            properties.optimal_tiling_features.transfer_src_bit = true;
            properties.optimal_tiling_features.sampled_image_filter_linear_bit = true;
        },

        // Formats which can be sampled, but don't support filtering
        .r8_uint,
        .r8_sint,
        .r8g8_uint,
        .r8g8_sint,
        .r8g8b8a8_uint,
        .r8g8b8a8_sint,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_sint_pack32,
        .a2b10g10r10_uint_pack32,
        .a2r10g10b10_uint_pack32,
        .r16_uint,
        .r16_sint,
        .r16g16_uint,
        .r16g16_sint,
        .r16g16b16a16_uint,
        .r16g16b16a16_sint,
        .r32_uint,
        .r32_sint,
        .r32g32_uint,
        .r32g32_sint,
        .r32g32b32a32_uint,
        .r32g32b32a32_sint,
        .s8_uint,
        => {
            properties.optimal_tiling_features.blit_src_bit = true;
            properties.optimal_tiling_features.sampled_image_bit = true;
            properties.optimal_tiling_features.transfer_dst_bit = true;
            properties.optimal_tiling_features.transfer_src_bit = true;
        },

        // YCbCr formats
        .g8_b8_r8_3plane_420_unorm,
        .g8_b8r8_2plane_420_unorm,
        .g10x6_b10x6r10x6_2plane_420_unorm_3pack16,
        => {
            properties.optimal_tiling_features.sampled_image_bit = true;
            properties.optimal_tiling_features.sampled_image_filter_linear_bit = true;
            properties.optimal_tiling_features.sampled_image_ycbcr_conversion_linear_filter_bit = true;
            properties.optimal_tiling_features.transfer_src_bit = true;
            properties.optimal_tiling_features.transfer_dst_bit = true;
            properties.optimal_tiling_features.cosited_chroma_samples_bit = true;
        },
        else => {},
    }

    switch (format) {
        // Vulkan 1.0 mandatory storage image formats supporting atomic operations
        .r32_uint,
        .r32_sint,
        => {
            properties.buffer_features.storage_texel_buffer_bit = true;
            properties.buffer_features.storage_texel_buffer_atomic_bit = true;
            properties.optimal_tiling_features.storage_image_bit = true;
            properties.optimal_tiling_features.storage_image_atomic_bit = true;
        },
        // vulkan 1.0 mandatory storage image formats
        .r8g8b8a8_unorm,
        .r8g8b8a8_snorm,
        .r8g8b8a8_uint,
        .r8g8b8a8_sint,
        .r16g16b16a16_uint,
        .r16g16b16a16_sint,
        .r16g16b16a16_sfloat,
        .r32_sfloat,
        .r32g32_uint,
        .r32g32_sint,
        .r32g32_sfloat,
        .r32g32b32a32_uint,
        .r32g32b32a32_sint,
        .r32g32b32a32_sfloat,
        .a2b10g10r10_unorm_pack32,
        .a2b10g10r10_uint_pack32,
        // vulkan 1.0 shaderstorageimageextendedformats
        .r16g16_sfloat,
        .b10g11r11_ufloat_pack32,
        .r16_sfloat,
        .r16g16b16a16_unorm,
        .r16g16_unorm,
        .r8g8_unorm,
        .r16_unorm,
        .r8_unorm,
        .r16g16b16a16_snorm,
        .r16g16_snorm,
        .r8g8_snorm,
        .r16_snorm,
        .r8_snorm,
        .r16g16_sint,
        .r8g8_sint,
        .r16_sint,
        .r8_sint,
        .r16g16_uint,
        .r8g8_uint,
        .r16_uint,
        .r8_uint,
        // additional formats not listed under "formats without shader storage format"
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_snorm_pack32,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_sint_pack32,
        .b8g8r8a8_unorm,
        .b8g8r8a8_srgb,
        => {
            properties.optimal_tiling_features.storage_image_bit = true;
            properties.buffer_features.storage_texel_buffer_bit = true;
        },

        else => {},
    }

    switch (format) {
        .r5g6b5_unorm_pack16,
        .a1r5g5b5_unorm_pack16,
        .r4g4b4a4_unorm_pack16,
        .b4g4r4a4_unorm_pack16,
        .a4r4g4b4_unorm_pack16,
        .a4b4g4r4_unorm_pack16,
        .b5g6r5_unorm_pack16,
        .r5g5b5a1_unorm_pack16,
        .b5g5r5a1_unorm_pack16,
        .r8_unorm,
        .r8g8_unorm,
        .r8g8b8a8_unorm,
        .r8g8b8a8_srgb,
        .b8g8r8a8_unorm,
        .b8g8r8a8_srgb,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_srgb_pack32,
        .a2b10g10r10_unorm_pack32,
        .a2r10g10b10_unorm_pack32,
        .r16_sfloat,
        .r16g16_sfloat,
        .r16g16b16a16_sfloat,
        .r32_sfloat,
        .r32g32_sfloat,
        .r32g32b32a32_sfloat,
        .b10g11r11_ufloat_pack32,
        .r8_uint,
        .r8_sint,
        .r8g8_uint,
        .r8g8_sint,
        .r8g8b8a8_uint,
        .r8g8b8a8_sint,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_sint_pack32,
        .a2b10g10r10_uint_pack32,
        .a2r10g10b10_uint_pack32,
        .r16_unorm,
        .r16_uint,
        .r16_sint,
        .r16g16_unorm,
        .r16g16_uint,
        .r16g16_sint,
        .r16g16b16a16_unorm,
        .r16g16b16a16_uint,
        .r16g16b16a16_sint,
        .r32_uint,
        .r32_sint,
        .r32g32_uint,
        .r32g32_sint,
        .r32g32b32a32_uint,
        .r32g32b32a32_sint,
        => {
            properties.optimal_tiling_features.color_attachment_bit = true;
            properties.optimal_tiling_features.blit_dst_bit = true;
        },
        .s8_uint,
        .d16_unorm,
        .d32_sfloat, // note: either vk_format_d32_sfloat or vk_format_x8_d24_unorm_pack32 must be supported
        .d32_sfloat_s8_uint,
        => { // note: either vk_format_d24_unorm_s8_uint or vk_format_d32_sfloat_s8_uint must be supported
            properties.optimal_tiling_features.depth_stencil_attachment_bit = true;
        },

        else => {},
    }

    if (base.Image.formatSupportsColorAttachemendBlend(format)) {
        properties.optimal_tiling_features.color_attachment_blend_bit = true;
    }

    switch (format) {
        .r8_unorm,
        .r8_snorm,
        .r8_uscaled,
        .r8_sscaled,
        .r8_uint,
        .r8_sint,
        .r8g8_unorm,
        .r8g8_snorm,
        .r8g8_uscaled,
        .r8g8_sscaled,
        .r8g8_uint,
        .r8g8_sint,
        .r8g8b8a8_unorm,
        .r8g8b8a8_snorm,
        .r8g8b8a8_uscaled,
        .r8g8b8a8_sscaled,
        .r8g8b8a8_uint,
        .r8g8b8a8_sint,
        .b8g8r8a8_unorm,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_snorm_pack32,
        .a8b8g8r8_uscaled_pack32,
        .a8b8g8r8_sscaled_pack32,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_sint_pack32,
        .a2r10g10b10_unorm_pack32,
        .a2r10g10b10_snorm_pack32,
        .a2r10g10b10_uint_pack32,
        .a2r10g10b10_sint_pack32,
        .a2b10g10r10_unorm_pack32,
        .a2b10g10r10_snorm_pack32,
        .a2b10g10r10_uint_pack32,
        .a2b10g10r10_sint_pack32,
        .r16_unorm,
        .r16_snorm,
        .r16_uscaled,
        .r16_sscaled,
        .r16_uint,
        .r16_sint,
        .r16_sfloat,
        .r16g16_unorm,
        .r16g16_snorm,
        .r16g16_uscaled,
        .r16g16_sscaled,
        .r16g16_uint,
        .r16g16_sint,
        .r16g16_sfloat,
        .r16g16b16a16_unorm,
        .r16g16b16a16_snorm,
        .r16g16b16a16_uscaled,
        .r16g16b16a16_sscaled,
        .r16g16b16a16_uint,
        .r16g16b16a16_sint,
        .r16g16b16a16_sfloat,
        .r32_uint,
        .r32_sint,
        .r32_sfloat,
        .r32g32_uint,
        .r32g32_sint,
        .r32g32_sfloat,
        .r32g32b32_uint,
        .r32g32b32_sint,
        .r32g32b32_sfloat,
        .r32g32b32a32_uint,
        .r32g32b32a32_sint,
        .r32g32b32a32_sfloat,
        => properties.buffer_features.vertex_buffer_bit = true,
        else => {},
    }

    switch (format) {
        // Vulkan 1.1 mandatory
        .r8_unorm,
        .r8_snorm,
        .r8_uint,
        .r8_sint,
        .r8g8_unorm,
        .r8g8_snorm,
        .r8g8_uint,
        .r8g8_sint,
        .r8g8b8a8_unorm,
        .r8g8b8a8_snorm,
        .r8g8b8a8_uint,
        .r8g8b8a8_sint,
        .b8g8r8a8_unorm,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_snorm_pack32,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_sint_pack32,
        .a2b10g10r10_unorm_pack32,
        .a2b10g10r10_uint_pack32,
        .r16_uint,
        .r16_sint,
        .r16_sfloat,
        .r16g16_uint,
        .r16g16_sint,
        .r16g16_sfloat,
        .r16g16b16a16_uint,
        .r16g16b16a16_sint,
        .r16g16b16a16_sfloat,
        .r32_uint,
        .r32_sint,
        .r32_sfloat,
        .r32g32_uint,
        .r32g32_sint,
        .r32g32_sfloat,
        .r32g32b32a32_uint,
        .r32g32b32a32_sint,
        .r32g32b32a32_sfloat,
        .b10g11r11_ufloat_pack32,
        // optional
        .a2r10g10b10_unorm_pack32,
        .a2r10g10b10_uint_pack32,
        => properties.buffer_features.uniform_texel_buffer_bit = true,
        else => {},
    }

    if (properties.optimal_tiling_features.toInt() != 0) {
        // "Formats that are required to support VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT must also support
        //  VK_FORMAT_FEATURE_TRANSFER_SRC_BIT and VK_FORMAT_FEATURE_TRANSFER_DST_BIT."

        properties.linear_tiling_features.transfer_src_bit = true;
        properties.linear_tiling_features.transfer_dst_bit = true;
    }

    return properties;
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

/// Soft does not support sparse images.
pub fn getSparseImageFormatProperties(
    interface: *Interface,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    properties: ?[*]vk.SparseImageFormatProperties,
) VkError!u32 {
    _ = interface;
    _ = format;
    _ = image_type;
    _ = samples;
    _ = tiling;
    _ = usage;
    _ = properties;
    return 0;
}

/// Soft does not support sparse images.
pub fn getSparseImageFormatProperties2(
    interface: *Interface,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    properties: ?[*]vk.SparseImageFormatProperties2,
) VkError!u32 {
    _ = interface;
    _ = format;
    _ = image_type;
    _ = samples;
    _ = tiling;
    _ = usage;
    _ = properties;
    return 0;
}
