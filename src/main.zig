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
    // _ = writer;
    const allocator = std.heap.smp_allocator;
    var messages = try std.ArrayList(Messaege).initCapacity(allocator, 64);

    const port: u16 = 44089;
    const address = std.Io.net.IpAddress{ .ip4 = .unspecified(port) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    while (!should_exit) {
        const connection = try server.accept(io);
        defer connection.close(io);
        try writer.print("connected:{f}\n", .{connection.socket.address});
        // var buffer: [1024]u8 = undefined;
        var reader = connection.reader(io, &.{});
        var id_buf: [16]u8 = undefined;
        if (try reader.interface.readSliceShort(&id_buf) != 16) {
            continue;
        }
        var message: Messaege = undefined;
        message.chat_id = std.mem.readInt(u128, &id_buf, .little);
        message.data = try reader.interface.allocRemaining(allocator, .unlimited);

        try messages.append(allocator, message);
        // try writer.print("msg:\"{s}\"\n", .{msg});
    }
    for (messages.items) |*msg| {
        try writer.print("{}:{s}\n", .{ msg.chat_id, msg.data });
    }
    try writer.print("end\n", .{});
}
