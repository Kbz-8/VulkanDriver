const std = @import("std");
const kernel = @import("kernel.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const cancellation_poll_us: u32 = 1_000;
const nanoseconds_per_microsecond: i96 = std.time.ns_per_us;

pub const InitOptions = struct {
    thread_priority: i32 = kernel.default_thread_priority,
    thread_stack_size: u32 = kernel.default_thread_stack_size,
    cpu_affinity_mask: i32 = kernel.default_cpu_affinity_mask,
};

pub const InitError = error{SystemResources};

/// A native PS Vita `std.Io` backend.
///
/// The allocator must be thread-safe. Futures and group tasks allocate and
/// release their copied contexts from different Vita kernel threads.
pub const Threaded = struct {
    allocator: Allocator,
    options: InitOptions,
    mutex_id: kernel.Uid,
    idle_semaphore_id: kernel.Uid,
    current_tasks: ?*TaskControl = null,
    futex_waiters: ?*FutexWaiter = null,
    running_threads: usize = 0,
    future_count: usize = 0,
    group_state_count: usize = 0,
    random_state: u64,

    pub fn init(allocator: Allocator, options: InitOptions) InitError!Threaded {
        const mutex_id = kernel.sceKernelCreateMutex("psvk-io\x00", 0, 0, null);
        if (mutex_id < 0)
            return error.SystemResources;

        errdefer checkKernel(kernel.sceKernelDeleteMutex(mutex_id));

        const idle_semaphore_id = kernel.sceKernelCreateSema("psvk-io-idle\x00", 0, 0, 1, null);
        if (idle_semaphore_id < 0)
            return error.SystemResources;

        var seed: u64 = @bitCast(kernel.sceKernelGetSystemTimeWide());
        seed ^= @as(u32, @bitCast(kernel.sceKernelGetThreadId()));

        if (seed == 0)
            seed = 0x9e3779b97f4a7c15;

        return .{
            .allocator = allocator,
            .options = options,
            .mutex_id = mutex_id,
            .idle_semaphore_id = idle_semaphore_id,
            .random_state = seed,
        };
    }

    pub fn deinit(self: *Threaded) void {
        while (true) {
            self.lock();
            const running = self.running_threads;
            self.unlock();

            if (running == 0)
                break;

            waitSemaphoreUncancelable(self.idle_semaphore_id);
        }

        self.lock();
        if (self.future_count != 0 or self.group_state_count != 0 or self.current_tasks != null or self.futex_waiters != null) {
            self.unlock();
            @panic("deinitialized PS Vita Io with outstanding operations");
        }
        self.unlock();

        checkKernel(kernel.sceKernelDeleteSema(self.idle_semaphore_id));
        checkKernel(kernel.sceKernelDeleteMutex(self.mutex_id));
        self.* = undefined;
    }

    pub fn io(self: *Threaded) Io {
        return .{
            .userdata = self,
            .vtable = &vtable,
        };
    }

    fn lock(self: *Threaded) void {
        checkKernel(kernel.sceKernelLockMutex(self.mutex_id, 1, null));
    }

    fn unlock(self: *Threaded) void {
        checkKernel(kernel.sceKernelUnlockMutex(self.mutex_id, 1));
    }

    fn registerCurrent(self: *Threaded, control: *TaskControl) void {
        self.lock();
        defer self.unlock();

        control.thread_id = kernel.sceKernelGetThreadId();
        control.current_next = self.current_tasks;
        self.current_tasks = control;
    }

    fn removeCurrentLocked(self: *Threaded, control: *TaskControl) void {
        var previous: ?*TaskControl = null;
        var current = self.current_tasks;
        while (current) |candidate| {
            if (candidate == control) {
                if (previous) |item| {
                    item.current_next = candidate.current_next;
                } else {
                    self.current_tasks = candidate.current_next;
                }
                candidate.current_next = null;
                return;
            }
            previous = candidate;
            current = candidate.current_next;
        }
        @panic("PS Vita Io task registry is corrupt");
    }

    fn currentControl(self: *Threaded) ?*TaskControl {
        const thread_id = kernel.sceKernelGetThreadId();

        self.lock();
        defer self.unlock();

        var current = self.current_tasks;
        while (current) |candidate| : (current = candidate.current_next) {
            if (candidate.thread_id == thread_id)
                return candidate;
        }
        return null;
    }

    fn addRunningLocked(self: *Threaded) void {
        if (self.running_threads == 0)
            _ = kernel.sceKernelPollSema(self.idle_semaphore_id, 1);

        self.running_threads += 1;
    }

    fn finishRunningLocked(self: *Threaded) void {
        std.debug.assert(self.running_threads > 0);
        self.running_threads -= 1;

        if (self.running_threads == 0)
            signalSemaphore(self.idle_semaphore_id);
    }
};

const vtable: Io.VTable = table: {
    var result = Io.failing.vtable.*;
    result.crashHandler = crashHandler;

    result.async = async;
    result.concurrent = concurrent;
    result.await = await;
    result.cancel = cancel;

    result.groupAsync = groupAsync;
    result.groupConcurrent = groupConcurrent;
    result.groupAwait = groupAwait;
    result.groupCancel = groupCancel;

    result.recancel = recancel;
    result.swapCancelProtection = swapCancelProtection;
    result.checkCancel = checkCancel;

    result.futexWait = futexWait;
    result.futexWaitUncancelable = futexWaitUncancelable;
    result.futexWake = futexWake;

    result.batchAwaitAsync = batchAwaitAsync;
    result.batchAwaitConcurrent = batchAwaitConcurrent;
    result.batchCancel = batchCancel;

    result.now = now;
    result.clockResolution = clockResolution;
    result.sleep = sleep;
    result.random = random;
    break :table result;
};

const Buffer = struct {
    ptr: [*]u8,
    len: usize,
    allocated_len: usize,
    alignment: Alignment,

    fn create(allocator: Allocator, len: usize, alignment: Alignment) Allocator.Error!Buffer {
        const allocated_len = @max(len, 1);
        const ptr = allocator.rawAlloc(allocated_len, alignment, @returnAddress()) orelse return error.OutOfMemory;
        return .{
            .ptr = ptr,
            .len = len,
            .allocated_len = allocated_len,
            .alignment = alignment,
        };
    }

    fn destroy(buffer: Buffer, allocator: Allocator) void {
        allocator.rawFree(buffer.ptr[0..buffer.allocated_len], buffer.alignment, @returnAddress());
    }

    fn bytes(buffer: Buffer) []u8 {
        return buffer.ptr[0..buffer.len];
    }
};

const CancellationState = enum(u8) {
    none,
    pending,
    acknowledged,
};

const TaskControl = struct {
    cancellation: std.atomic.Value(CancellationState) = .init(.none),
    protection: Io.CancelProtection = .unblocked,
    thread_id: kernel.Uid = -1,
    current_next: ?*TaskControl = null,

    fn request(control: *TaskControl) void {
        control.cancellation.store(.pending, .release);
    }

    fn takeCancellation(control: *TaskControl) bool {
        if (control.protection == .blocked)
            return false;
        return control.cancellation.cmpxchgStrong(.pending, .acknowledged, .acq_rel, .acquire) == null;
    }

    fn recancel(control: *TaskControl) void {
        if (control.cancellation.cmpxchgStrong(.acknowledged, .pending, .acq_rel, .acquire) != null)
            @panic("recancel called without an acknowledged cancellation");
    }

    fn acknowledged(control: *TaskControl) bool {
        return control.cancellation.load(.acquire) == .acknowledged;
    }
};

const FutureTask = struct {
    backend: *Threaded,
    control: TaskControl = .{},
    thread_id: kernel.Uid = -1,
    context: Buffer,
    result: Buffer,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,

    fn create(
        backend: *Threaded,
        result_len: usize,
        result_alignment: Alignment,
        context: []const u8,
        context_alignment: Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) Allocator.Error!*FutureTask {
        var context_copy = try Buffer.create(backend.allocator, context.len, context_alignment);
        errdefer context_copy.destroy(backend.allocator);

        @memcpy(context_copy.bytes(), context);

        var result_storage = try Buffer.create(backend.allocator, result_len, result_alignment);
        errdefer result_storage.destroy(backend.allocator);

        const task = try backend.allocator.create(FutureTask);
        task.* = .{
            .backend = backend,
            .context = context_copy,
            .result = result_storage,
            .start = start,
        };
        return task;
    }

    fn destroy(task: *FutureTask) void {
        const allocator = task.backend.allocator;
        task.context.destroy(allocator);
        task.result.destroy(allocator);
        allocator.destroy(task);
    }
};

fn backendFromUserdata(userdata: ?*anyopaque) *Threaded {
    return @ptrCast(@alignCast(userdata orelse @panic("missing PS Vita Io backend")));
}

fn spawnFuture(backend: *Threaded, task: *FutureTask) bool {
    const thread_id = kernel.sceKernelCreateThread("psvk-io-future\x00", futureEntry, backend.options.thread_priority, backend.options.thread_stack_size, 0, backend.options.cpu_affinity_mask, null);

    if (thread_id < 0)
        return false;

    task.thread_id = thread_id;
    var argument = task;

    backend.lock();
    backend.addRunningLocked();
    backend.future_count += 1;

    const start_result = kernel.sceKernelStartThread(thread_id, @sizeOf(*FutureTask), @ptrCast(&argument));
    if (start_result < 0) {
        backend.future_count -= 1;
        backend.finishRunningLocked();
        backend.unlock();
        checkKernel(kernel.sceKernelDeleteThread(thread_id));
        return false;
    }

    backend.unlock();
    return true;
}

fn futureEntry(argument_size: u32, argument_ptr: ?*anyopaque) callconv(.c) c_int {
    if (argument_size != @sizeOf(*FutureTask))
        return -1;

    const task = @as(*const *FutureTask, @ptrCast(@alignCast(argument_ptr orelse return -1))).*;
    const backend = task.backend;

    backend.registerCurrent(&task.control);
    task.start(task.context.ptr, task.result.ptr);

    backend.lock();
    backend.removeCurrentLocked(&task.control);
    backend.finishRunningLocked();
    backend.unlock();
    return 0;
}

fn async(
    userdata: ?*anyopaque,
    eager_result: []u8,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    const backend = backendFromUserdata(userdata);
    const task = FutureTask.create(backend, eager_result.len, result_alignment, context, context_alignment, start) catch {
        start(context.ptr, eager_result.ptr);
        return null;
    };

    if (!spawnFuture(backend, task)) {
        task.destroy();
        start(context.ptr, eager_result.ptr);
        return null;
    }

    return @ptrCast(task);
}

fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    const backend = backendFromUserdata(userdata);

    const task = FutureTask.create(backend, result_len, result_alignment, context, context_alignment, start) catch return error.ConcurrencyUnavailable;
    errdefer task.destroy();

    if (!spawnFuture(backend, task))
        return error.ConcurrencyUnavailable;

    return @ptrCast(task);
}

