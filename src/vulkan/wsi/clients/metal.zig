//! Minimal Metal/Objective-C client used by the Apple WSI backend

const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../../lib.zig");

const VkError = lib.VkError;

pub const id = *anyopaque;
pub const SEL = usize;

pub const storage_mode_shared: usize = 0;

const Size = extern struct {
    width: usize,
    height: usize,
    depth: usize,
};

const Origin = extern struct {
    x: usize,
    y: usize,
    z: usize,
};

const CGSize = extern struct {
    width: f64,
    height: f64,
};

const CGPoint = extern struct {
    x: f64,
    y: f64,
};

const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

var objc_msgSend: *const fn (id, SEL) callconv(.c) ?id = undefined;
var objc_msgSend_stret: *const fn (*CGRect, id, SEL) callconv(.c) void = undefined;
pub var objc_autoreleasePoolPush: *const fn () callconv(.c) *anyopaque = undefined;
pub var objc_autoreleasePoolPop: *const fn (*anyopaque) callconv(.c) void = undefined;
var sel_registerName: *const fn ([*:0]const u8) callconv(.c) SEL = undefined;

const objc_msgSend0_void = *const fn (id, SEL) callconv(.c) void;
const objc_msgSend1_void = *const fn (id, SEL, id) callconv(.c) void;
const objc_msgSend2_id = *const fn (id, SEL, usize, usize) callconv(.c) ?id;
const objc_msgSend_copy = *const fn (id, SEL, id, usize, usize, usize, Size, id, usize, usize, Origin) callconv(.c) void;
const objc_msgSend1_size = *const fn (id, SEL, CGSize) callconv(.c) void;

const mtl_create_system_default_device = *const fn () callconv(.c) ?id;

var sel_nextDrawable: SEL = undefined;
var sel_texture: SEL = undefined;
var sel_newCommandQueue: SEL = undefined;
var sel_commandBuffer: SEL = undefined;
var sel_commit: SEL = undefined;
var sel_blitCommandEncoder: SEL = undefined;
var sel_copyFromBuffer: SEL = undefined;
var sel_endEncoding: SEL = undefined;
var sel_presentDrawable: SEL = undefined;
var sel_waitUntilCompleted: SEL = undefined;
var sel_release: SEL = undefined;
var sel_retain: SEL = undefined;
var sel_contents: SEL = undefined;
var sel_setFramebufferOnly: SEL = undefined;
var sel_newBuffer: SEL = undefined;
var sel_setDevice: SEL = undefined;
var sel_setDrawableSize: SEL = undefined;
var sel_bounds: SEL = undefined;
var sel_contentsScale: SEL = undefined;
var sel_width: SEL = undefined;
var sel_height: SEL = undefined;

var objc_lib: std.DynLib = undefined;
var metal_lib: std.DynLib = undefined;
var ref_count = std.atomic.Value(usize).init(0);
var load_mutex: lib.SpinMutex = .{};

const objc_runtime_path = "/usr/lib/libobjc.A.dylib";
const metal_framework_path = "/System/Library/Frameworks/Metal.framework/Metal";

fn runtimeSymbol(comptime T: type, comptime name: [:0]const u8) VkError!T {
    return objc_lib.lookup(T, name) orelse {
        std.log.scoped(.Metal).err("Could not resolve Objective-C runtime symbol '{s}'", .{name});
        return VkError.InitializationFailed;
    };
}

pub fn load() VkError!void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.load(.monotonic) != 0) {
        _ = ref_count.fetchAdd(1, .monotonic);
        return;
    }

    objc_lib = std.DynLib.open(objc_runtime_path) catch {
        std.log.scoped(.Metal).err("Could not open the Objective-C runtime", .{});
        return VkError.InitializationFailed;
    };
    errdefer objc_lib.close();

    objc_msgSend = try runtimeSymbol(@TypeOf(objc_msgSend), "objc_msgSend");
    sel_registerName = try runtimeSymbol(@TypeOf(sel_registerName), "sel_registerName");
    objc_autoreleasePoolPush = try runtimeSymbol(@TypeOf(objc_autoreleasePoolPush), "objc_autoreleasePoolPush");
    objc_autoreleasePoolPop = try runtimeSymbol(@TypeOf(objc_autoreleasePoolPop), "objc_autoreleasePoolPop");

    if (comptime @import("builtin").cpu.arch == .x86_64)
        objc_msgSend_stret = try runtimeSymbol(@TypeOf(objc_msgSend_stret), "objc_msgSend_stret");

    metal_lib = std.DynLib.open(metal_framework_path) catch {
        std.log.scoped(.Metal).err("Could not open the Metal framework", .{});
        return VkError.InitializationFailed;
    };
    errdefer metal_lib.close();

    if (metal_lib.lookup(mtl_create_system_default_device, "MTLCreateSystemDefaultDevice") == null) {
        std.log.scoped(.Metal).err("Could not resolve MTLCreateSystemDefaultDevice", .{});
        return VkError.InitializationFailed;
    }

    sel_nextDrawable = sel_registerName("nextDrawable");
    sel_texture = sel_registerName("texture");
    sel_newCommandQueue = sel_registerName("newCommandQueue");
    sel_commandBuffer = sel_registerName("commandBuffer");
    sel_commit = sel_registerName("commit");
    sel_blitCommandEncoder = sel_registerName("blitCommandEncoder");
    sel_copyFromBuffer = sel_registerName("copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:");
    sel_endEncoding = sel_registerName("endEncoding");
    sel_presentDrawable = sel_registerName("presentDrawable:");
    sel_waitUntilCompleted = sel_registerName("waitUntilCompleted");
    sel_release = sel_registerName("release");
    sel_retain = sel_registerName("retain");
    sel_contents = sel_registerName("contents");
    sel_setFramebufferOnly = sel_registerName("setFramebufferOnly:");
    sel_newBuffer = sel_registerName("newBufferWithLength:options:");
    sel_setDevice = sel_registerName("setDevice:");
    sel_setDrawableSize = sel_registerName("setDrawableSize:");
    sel_bounds = sel_registerName("bounds");
    sel_contentsScale = sel_registerName("contentsScale");
    sel_width = sel_registerName("width");
    sel_height = sel_registerName("height");

    _ = ref_count.fetchAdd(1, .monotonic);
    std.log.scoped(.Metal).debug("Loaded Metal", .{});
}

