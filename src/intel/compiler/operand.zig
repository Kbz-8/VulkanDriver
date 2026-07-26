const device = @import("device.zig");
const ids = @import("id.zig");

pub const DataType = enum {
    u8,
    i8,
    u16,
    i16,
    f16,
    u32,
    i32,
    f32,
    u64,
    i64,
    f64,

    pub fn sizeBytes(self: DataType) u8 {
        return switch (self) {
            .u8, .i8 => 1,
            .u16, .i16, .f16 => 2,
            .u32, .i32, .f32 => 4,
            .u64, .i64, .f64 => 8,
        };
    }

    pub fn isInitialTargetType(self: DataType) bool {
        return switch (self) {
            .u32, .i32, .f32 => true,
            else => false,
        };
    }
};

pub const RegisterClass = enum {
    uniform,
    varying,
    payload,
    response,
    temporary,
};

pub const VirtualRegister = struct {
    size_bytes: u32,
    alignment_bytes: u16,
    element_type: DataType,
    lane_count: u8,
    class: RegisterClass,
    spillable: bool = true,
    name: ?[]const u8 = null,
};

pub const VirtualFlag = struct {
    name: ?[]const u8 = null,
};

pub const PhysicalGrf = struct {
    number: u16,
    byte_offset: u8 = 0,
};

pub const PhysicalFlag = struct {
    register: u8 = 0,
    subregister: u8 = 0,
};

pub const ArchitectureRegister = union(enum) {
    flag: u8,
    address: u8,
    accumulator: u8,
    notification: u8,
    instruction_pointer,
};

pub const Immediate = union(enum) {
    u32: u32,
    i32: i32,
    f32: f32,
};

pub const RegisterRef = union(enum) {
    virtual: ids.VirtualRegisterId,
    physical_grf: PhysicalGrf,
    architecture: ArchitectureRegister,
    immediate: Immediate,
    null,
};

pub const FlagRef = union(enum) {
    virtual: ids.VirtualFlagId,
    physical: PhysicalFlag,
};

pub const Predicate = struct {
    flag: FlagRef,
    inverse: bool = false,
};

pub const Region = struct {
    byte_offset: u16 = 0,
    vertical_stride: u8,
    width: u8,
    horizontal_stride: u8,

    pub fn scalar() Region {
        return .{
            .vertical_stride = 0,
            .width = 1,
            .horizontal_stride = 0,
        };
    }

    pub fn contiguous(execution_size: device.ExecutionSize) Region {
        const width: u8 = @intFromEnum(execution_size);
        return .{
            .vertical_stride = width,
            .width = width,
            .horizontal_stride = 1,
        };
    }

    pub fn broadcast() Region {
        return scalar();
    }
};

pub const DestinationRegion = struct {
    byte_offset: u16 = 0,
    horizontal_stride: u8 = 1,
};

pub const Source = struct {
    register: RegisterRef,
    type: DataType,
    region: Region,
    negate: bool = false,
    absolute: bool = false,
};

pub const Destination = struct {
    register: RegisterRef,
    type: DataType,
    region: DestinationRegion = .{},
};

pub const RegisterSpan = struct {
    base: RegisterRef,
    register_count: u8,
};