fn waitForFuture(task: *FutureTask, propagate_cancellation: bool) void {
    const parent = if (propagate_cancellation) task.backend.currentControl() else null;
    var propagated = false;

    if (parent == null) {
        checkKernel(kernel.sceKernelWaitThreadEnd(task.thread_id, null, null));
    } else {
        while (true) {
            if (TaskControl.takeCancellation(parent.?)) {
                task.control.request();
                propagated = true;
            }

            var timeout_us = cancellation_poll_us;
            const wait_result = kernel.sceKernelWaitThreadEnd(task.thread_id, null, &timeout_us);

            if (wait_result >= 0)
                break;

            if (wait_result != kernel.error_wait_timeout)
                @panic("sceKernelWaitThreadEnd failed");
        }
    }

    if (propagated and !task.control.acknowledged())
        parent.?.recancel();
}

fn finishFuture(task: *FutureTask, result: []u8, propagate_cancellation: bool) void {
    std.debug.assert(result.len == task.result.len);
    waitForFuture(task, propagate_cancellation);
    @memcpy(result, task.result.bytes());
    checkKernel(kernel.sceKernelDeleteThread(task.thread_id));

    const backend = task.backend;
    backend.lock();
    std.debug.assert(backend.future_count > 0);
    backend.future_count -= 1;
    backend.unlock();
    task.destroy();
}

