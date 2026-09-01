pub const version: u32 = 1;

pub const BufferDescriptor = extern struct {
    address: u64,
    size: u64,
};

pub const KernelContext = extern struct {
    abi_version: u32,
    resource_count: u32,
    resources: u64,
    push_constants: u64,
    push_constant_size: u32,
    reserved: u32 = 0,
    base_group: [3]u32,
    group_count: [3]u32,
    local_size: [3]u32,
    num_workgroups: [3]u32,
};

pub const EntryPoint = *const fn (
    context: *const KernelContext,
    begin_workgroup: u64,
    end_workgroup: u64,
) callconv(.c) void;
