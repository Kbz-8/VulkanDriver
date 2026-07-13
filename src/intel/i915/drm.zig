const vk = @import("vulkan");

pub const command_base = 0x40;
pub const i915_gem_create = 0x1b;
pub const i915_gem_mmap_gtt = 0x24;
pub const i915_gem_set_domain = 0x1f;
pub const i915_gem_execbuffer2 = 0x29;
pub const gem_close = 0x09;

pub const i915_mmap_offset_wb = 2;
pub const i915_gem_domain_cpu = 0x00000001;
pub const i915_gem_domain_gtt = 0x00000040;
pub const i915_exec_blt = 3 << 0;
pub const i915_exec_fence_array: u64 = 1 << 19;
pub const i915_exec_fence_wait: u32 = 1 << 0;
pub const i915_exec_fence_signal: u32 = 1 << 1;
pub const exec_object_write = 1 << 2;
pub const mi_flush_dw: u32 = (0x26 << 23) | 3;

pub const GemCreate = extern struct {
    size: u64,
    handle: u32,
    pad: u32,
};

pub const GemMmapOffset = extern struct {
    handle: u32,
    pad: u32,
    offset: u64,
    flags: u64,
    extensions: u64,
};

pub const GemClose = extern struct {
    handle: u32,
    pad: u32,
};

pub const GemSetDomain = extern struct {
    handle: u32,
    read_domains: u32,
    write_domain: u32,
};

pub const RelocationEntry = extern struct {
    target_handle: u32,
    delta: u32,
    offset: u64,
    presumed_offset: u64,
    read_domains: u32,
    write_domain: u32,
};

pub const ExecObject2 = extern struct {
    handle: u32,
    relocation_count: u32,
    relocs_ptr: u64,
    alignment: u64,
    offset: u64,
    flags: u64,
    rsvd1: u64,
    rsvd2: u64,
};

pub const ExecBuffer2 = extern struct {
    buffers_ptr: u64,
    buffer_count: u32,
    batch_start_offset: u32,
    batch_len: u32,
    DR1: u32,
    DR4: u32,
    num_cliprects: u32,
    cliprects_ptr: u64,
    flags: u64,
    rsvd1: u64,
    rsvd2: u64,
};

pub const ExecFence = extern struct {
    handle: u32,
    flags: u32,
};