fn await(_: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, _: Alignment) void {
    const task: *FutureTask = @ptrCast(@alignCast(any_future));
    finishFuture(task, result, true);
}

fn cancel(_: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, _: Alignment) void {
    const task: *FutureTask = @ptrCast(@alignCast(any_future));
    task.control.request();
    finishFuture(task, result, false);
}

const GroupState = struct {
    backend: *Threaded,
    semaphore_id: kernel.Uid,
    tasks: ?*GroupTask = null,
    pending: usize = 0,
    cancel_requested: bool = false,
};

const GroupTask = struct {
    backend: *Threaded,
    state: *GroupState,
    control: TaskControl = .{},
    context: Buffer,
    start: *const fn (context: *const anyopaque) void,
    group_next: ?*GroupTask = null,

    fn create(backend: *Threaded, context: []const u8, context_alignment: Alignment, start: *const fn (context: *const anyopaque) void) Allocator.Error!*GroupTask {
        var context_copy = try Buffer.create(backend.allocator, context.len, context_alignment);
        errdefer context_copy.destroy(backend.allocator);

        @memcpy(context_copy.bytes(), context);

        const task = try backend.allocator.create(GroupTask);
        task.* = .{
            .backend = backend,
            .context = context_copy,
            .start = start,
            // SAFETY: will be overwritten
            .state = undefined,
        };
        return task;
    }

    fn destroy(task: *GroupTask) void {
        const allocator = task.backend.allocator;
        task.context.destroy(allocator);
        allocator.destroy(task);
    }
};

