const std = @import("std");
const ids = @import("id.zig");

pub const TypeId = ids.TypeId;

pub const Signedness = enum { signed, unsigned };

pub const IntegerType = struct {
    bits: u16,
    signedness: Signedness,
};

pub const FloatType = struct {
    bits: u16,
};

pub const VectorType = struct {
    element_type: TypeId,
    length: u8,
};

pub const ArrayType = struct {
    element_type: TypeId,
    length: u32,
};

pub const StructureType = struct {
    members: []const TypeId,
};

pub const AddressSpace = enum {
    function,
    private,
    workgroup,
    input,
    output,
    uniform,
    storage,
    push_constant,
    physical,
};

pub const PointerType = struct {
    address_space: AddressSpace,
    pointee_type: TypeId,
};

pub const ResourceKind = enum {
    uniform_buffer,
    storage_buffer,
    sampled_image,
    storage_image,
    sampler,
};

pub const ResourceHandleType = struct {
    kind: ResourceKind,
    data_type: ?TypeId = null,
};

pub const Type = union(enum) {
    void,
    boolean,
    integer: IntegerType,
    floating: FloatType,
    vector: VectorType,
    array: ArrayType,
    structure: StructureType,
    pointer: PointerType,
    resource_handle: ResourceHandleType,

    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .void => b == .void,
            .boolean => b == .boolean,
            .integer => |value| switch (b) {
                .integer => |other| std.meta.eql(value, other),
                else => false,
            },
            .floating => |value| switch (b) {
                .floating => |other| std.meta.eql(value, other),
                else => false,
            },
            .vector => |value| switch (b) {
                .vector => |other| std.meta.eql(value, other),
                else => false,
            },
            .array => |value| switch (b) {
                .array => |other| std.meta.eql(value, other),
                else => false,
            },
            .structure => |value| switch (b) {
                .structure => |other| std.mem.eql(TypeId, value.members, other.members),
                else => false,
            },
            .pointer => |value| switch (b) {
                .pointer => |other| std.meta.eql(value, other),
                else => false,
            },
            .resource_handle => |value| switch (b) {
                .resource_handle => |other| std.meta.eql(value, other),
                else => false,
            },
        };
    }
};
