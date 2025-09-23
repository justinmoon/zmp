const std = @import("std");

const AuxEntry = extern struct { tag: usize, value: usize };

fn readAux(tag: usize) usize {
    var file = std.fs.openFileAbsolute("/proc/self/auxv", .{}) catch return 0;
    defer file.close();
    var buf: [1024]u8 = undefined;
    var reader = file.reader(buf[0..]);
    while (true) {
        var entry: AuxEntry = undefined;
        const bytes = reader.read(std.mem.asBytes(&entry)) catch return 0;
        if (bytes != @sizeOf(AuxEntry)) return 0;
        if (entry.tag == tag) return entry.value;
        if (entry.tag == 0 and entry.value == 0) return 0;
    }
}

pub export fn getauxval(tag: usize) callconv(.c) usize {
    return readAux(tag);
}

pub export fn Java___JNI_PREFIX___Native_getNumberNative(env: ?*anyopaque, clazz: ?*anyopaque) callconv(.c) i32 {
    _ = env;
    _ = clazz;
    return 42;
}

pub export fn Java___JNI_PREFIX___Native_startServerNative(env: ?*anyopaque, clazz: ?*anyopaque, port: i32) callconv(.c) void {
    _ = env;
    _ = clazz;
    _ = port;
}