const SpawnGroupError = error{ OutOfMemory, SystemResources };

fn getOrCreateGroupStateLocked(backend: *Threaded, group: *Io.Group) SpawnGroupError!struct {
    state: *GroupState,
    created: bool,
} {
    if (group.token.load(.acquire)) |token| {
        const state: *GroupState = @ptrCast(@alignCast(token));

        if (state.backend != backend)
            @panic("std.Io.Group used with multiple Io backends");

        return .{
            .state = state,
            .created = false,
        };
    }

    const state = backend.allocator.create(GroupState) catch return error.OutOfMemory;
    errdefer backend.allocator.destroy(state);

    const semaphore_id = kernel.sceKernelCreateSema("psvk-io-group\x00", 0, 0, 1, null);
    if (semaphore_id < 0)
        return error.SystemResources;

    state.* = .{
        .backend = backend,
        .semaphore_id = semaphore_id,
    };

    return .{
        .state = state,
        .created = true,
    };
}

fn removeGroupTaskLocked(state: *GroupState, task: *GroupTask) void {
    var previous: ?*GroupTask = null;
    var current = state.tasks;
    while (current) |candidate| {
        if (candidate == task) {
            if (previous) |item|
                item.group_next = candidate.group_next
            else
                state.tasks = candidate.group_next;

            candidate.group_next = null;
            return;
        }
        previous = candidate;
        current = candidate.group_next;
    }
    @panic("PS Vita Io group registry is corrupt");
}

fn spawnGroupTask(
    backend: *Threaded,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque) void,
) SpawnGroupError!void {
    const task = GroupTask.create(backend, context, context_alignment, start) catch return error.OutOfMemory;
    errdefer task.destroy();

    const thread_id = kernel.sceKernelCreateThread("psvk-io-group\x00", groupEntry, backend.options.thread_priority, backend.options.thread_stack_size, 0, backend.options.cpu_affinity_mask, null);

    if (thread_id < 0)
        return error.SystemResources;

    errdefer checkKernel(kernel.sceKernelDeleteThread(thread_id));

    backend.lock();
    const state_result = getOrCreateGroupStateLocked(backend, group) catch |err| {
        backend.unlock();
        return err;
    };
    const state = state_result.state;

    if (state.pending == 0)
        _ = kernel.sceKernelPollSema(state.semaphore_id, 1);

    task.state = state;
    task.group_next = state.tasks;
    state.tasks = task;
    state.pending += 1;

    if (state.cancel_requested)
        task.control.request();

    backend.addRunningLocked();

    var argument = task;
    const start_result = kernel.sceKernelStartThread(thread_id, @sizeOf(*GroupTask), @ptrCast(&argument));
    if (start_result < 0) {
        removeGroupTaskLocked(state, task);
        state.pending -= 1;
        backend.finishRunningLocked();
        backend.unlock();

        if (state_result.created) {
            checkKernel(kernel.sceKernelDeleteSema(state.semaphore_id));
            backend.allocator.destroy(state);
        }
        return error.SystemResources;
    }

    if (state_result.created) {
        group.token.store(state, .release);
        backend.group_state_count += 1;
    }
    backend.unlock();
}

