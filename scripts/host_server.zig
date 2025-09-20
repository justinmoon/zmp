const std = @import("std");

var counter = std.atomic.Value(u64).init(0);

fn writeResponse(stream: *std.net.Stream, body: []const u8) void {
    var header_buf: [200]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ body.len },
    ) catch return;
    _ = stream.writeAll(header) catch return;
    _ = stream.writeAll(body) catch {};
}

fn handleConnection(conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    var buf: [4096]u8 = undefined;
    const n = conn.stream.read(&buf) catch return;
    if (n == 0) return;
    const req = buf[0..n];
    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, req, ' ')) |sp1| {
        const off = sp1 + 1;
        if (off < req.len) {
            const rest = req[off..];
            if (std.mem.indexOfScalar(u8, rest, ' ')) |sp2| {
                path = rest[0..sp2];
            } else {
                path = rest;
            }
        }
    }

    const count: u64 = if (std.mem.eql(u8, path, "/inc"))
        counter.fetchAdd(1, .acq_rel) + 1
    else
        counter.load(.acquire);

    const body = std.fmt.allocPrint(
        std.heap.page_allocator,
        "<!doctype html>\n" ++
            "<html><head><meta charset=\"utf-8\"><title>ZMP Counter</title></head>\n" ++
            "<body style=\"font-family: sans-serif; padding: 24px;\">\n" ++
            "<h1>ZMP Counter (Host Mode)</h1>\n" ++
            "<p id=\"count\">Count: {d}</p>\n" ++
            "<a href=\"/inc\" style=\"display:inline-block;margin-top:16px;\">Increment</a>\n" ++
            "</body></html>",
        .{ count },
    ) catch return;
    defer std.heap.page_allocator.free(body);

    const stream_ptr = @constCast(&conn.stream);
    writeResponse(stream_ptr, body);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const port_arg = args.next() orelse "8085";
    const port = std.fmt.parseUnsigned(u16, port_arg, 10) catch 8085;

    var server = try std.net.Address.listen(
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port),
        .{ .reuse_address = true },
    );
    defer server.deinit();

    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("host server accept failed: {s}", .{ @errorName(err) });
            continue;
        };
        handleConnection(conn);
    }
}
