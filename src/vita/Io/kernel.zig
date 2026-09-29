pub const Uid = i32;
pub const Size = u32;

pub const default_thread_priority: i32 = 0x10000100;
pub const default_thread_stack_size: u32 = 64 * 1024;
pub const default_cpu_affinity_mask: i32 = 0;

pub const error_wait_timeout: i32 = @bitCast(@as(u32, 0x80028005));

pub const ThreadEntry = *const fn (args: Size, argp: ?*anyopaque) callconv(.c) c_int;

pub extern fn sceKernelCreateThread(name: [*:0]const u8, entry: ThreadEntry, init_priority: i32, stack_size: Size, attr: u32, cpu_affinity_mask: i32, option: ?*const anyopaque) Uid;
pub extern fn sceKernelDeleteThread(thread_id: Uid) c_int;
pub extern fn sceKernelStartThread(thread_id: Uid, arg_len: Size, argp: ?*anyopaque) c_int;
pub extern fn sceKernelWaitThreadEnd(thread_id: Uid, status: ?*c_int, timeout_us: ?*u32) c_int;
pub extern fn sceKernelExitDeleteThread(status: c_int) c_int;
pub extern fn sceKernelGetThreadId() Uid;
pub extern fn sceKernelDelayThread(delay_us: u32) c_int;
pub extern fn sceKernelGetSystemTimeWide() i64;

pub extern fn sceKernelCreateMutex(name: [*:0]const u8, attr: u32, initial_count: c_int, option: ?*anyopaque) Uid;
pub extern fn sceKernelDeleteMutex(mutex_id: Uid) c_int;
pub extern fn sceKernelLockMutex(mutex_id: Uid, lock_count: c_int, timeout_us: ?*u32) c_int;
pub extern fn sceKernelUnlockMutex(mutex_id: Uid, unlock_count: c_int) c_int;

pub extern fn sceKernelCreateSema(name: [*:0]const u8, attr: u32, initial_value: c_int, maximum_value: c_int, option: ?*anyopaque) Uid;
pub extern fn sceKernelDeleteSema(semaphore_id: Uid) c_int;
pub extern fn sceKernelWaitSema(semaphore_id: Uid, signal: c_int, timeout_us: ?*u32) c_int;
pub extern fn sceKernelPollSema(semaphore_id: Uid, signal: c_int) c_int;
pub extern fn sceKernelSignalSema(semaphore_id: Uid, signal: c_int) c_int;