fn groupEntry(argument_size: u32, argument_ptr: ?*anyopaque) callconv(.c) c_int {
    if (argument_size != @sizeOf(*GroupTask))
        return -1;

    const task = @as(*const *GroupTask, @ptrCast(@alignCast(argument_ptr orelse return -1))).*;
    const backend = task.backend;
    const state = task.state;

    backend.registerCurrent(&task.control);
    task.start(task.context.ptr);

    backend.lock();
    backend.removeCurrentLocked(&task.control);
    removeGroupTaskLocked(state, task);
    backend.unlock();

    task.destroy();

    backend.lock();
    std.debug.assert(state.pending > 0);
    state.pending -= 1;
    if (state.pending == 0) signalSemaphore(state.semaphore_id);
    backend.finishRunningLocked();
    backend.unlock();

    _ = kernel.sceKernelExitDeleteThread(0);
    return 0;
}

fn groupAsync(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const backend = backendFromUserdata(userdata);
    spawnGroupTask(backend, group, context, context_alignment, start) catch start(context.ptr);
}

fn groupConcurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    const backend = backendFromUserdata(userdata);
    spawnGroupTask(backend, group, context, context_alignment, start) catch return error.ConcurrencyUnavailable;
}

fn requestGroupCancellationLocked(state: *GroupState) void {
    state.cancel_requested = true;
    var task = state.tasks;
    while (task) |current| : (task = current.group_next)
        current.control.request();
}

fn destroyGroupState(group: *Io.Group, state: *GroupState) void {
    const backend = state.backend;
    backend.lock();
    std.debug.assert(state.pending == 0);
    std.debug.assert(state.tasks == null);
    const token = group.token.load(.acquire);
    std.debug.assert(token == @as(*anyopaque, @ptrCast(state)));
    group.token.store(null, .release);
    std.debug.assert(backend.group_state_count > 0);
    backend.group_state_count -= 1;
    backend.unlock();

    checkKernel(kernel.sceKernelDeleteSema(state.semaphore_id));
    backend.allocator.destroy(state);
}

fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) Io.Cancelable!void {
    const backend = backendFromUserdata(userdata);
    const state: *GroupState = @ptrCast(@alignCast(initial_token));

    if (state.backend != backend)
        @panic("std.Io.Group used with multiple Io backends");

    const parent = backend.currentControl();
    var canceled = false;

    while (true) {
        if (!canceled and parent != null and TaskControl.takeCancellation(parent.?)) {
            canceled = true;
            backend.lock();
            requestGroupCancellationLocked(state);
            backend.unlock();
        }

        backend.lock();
        const pending = state.pending;
        backend.unlock();

        if (pending == 0)
            break;

        var timeout_us = cancellation_poll_us;
        const wait_result = kernel.sceKernelWaitSema(state.semaphore_id, 1, &timeout_us);

        if (wait_result < 0 and wait_result != kernel.error_wait_timeout)
            @panic("sceKernelWaitSema failed");
    }

    if (!canceled and parent != null and TaskControl.takeCancellation(parent.?))
        canceled = true;

    destroyGroupState(group, state);

    if (canceled)
        return Io.Cancelable.Canceled;
}

fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) void {
    const backend = backendFromUserdata(userdata);
    const state: *GroupState = @ptrCast(@alignCast(initial_token));

    if (state.backend != backend)
        @panic("std.Io.Group used with multiple Io backends");

    backend.lock();
    requestGroupCancellationLocked(state);
    backend.unlock();

    while (true) {
        backend.lock();
        const pending = state.pending;
        backend.unlock();

        if (pending == 0)
            break;

        waitSemaphoreUncancelable(state.semaphore_id);
    }
    destroyGroupState(group, state);
}

fn crashHandler(userdata: ?*anyopaque) void {
    _ = userdata;
}

fn recancel(userdata: ?*anyopaque) void {
    const backend = backendFromUserdata(userdata);
    const control = backend.currentControl() orelse @panic("recancel called outside a PS Vita Io task");
    control.recancel();
}

fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const backend = backendFromUserdata(userdata);
    const control = backend.currentControl() orelse return .unblocked;
    const old = control.protection;
    control.protection = new;
    return old;
}

fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const backend = backendFromUserdata(userdata);
    const control = backend.currentControl() orelse return;

    if (TaskControl.takeCancellation(control))
        return Io.Cancelable.Canceled;
}

const Deadline = union(enum) {
    infinite,
    immediate,
    at: i96,
};