pub fn unload() void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.fetchSub(1, .release) == 1) {
        metal_lib.close();
        objc_lib.close();
        std.log.scoped(.Metal).debug("Unloaded Metal", .{});
    }
}

pub fn systemDefaultDevice() ?id {
    const pfn = metal_lib.lookup(mtl_create_system_default_device, "MTLCreateSystemDefaultDevice") orelse return null;
    return pfn();
}

pub fn newCommandQueue(object: id) ?id {
    return objc_msgSend(object, sel_newCommandQueue);
}

pub fn newBuffer(object: id, length: usize, options: usize) ?id {
    const call: objc_msgSend2_id = @ptrCast(objc_msgSend);
    return call(object, sel_newBuffer, length, options);
}

pub fn nextDrawable(layer: id) ?id {
    const drawable = objc_msgSend(layer, sel_nextDrawable) orelse return null;
    return objc_msgSend(drawable, sel_retain);
}

pub fn drawableTexture(drawable: id) ?id {
    return objc_msgSend(drawable, sel_texture);
}

pub fn newCommandBuffer(queue: id) ?id {
    const command_buffer = objc_msgSend(queue, sel_commandBuffer) orelse return null;
    return objc_msgSend(command_buffer, sel_retain);
}

pub fn blitCommandEncoder(command_buffer: id) ?id {
    return objc_msgSend(command_buffer, sel_blitCommandEncoder);
}

pub fn copyFromBufferToTexture(blit: id, buffer: id, texture: id, source_bytes_per_row: usize, source_bytes_per_image: usize, width: usize, height: usize) void {
    const call: objc_msgSend_copy = @ptrCast(objc_msgSend);
    call(blit, sel_copyFromBuffer, buffer, 0, source_bytes_per_row, source_bytes_per_image, .{ .width = width, .height = height, .depth = 1 }, texture, 0, 0, .{ .x = 0, .y = 0, .z = 0 });
}

pub fn commit(command_buffer: id) void {
    const call: objc_msgSend0_void = @ptrCast(objc_msgSend);
    call(command_buffer, sel_commit);
}

pub fn endEncoding(encoder: id) void {
    const call: objc_msgSend0_void = @ptrCast(objc_msgSend);
    call(encoder, sel_endEncoding);
}

pub fn presentDrawable(command_buffer: id, drawable: id) void {
    const call: objc_msgSend1_void = @ptrCast(objc_msgSend);
    call(command_buffer, sel_presentDrawable, drawable);
}

pub fn waitUntilCompleted(command_buffer: id) void {
    const call: objc_msgSend0_void = @ptrCast(objc_msgSend);
    call(command_buffer, sel_waitUntilCompleted);
}

pub fn release(object: id) void {
    const call: objc_msgSend0_void = @ptrCast(objc_msgSend);
    call(object, sel_release);
}

pub fn contents(buffer: id) ?*anyopaque {
    return objc_msgSend(buffer, sel_contents);
}

pub fn setFramebufferOnly(layer: id, framebuffer_only: bool) void {
    const call: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(objc_msgSend);
    call(layer, sel_setFramebufferOnly, framebuffer_only);
}

pub fn setDevice(object: id, device: id) void {
    const call: objc_msgSend1_void = @ptrCast(objc_msgSend);
    call(object, sel_setDevice, device);
}

pub fn naturalExtent(layer: id) vk.Extent2D {
    const bounds = if (comptime @import("builtin").cpu.arch == .x86_64) blk: {
        var rect: CGRect = undefined;
        objc_msgSend_stret(&rect, layer, sel_bounds);
        break :blk rect;
    } else blk: {
        const call: *const fn (id, SEL) callconv(.c) CGRect = @ptrCast(objc_msgSend);
        break :blk call(layer, sel_bounds);
    };

    const get_scale: *const fn (id, SEL) callconv(.c) f64 = @ptrCast(objc_msgSend);
    const scale = get_scale(layer, sel_contentsScale);

    return .{
        .width = pixelDimension(bounds.size.width, scale),
        .height = pixelDimension(bounds.size.height, scale),
    };
}

fn pixelDimension(points: f64, scale: f64) u32 {
    const pixels = @round(points * scale);
    if (!std.math.isFinite(pixels) or pixels <= 0)
        return 0;

    // UINT32_MAX is reserved for Vulkan's undefined-current-extent sentinel
    return @intFromFloat(@min(pixels, std.math.maxInt(u32) - 1));
}

pub fn textureExtent(texture: id) vk.Extent2D {
    const call: *const fn (id, SEL) callconv(.c) usize = @ptrCast(objc_msgSend);
    return .{
        .width = @intCast(call(texture, sel_width)),
        .height = @intCast(call(texture, sel_height)),
    };
}

pub fn setDrawableSize(object: id, width: f64, height: f64) void {
    const call: objc_msgSend1_size = @ptrCast(objc_msgSend);
    call(object, sel_setDrawableSize, .{ .width = width, .height = height });
}
