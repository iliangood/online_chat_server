const std = @import("std");

const message = struct {
    chat_id: usize,
    data: std.ArrayList(u8),
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout = std.Io.File.stdout().writer(io, &.{});
    const writer = &stdout.interface;
    _ = writer;
    const allocator = std.heap.smp_allocator;
    var messages = try std.ArrayList(u8).initCapacity(allocator, 64);
    var chat_counter: usize = 0;

    const addres = std.tc

    while (true) {}
}