fn clockSupported(clock: Io.Clock) bool {
    return clock == .awake or clock == .boot;
}

fn monotonicNanoseconds() i96 {
    return @as(i96, kernel.sceKernelGetSystemTimeWide()) * nanoseconds_per_microsecond;
}

fn timeoutDeadline(timeout: Io.Timeout) Deadline {
    return switch (timeout) {
        .none => .infinite,
        .duration => |duration| if (!clockSupported(duration.clock) or duration.raw.nanoseconds <= 0)
            .immediate
        else
            .{ .at = monotonicNanoseconds() +| duration.raw.nanoseconds },
        .deadline => |deadline| if (!clockSupported(deadline.clock))
            .immediate
        else
            .{ .at = deadline.raw.nanoseconds },
    };
}

fn remainingNanoseconds(deadline: Deadline) ?i96 {
    return switch (deadline) {
        .infinite => null,
        .immediate => 0,
        .at => |timestamp| @max(timestamp - monotonicNanoseconds(), 0),
    };
}

fn delaySlice(deadline: Deadline) void {
    const delay_us: u32 = if (remainingNanoseconds(deadline)) |remaining_ns| delay: {
        if (remaining_ns <= 0)
            return;

        const bounded_ns = @min(remaining_ns, @as(i96, cancellation_poll_us) * nanoseconds_per_microsecond);
        break :delay @intCast(@divTrunc(bounded_ns + nanoseconds_per_microsecond - 1, nanoseconds_per_microsecond));
    } else cancellation_poll_us;

    checkKernel(kernel.sceKernelDelayThread(@max(delay_us, 1)));
}

const FutexWaiter = struct {
    address: *const u32,
    semaphore_id: kernel.Uid,
    next: ?*FutexWaiter = null,
    registered: bool = false,
};

fn removeFutexWaiterLocked(backend: *Threaded, waiter: *FutexWaiter) void {
    if (!waiter.registered)
        return;

    var previous: ?*FutexWaiter = null;
    var current = backend.futex_waiters;

    while (current) |candidate| {
        if (candidate == waiter) {
            if (previous) |item|
                item.next = candidate.next
            else
                backend.futex_waiters = candidate.next;

            waiter.next = null;
            waiter.registered = false;
            return;
        }
        previous = candidate;
        current = candidate.next;
    }

    @panic("PS Vita Io futex registry is corrupt");
}

fn futexPollingWait(backend: *Threaded, ptr: *const u32, expected: u32, deadline: Deadline, cancelable: bool) Io.Cancelable!void {
    while (@atomicLoad(u32, ptr, .monotonic) == expected) {
        if (cancelable)
            try checkCancel(backend);

        if (remainingNanoseconds(deadline)) |remaining| {
            if (remaining <= 0)
                return;
        }

        delaySlice(deadline);
    }
}

