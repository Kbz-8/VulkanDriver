pub const Generation = enum {
    gen9,
    gen10,
    gen11,
};

pub const Platform = enum {
    skylake,
    broxton,
    kabylake,
    gemini_lake,
    coffee_lake,
    whiskey_lake,
    comet_lake,
    ice_lake,
    elkhart_lake,
    jasper_lake,
};

pub const DeviceInfo = struct {
    generation: Generation,
    platform: Platform,
    pci_device_id: u16,

    grf_count: u16,
    grf_size_bytes: u16 = 32,

    supports_int64: bool = false,
    supports_float64: bool = false,
    supports_half_float: bool = false,
    supports_simd16: bool = false,
    supports_simd32: bool = false,

    pub fn supportsDispatch(self: DeviceInfo, width: DispatchWidth) bool {
        return switch (width) {
            .simd8 => true,
            .simd16 => self.supports_simd16,
            .simd32 => self.supports_simd32,
        };
    }

    pub fn fromPciDeviceId(raw_pci_device_id: u32) ?DeviceInfo {
        if (raw_pci_device_id > 0xffff)
            return null;
        const pci_device_id: u16 = @intCast(raw_pci_device_id);

        const platform: Platform = switch (pci_device_id & 0xff00) {
            0x1900 => .skylake,
            0x5900 => .kabylake,

            0x3e00 => switch (pci_device_id) {
                0x3ea0,
                0x3ea1,
                0x3ea2,
                0x3ea3,
                0x3ea4,
                => .whiskey_lake,

                else => .coffee_lake,
            },

            0x9b00 => .comet_lake,
            0x8a00 => .ice_lake,
            0x4500 => .elkhart_lake,
            0x4e00 => .jasper_lake,

            else => switch (pci_device_id) {
                0x0a84,
                0x1a84,
                0x1a85,
                0x5a84,
                0x5a85,
                => .broxton,

                0x3184,
                0x3185,
                => .gemini_lake,

                0x87c0,
                0x87ca,
                => .kabylake,

                else => return null,
            },
        };

        const generation: Generation = switch (platform) {
            .skylake,
            .broxton,
            .kabylake,
            .gemini_lake,
            .coffee_lake,
            .whiskey_lake,
            .comet_lake,
            => .gen9,

            .ice_lake,
            .elkhart_lake,
            .jasper_lake,
            => .gen11,
        };

        return .{
            .generation = generation,
            .platform = platform,
            .pci_device_id = pci_device_id,
            .grf_count = 128,
        };
    }
};

pub const DispatchWidth = enum(u8) {
    simd8 = 8,
    simd16 = 16,
    simd32 = 32,
};

pub const ExecutionSize = enum(u8) {
    simd1 = 1,
    simd2 = 2,
    simd4 = 4,
    simd8 = 8,
    simd16 = 16,
    simd32 = 32,
};

test "compiler device: classify supported Intel PCI IDs" {
    const std = @import("std");

    try std.testing.expectEqual(Platform.skylake, DeviceInfo.fromPciDeviceId(0x1912).?.platform);
    try std.testing.expectEqual(Platform.broxton, DeviceInfo.fromPciDeviceId(0x5a84).?.platform);
    try std.testing.expectEqual(Platform.kabylake, DeviceInfo.fromPciDeviceId(0x5916).?.platform);
    try std.testing.expectEqual(Platform.whiskey_lake, DeviceInfo.fromPciDeviceId(0x3ea0).?.platform);
    try std.testing.expectEqual(Platform.comet_lake, DeviceInfo.fromPciDeviceId(0x9bc5).?.platform);
    try std.testing.expectEqual(Generation.gen11, DeviceInfo.fromPciDeviceId(0x8a52).?.generation);
    try std.testing.expectEqual(Generation.gen11, DeviceInfo.fromPciDeviceId(0x4e55).?.generation);
    try std.testing.expectEqual(@as(?DeviceInfo, null), DeviceInfo.fromPciDeviceId(0x46a6));
}
