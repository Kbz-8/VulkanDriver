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
