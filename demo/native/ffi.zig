const std = @import("std");

pub export fn getauxval(tag: usize) callconv(.c) usize {
    _ = tag;
    return 0;
}

pub export fn Java_com_example_demo_Native_getNumber(env: ?*anyopaque, clazz: ?*anyopaque) callconv(.c) i32 {
    _ = env;
    _ = clazz;
    return 42;
}

pub export fn Java_com_example_demo_Native_startServer(env: ?*anyopaque, clazz: ?*anyopaque, port: i32) callconv(.c) void {
    _ = env;
    _ = clazz;
    _ = port;
}
