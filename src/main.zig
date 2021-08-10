const std = @import("std");
const Channel = @import("chan.zig").Channel;

const buffer_size = 1024 * 1024;
const Buffer = [buffer_size]u8;
const WorkResponse = union(enum) { bytes_read: u64, eof };
const WorkRequest = struct { buf: *Buffer, response_chan: *Channel(WorkResponse) };

const WorkChannel = Channel(WorkRequest);

const CountResult = [256]u64;
const CountResultChannel = Channel(CountResult);

const CharCount = struct { char: u8 = undefined, count: u64 = 0 };

pub fn threadWorker(work_chan: *WorkChannel, result_chan: *CountResultChannel) void {
    var count: CountResult = [_]u64{0} ** 256;
    var buf: Buffer = undefined;
    var response_chan = Channel(WorkResponse){};
    var response: WorkResponse = undefined;
    var work_request = WorkRequest{ .buf = &buf, .response_chan = &response_chan };

    while (true) {
        work_chan.send(work_request) catch unreachable;
        response_chan.recv(&response) catch unreachable;
        switch (response) {
            .bytes_read => |bytes_read| {
                for (buf[0..bytes_read]) |byte| count[byte] += 1;
            },

            .eof => {
                result_chan.send(count) catch unreachable;
                return;
            },
        }
    }
}

fn cmpCount(comptime _context: type, lhs: CharCount, rhs: CharCount) bool {
    _ = _context;
    return lhs.count >= rhs.count;
}

pub fn main() anyerror!void {
    const start_time = std.time.milliTimestamp();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = &arena.allocator;
    defer arena.deinit();

    const max_threads = try std.Thread.getCpuCount();

    var threads = try allocator.alloc(std.Thread, max_threads);
    defer allocator.free(threads);

    var request_chan = WorkChannel{};
    var result_chan = CountResultChannel{};

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, threadWorker, .{ &request_chan, &result_chan });
    }

    var counts = [_]CharCount{.{}} ** 256;
    for (counts) |*count, c| count.char = @intCast(u8, c);

    // File reading
    var args_iterator = std.process.args();
    _ = args_iterator.skip();

    var filename = try (args_iterator.next(allocator) orelse {
        std.debug.warn("Expected filename\n", .{});
        return error.InvalidArgs;
    });

    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var bytes_read: usize = 0;
    var work_request: WorkRequest = undefined;
    var eof_sent: u8 = 0;
    var result: CountResult = [_]u64{0} ** 256;

    while (eof_sent < max_threads) {
        try request_chan.recv(&work_request);
        bytes_read = try file.read(work_request.buf);
        if (bytes_read > 0) try work_request.response_chan.send(WorkResponse{ .bytes_read = bytes_read }) else {
            try work_request.response_chan.send(.eof);
            eof_sent += 1;
        }
    }

    for (threads) |_| {
        try result_chan.recv(&result);
        for (result) |count, c| counts[c].count += count;
    }

    // Sort and print the results
    std.sort.sort(CharCount, &counts, CharCount, cmpCount);

    const out = std.io.getStdOut().writer();

    for (counts) |*count| {
        if (count.count > 0) {
            if (count.char >= 20 and count.char <= 126) {
                try out.print("'{c}' {}\n", .{ count.char, count.count });
            } else {
                try out.print("0x{X} {}\n", .{ count.char, count.count });
            }
        }
    }

    const elapsed = std.time.milliTimestamp() - start_time;

    try out.print("{} ms\n", .{elapsed});

    for (threads) |*thread| thread.join();
}
