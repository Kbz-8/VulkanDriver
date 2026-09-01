const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{
    MissingEntryPoint,
    MissingWorkgroupSize,
    InvalidModule,
    UnsupportedStage,
    UnsupportedType,
    UnsupportedOperation,
    UnstructuredControlFlow,
    RegisterAllocationFailed,
    EncodingFailed,
    BranchOutOfRange,
    CodeGenerationNotImplemented,
};