fn futexWaitInner(backend: *Threaded, ptr: *const u32, expected: u32, deadline: Deadline, cancelable: bool) Io.Cancelable!void {
    if (cancelable)
        try checkCancel(backend);

    if (@atomicLoad(u32, ptr, .monotonic) != expected)
        return;

    if (remainingNanoseconds(deadline)) |remaining| {
        if (remaining <= 0)
            return;
    }

    const semaphore_id = kernel.sceKernelCreateSema("psvk-io-futex\x00", 0, 0, 1, null);

    if (semaphore_id < 0)
        return futexPollingWait(backend, ptr, expected, deadline, cancelable);

    defer checkKernel(kernel.sceKernelDeleteSema(semaphore_id));

    var waiter: FutexWaiter = .{ .address = ptr, .semaphore_id = semaphore_id };
    backend.lock();

    if (@atomicLoad(u32, ptr, .monotonic) != expected) {
        backend.unlock();
        return;
    }

    waiter.next = backend.futex_waiters;
    waiter.registered = true;
    backend.futex_waiters = &waiter;
    backend.unlock();

    defer {
        backend.lock();
        removeFutexWaiterLocked(backend, &waiter);
        backend.unlock();
    }

    const current = if (cancelable) backend.currentControl() else null;
    while (true) {
        if (cancelable and current != null and TaskControl.takeCancellation(current.?))
            return Io.Cancelable.Canceled;

        if (remainingNanoseconds(deadline)) |remaining| {
            if (remaining <= 0)
                return;
        }

        var timeout_us: u32 = cancellation_poll_us;
        if (remainingNanoseconds(deadline)) |remaining| {
            const bounded_ns = @min(remaining, @as(i96, cancellation_poll_us) * nanoseconds_per_microsecond);
            timeout_us = @intCast(@divTrunc(bounded_ns + nanoseconds_per_microsecond - 1, nanoseconds_per_microsecond));
        }

        const wait_result = if (!cancelable and deadline == .infinite)
            kernel.sceKernelWaitSema(semaphore_id, 1, null)
        else
            kernel.sceKernelWaitSema(semaphore_id, 1, &timeout_us);

        if (wait_result >= 0)
            return;

        if (wait_result != kernel.error_wait_timeout)
            return;

        if (@atomicLoad(u32, ptr, .monotonic) != expected)
            return;
    }
}

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const backend = backendFromUserdata(userdata);
    return futexWaitInner(backend, ptr, expected, timeoutDeadline(timeout), true);
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const backend = backendFromUserdata(userdata);
    futexWaitInner(backend, ptr, expected, .infinite, false) catch @panic("uncancellable futex wait failed");
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    const backend = backendFromUserdata(userdata);
    backend.lock();
    defer backend.unlock();

    var remaining = max_waiters;
    var previous: ?*FutexWaiter = null;
    var current = backend.futex_waiters;

    while (current) |waiter| {
        const next = waiter.next;
        if (remaining != 0 and waiter.address == ptr) {
            if (previous) |item|
                item.next = next
            else
                backend.futex_waiters = next;

            waiter.next = null;
            waiter.registered = false;
            signalSemaphore(waiter.semaphore_id);
            remaining -= 1;
        } else {
            previous = waiter;
        }
        current = next;
    }
}

fn batchAwaitAsync(userdata: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
    try checkCancel(userdata);

    var completed_tail = batch.completed.tail;
    defer batch.completed.tail = completed_tail;

    var index = batch.submitted.head;
    errdefer batch.submitted.head = index;

    while (index != .none) {
        const storage = &batch.storage[index.toIndex()];
        const next = storage.submission.node.next;
        const operation_result = try Io.failing.vtable.operate(null, storage.submission.operation);

        switch (completed_tail) {
            .none => batch.completed.head = index,
            else => |tail| batch.storage[tail.toIndex()].completion.node.next = index,
        }

        storage.* = .{
            .completion = .{
                .node = .{ .next = .none },
                .result = operation_result,
            },
        };

        completed_tail = index;
        index = next;

        if (index != .none)
            try checkCancel(userdata);
    }

    batch.submitted = .empty;
}

fn batchAwaitConcurrent(_: ?*anyopaque, _: *Io.Batch, _: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    return Io.Batch.AwaitConcurrentError.ConcurrencyUnavailable;
}

fn batchCancel(_: ?*anyopaque, batch: *Io.Batch) void {
    std.debug.assert(batch.pending.head == .none and batch.pending.tail == .none);
    std.debug.assert(batch.userdata == null);
}

fn now(_: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    if (!clockSupported(clock))
        return .zero;
    return .{ .nanoseconds = monotonicNanoseconds() };
}

fn clockResolution(_: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    if (!clockSupported(clock))
        return error.ClockUnavailable;
    return .fromMicroseconds(1);
}

fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const backend = backendFromUserdata(userdata);
    const deadline = timeoutDeadline(timeout);

    while (true) {
        try checkCancel(backend);
        if (remainingNanoseconds(deadline)) |remaining| {
            if (remaining <= 0)
                return;
        }
        delaySlice(deadline);
    }
}

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    const backend = backendFromUserdata(userdata);
    backend.lock();
    defer backend.unlock();

    var state = backend.random_state;
    for (buffer) |*byte| {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        byte.* = @truncate((state *% 0x2545f4914f6cdd1d) >> 56);
    }
    backend.random_state = state;
}

fn waitSemaphoreUncancelable(semaphore_id: kernel.Uid) void {
    checkKernel(kernel.sceKernelWaitSema(semaphore_id, 1, null));
}

fn signalSemaphore(semaphore_id: kernel.Uid) void {
    checkKernel(kernel.sceKernelSignalSema(semaphore_id, 1));
}

fn checkKernel(result: c_int) void {
    if (result < 0)
        @panic("PS Vita kernel operation failed");
}
