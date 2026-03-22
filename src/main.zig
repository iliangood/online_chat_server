const std = @import("std");
const Messaege = struct {
    chat_id: u128,
    data: []u8,
};
var should_exit = false;
fn handleSigInt(sig: std.os.linux.SIG) callconv(.c) void {
    _ = sig;
    should_exit = true;
}

const Request_type = union(enum(u8)) {
    send_msg: struct {
        chat_id: u128,
        len: u64,
    },
    get_msg: struct {
        chat_id: u128,
        mode: union(enum(u8)) {
            all: void,
            latest: struct { limit: u64 },
            range: struct {
                is_rev: bool,
                start: u64,
                end: u64,
            },
        },
    },
    get_info: enum {
        msg_count,
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

fn getMsg(io: std.Io, allocator: std.mem.Allocator, connection: std.Io.net.Stream) !Request_vec {
    var buf_reader: [4096]u8 = undefined;
    var reader = connection.reader(io, &buf_reader);
    const msg = try reader.interface.allocRemaining(allocator, .unlimited);
    if (msg.len < 2) {
        return error{TooShortPacket};
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
    return .{ .requests = res_requests, .data = msg, .connection = connection };
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

    var messages = try std.ArrayList(Messaege).initCapacity(allocator, 64);
    _ = messages;
    const port: u16 = 44089;
    const address = std.Io.net.IpAddress{ .ip4 = .unspecified(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    while (!should_exit) {
        // server.accept(io: Io)
    }
    // for (messages.items) |*msg| {}
    // try writer.print("end\n", .{});
}
