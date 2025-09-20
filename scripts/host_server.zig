const std = @import("std");

const index_template = @embedFile("static/index.html");
const count_placeholder = "{{COUNT}}";

const placeholder_index = std.mem.indexOf(u8, index_template, count_placeholder) orelse
    @compileError("static/index.html must contain {{COUNT}} placeholder");
const html_prefix = index_template[0..placeholder_index];
const html_suffix = index_template[placeholder_index + count_placeholder.len ..];
const max_count_digits = 20;
const max_body_len = html_prefix.len + html_suffix.len + max_count_digits;

var counter = std.atomic.Value(u64).init(0);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const port_str = args.next() orelse "8085";
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch 8085;

    counter.store(0, .release);

    var server = try std.net.Address.listen(
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port),
        .{ .reuse_address = true },
    );
    defer server.deinit();

    std.log.info("host server listening on 127.0.0.1:{d}", .{port});

    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("host server accept failed: {s}", .{@errorName(err)});
            continue;
        };
        handleConn(conn);
    }
}

fn handleConn(conn: std.net.Server.Connection) void {
    var stream = conn.stream;
    defer stream.close();

    var buf: [4096]u8 = undefined;
    const n = stream.read(&buf) catch |err| {
        std.log.err("read failed: {s}", .{@errorName(err)});
        return;
    };
    if (n == 0) return;

    const request = buf[0..n];
    const path = parsePath(request);

    const is_root = std.mem.eql(u8, path, "/");
    const is_increment = std.mem.eql(u8, path, "/inc");
    const is_decrement = std.mem.eql(u8, path, "/dec");

    if (!is_root and !is_increment and !is_decrement) {
        sendStatus(&stream, 404, "Not Found", "text/plain; charset=utf-8", "not found");
        return;
    }

    const count: u64 = if (is_increment)
        increment()
    else if (is_decrement)
        decrement()
    else
        counter.load(.acquire);

    var body_buf: [max_body_len]u8 = undefined;
    const body = renderCount(count, &body_buf) catch |err| {
        std.log.err("render failed: {s}", .{@errorName(err)});
        return;
    };

    sendStatus(&stream, 200, "OK", "text/html; charset=utf-8", body);
}

fn renderCount(count: u64, buffer: []u8) ![]const u8 {
    var count_buf: [max_count_digits]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch return error.FormatFailed;

    const total = html_prefix.len + html_suffix.len + count_str.len;
    if (total > buffer.len) return error.BufferTooSmall;

    std.mem.copyForwards(u8, buffer[0..html_prefix.len], html_prefix);
    var idx: usize = html_prefix.len;
    std.mem.copyForwards(u8, buffer[idx .. idx + count_str.len], count_str);
    idx += count_str.len;
    std.mem.copyForwards(u8, buffer[idx .. idx + html_suffix.len], html_suffix);
    idx += html_suffix.len;

    return buffer[0..idx];
}

fn sendStatus(
    stream: *std.net.Stream,
    code: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
) void {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ code, reason, content_type, body.len },
    ) catch {
        std.log.err("header format failed", .{});
        return;
    };

    stream.writeAll(header) catch |err| {
        std.log.err("write header failed: {s}", .{@errorName(err)});
        return;
    };
    stream.writeAll(body) catch |err| {
        std.log.err("write body failed: {s}", .{@errorName(err)});
    };
}

fn parsePath(request: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, request, ' ')) |method_end| {
        const start = method_end + 1;
        if (start >= request.len) return "/";
        const rest = request[start..];
        if (std.mem.indexOfScalar(u8, rest, ' ')) |len| {
            return rest[0..len];
        }
        return rest;
    }
    return "/";
}

fn increment() u64 {
    return counter.fetchAdd(1, .acq_rel) + 1;
}

fn decrement() u64 {
    while (true) {
        const current = counter.load(.acquire);
        if (current == 0) return 0;
        if (counter.cmpxchgWeak(current, current - 1, .acq_rel, .acquire) == null) {
            return current - 1;
        }
    }
}
