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
    fn deinit(self: *Request_vec, io: std.Io, allocator: std.mem.Allocator) void {
        allocator.free(self.requests);
        allocator.free(self.data);
        self.connection.close(io);
    }
};

const getMsg_error = error{ LimitedAllocError, TooShortPacket, OutOfMemory, ReadFailed, StreamTooLong } || std.Io.Cancelable;

fn getMsg(io: std.Io, allocator: std.mem.Allocator, connection: std.Io.net.Stream, flag: *u32) getMsg_error!Request_vec {
    errdefer connection.close(io);
    var buf_reader: [16384]u8 = undefined;
    var reader = connection.reader(io, &buf_reader);
    const msg = try reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(msg);
    if (msg.len < 8) {
        return getMsg_error.TooShortPacket;
    }
    const requests_count = std.mem.readInt(u64, msg[0..8], .little);
    const requests_msg = msg[8..];
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
    io.futexWaitTimeout(u32, &flag, 0, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch return;
    const res: Request_vec = future.cancel(io) catch |err| {
        switch (err) {
            getMsg_error.Canceled => {},
            else => std.log.err("error:{}\n", .{err}),
        }
        return;
    };
    queue_mutext.lock(io) catch return;
    defer queue_mutext.unlock(io);
    queue.pushBack(allocator, res) catch |err| std.log.err("error:{}", .{err});
    io.futexWake(usize, &queue.len, 1);
}

const serverThread_id: u32 = 1 << 0;
fn serverThread(io: std.Io, allocator: std.mem.Allocator, queue: *std.Deque(Request_vec), queue_mutex: *std.Io.Mutex, thread_table: *u32) void {
    defer {
        thread_table.* &= ~serverThread_id;
        io.futexWake(u32, thread_table, 1);
    }
    const port = 44099;
    const address = std.Io.net.IpAddress{ .ip4 = .unspecified(port) };
    var server = address.listen(io, .{ .mode = .stream, .protocol = .tcp, .reuse_address = true }) catch |err| {
        switch (err) {
            error.Canceled => {},
            else => std.log.err("error:{}", .{err}),
        }
        return;
    };
    defer server.deinit(io);
    var group = std.Io.Group.init;
    defer group.cancel(io);
    while (true) {
        const connection = server.accept(io) catch |err| {
            switch (err) {
                error.Canceled => return,
                else => continue,
            }
        };
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

fn request_processor(io: std.Io, allocator: std.mem.Allocator, messages: *std.ArrayList(Message), requests: Request_vec) (error{OutOfMemory} || std.Io.Writer.Error || error{IncorrectRequest})!void {
    var response = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer response.deinit(allocator);
    for (requests.requests) |request| {
        switch (request.type) {
            .get_info => |req| switch (req) {
                .msg_count => {
                    const res: u64 = @intCast(messages.items.len);
                    try response.appendSlice(allocator, &@as([8]u8, @bitCast(res)));
                },
            },
            .get_msg => |req| {
                const msgs = try getMessages(allocator, messages, req);
                defer allocator.free(msgs);
                try response.appendSlice(allocator, &@as([8]u8, @bitCast(@as(u64, @intCast(msgs.len)))));
                var cur_offset: u64 = 0;
                for (msgs) |msg| {
                    try response.appendSlice(allocator, &@as([8]u8, @bitCast(cur_offset)));
                    cur_offset += @intCast(msg.len);
                }
                for (msgs) |msg| {
                    try response.appendSlice(allocator, msg);
                }
            },
            .send_msg => |req| {
                const msg_text = try allocator.dupe(u8, request.data orelse return error.IncorrectRequest);
                const msg = Message{ .data = msg_text, .chat_id = req.chat_id };
                try messages.append(allocator, msg);
            },
        }
    }

    var writer = requests.connection.writer(io, &.{});
    _ = try writer.interface.write(response.items);
    allocator.free(requests.requests);
}
const request_processor_thread_id: u32 = 1 << 1;
fn request_processor_thread(io: std.Io, allocator: std.mem.Allocator, queue: *std.Deque(Request_vec), queue_mutex: *std.Io.Mutex, messages: *std.ArrayList(Message), thread_table: *u32) void {
    defer {
        thread_table.* &= ~request_processor_thread_id;
        io.futexWake(u32, thread_table, 1);
    }
    while (true) {
        io.futexWait(usize, &queue.len, 0) catch return;
        queue_mutex.lock(io) catch return;
        var requests = queue.popBack().?;
        defer requests.deinit(io, allocator);
        queue_mutex.unlock(io);
        request_processor(io, allocator, messages, requests) catch return;
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
    var messages = try std.ArrayList(Message).initCapacity(allocator, 512);
    defer allocator.free(messages);
    defer queue.deinit(allocator);

    const work_thread_table = serverThread_id | request_processor_thread_id;
    var thread_table = work_thread_table;
    var server = io.async(serverThread, .{ io, allocator, &queue, &queue_mutex, &thread_table });
    defer server.cancel(io);
    var request_processorThread = io.async(request_processor_thread, .{ io, allocator, &queue, &queue_mutex, &messages, &thread_table });
    defer request_processorThread.cancel(io);
    try io.futexWait(u32, &thread_table, work_thread_table);
}
