const std = @import("std");
const Message = struct {
    chat_id: u64,
    data: []u8,
};
var should_exit = false;
fn handleSigInt(sig: std.os.linux.SIG) callconv(.c) void {
    _ = sig;
    should_exit = true;
}

const Msg_range = union(enum(u8)) {
    all: void,
    latest: struct { limit: u64 },
    range: struct {
        is_rev: bool,
        start: u64,
        end: u64,
    },
};

const Msgs_target = struct {
    chat_id: u64,
    mode: Msg_range,
};

const Request_type = union(enum(u8)) {
    send_msg: struct {
        chat_id: u64,
        len: u64,
    },
    get_msg: Msgs_target,
    get_info: union(enum(u8)) {
        msg_count: void,
    },
};

const Request = struct {
    type: Request_type,
    data: ?[]u8,
};
const Request_vec = struct {
    requests: []Request,
    data: []u8,
    connection: std.Io.net.Stream,
};

const getMsg_error = error{ LimitedAllocError, TooShortPacket, Cancelable, OutOfMemory };

fn getMsg(io: std.Io, allocator: std.mem.Allocator, connection: std.Io.net.Stream, flag: *u32) getMsg_error!Request_vec {
    errdefer connection.close(io);
    var buf_reader: [4096]u8 = undefined;
    var reader = connection.reader(io, &buf_reader);
    const msg = try reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(msg);
    if (msg.len < 2) {
        try error{TooShortPacket};
    }
    const requests_count = @as(u16, @bitCast(msg[0..2]));
    const requests_msg = msg[2..];
    if (requests_msg.len < requests_count * @sizeOf(Request_type)) {
        return error{TooShortPacket};
    }
    const requests = @as([]Request_type, requests_msg[0 .. requests_count * @sizeOf(Request_type)]);
    var data = requests_msg[requests_count * @sizeOf(Request_type) ..];
    var res_requests = try allocator.alloc(Request, requests_count);
    for (requests, 0..) |request, i| {
        const cur_buf = switch (request) {
            .send_msg => |cur| curp: {
                const cur_b = data[0..cur.len];
                data = data[cur.len..];
                break :curp cur_b;
            },
            else => null,
        };
        res_requests[i] = Request{ .type = request, .data = cur_buf };
    }
    flag.* = 1;
    io.futexWake(u32, flag, 1);
    return .{ .requests = res_requests, .data = msg, .connection = connection };
}

fn connection_handler(io: std.Io, allocator: std.mem.Allocator, connection: std.Io.net.Stream, queue: *std.Deque(Request_vec), queue_mutext: *std.Io.Mutex) void {
    var flag: u32 = 0;
    var future = io.async(getMsg, .{ io, allocator, connection, &flag });
    io.futexWaitTimeout(u32, &flag, 0, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    const res: Request_vec = future.cancel(io) catch |err| {
        switch (err) {
            getMsg_error.Cancelable => {},
            else => std.log.err("error:{}\n", err),
        }
        return;
    };
    queue_mutext.lock(io);
    defer queue_mutext.unlock(io);
    queue.pushBack(allocator, res);
}

const serverThread_id: u32 = 1 << 0;
fn serverThread(io: std.Io, allocator: std.mem.Allocator, queue: *std.Deque(Request_vec), queue_mutex: *std.Io.Mutex, thread_table: *u32) !void {
    defer {
        thread_table &= ~serverThread_id;
        io.futexWake(u32, thread_table, 1);
    }
    const port = 44099;
    const address = std.Io.net.IpAddress{ .ip4 = .unspecified(port) };
    var server = try address.listen(io, .{ .mode = .stream, .protocol = .tcp, .reuse_address = true });
    var group = std.Io.Group.init;
    while (true) {
        const connection = try server.accept(io);
        group.async(io, connection_handler, .{ io, allocator, connection, queue, queue_mutex });
    }
}

fn getMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(Message), target: Msgs_target) error{OutOfMemory}![][]u8 {
    const chat_id = target.chat_id;
    switch (target.mode) {
        .all => {
            var res = try std.ArrayList([]u8).initCapacity(allocator, 64);
            errdefer res.deinit(allocator);
            for (messages.items) |msg| {
                if (msg.chat_id == chat_id) {
                    try res.append(allocator, msg.data);
                }
            }
            return try res.toOwnedSlice(allocator);
        },
        .latest => |mode| {
            return getMessages(allocator, messages, .{
                .chat_id = target.chat_id,
                .mode = .{
                    .range = .{
                        .is_rev = true,
                        .start = 0,
                        .end = mode.limit,
                    },
                },
            });
        },
        .range => |mode| {
            var res = try std.ArrayList([]u8).initCapacity(allocator, 64);
            errdefer res.deinit(allocator);
            if (mode.is_rev) {
                var cur: usize = 0;
                var i = messages.items.len -% 1;
                while (cur < mode.start and i < messages.items.len) : (i -%= 1) {
                    cur += @intFromBool(messages.items[i].chat_id == chat_id);
                }
                while (cur < mode.end and i < messages.items.len) : (i -%= 1) {
                    if (messages.items[i].chat_id == chat_id) {
                        cur += 1;
                        try res.append(allocator, messages.items[i].data);
                    }
                }
                std.mem.reverse([]u8, res.items);
                return try res.toOwnedSlice(allocator);
            }
            var cur: usize = 0;
            var i: usize = 0;
            while (cur < mode.start and i < messages.items.len) : (i += 1) {
                cur += @intFromBool(messages.items[i].chat_id == chat_id);
            }
            while (cur < mode.end and i < messages.items.len) : (i += 1) {
                if (messages.items[i].chat_id == chat_id) {
                    cur += 1;
                    try res.append(allocator, messages.items[i].data);
                }
            }
            return try res.toOwnedSlice(allocator);
        },
    }
}

// Формат ответа:
// n: u64 = количество ответов
// _: [n]u64 = сдвиги ответов
// _: [_]u8 = данные ответов по сдвигам
// для сообщений схема аналогичная относительно начала ответа

fn request_processor(io: std.Io, allocator: std.mem.Allocator, thread_table: *u32, queue: *std.Deque(Request_vec), queue_mutex: *std.Io.Mutex, messages: *std.ArrayList(Message), requests: Request_vec) !void {
    defer allocator.free(requests.data);
    defer requests.connection.close(io);
    var response = try std.ArrayList(u8).initCapacity(allocator, 64);
    for (requests.requests) |request| {
        switch (request.type) {
            .get_info => |req| switch (req) {
                .msg_count => {
                    const res: u64 = @intCast(messages.items.len);
                    try response.appendSlice(allocator, @bitCast(res));
                },
            },
            .get_msg => |req| {
                const msgs = try getMessages(allocator, messages, req);
                response.appendSlice(allocator, @bitCast(@as(u64, @intCast(msgs.len))));
                var cur_offset: u64 = 0;
                for (msgs) |msg| {
                    response.appendSlice(allocator, @bitCast(cur_offset));
                    cur_offset += @intCast(msg.len);
                }
                for (msgs) |msg| {
                    response.appendSlice(allocator, msg);
                }
            },
            .send_msg => {},
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    const io = init.io;
    var stdout = std.Io.File.stdout().writer(io, &.{});
    const writer = &stdout.interface;
    _ = writer;
    const allocator = std.heap.smp_allocator;

    var queue_mutex = std.Io.Mutex.init;
    var queue = try std.Deque(Request_vec).initCapacity(allocator, 64);

    // for (messages.items) |*msg| {}
    // try writer.print("end\n", .{});
}
