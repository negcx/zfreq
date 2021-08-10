const std = @import("std");
const testing = std.testing;

const Mutex = std.Thread.Mutex;

const DEBUG: bool = false;

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG) std.debug.print(fmt, args);
}

const ChannelError = error{Closed};
const ChannelStatus = enum { new, waiting_to_recv, sent };

pub fn Channel(comptime T: type) type {
    return struct {
        send_lock: Mutex = Mutex{},
        recv_lock: Mutex = Mutex{},
        recv_ptr: ?*T = null,
        status: ChannelStatus = .new,
        closed: bool = false,

        pub fn close(self: *@This()) void {
            self.closed = true;
        }

        fn reset(self: *@This()) void {
            self.status = .new;
            self.recv_ptr = null;
        }

        pub fn send(self: *@This(), data: T) ChannelError!void {
            if (self.closed) return error.Closed;

            const send_lock = self.send_lock.acquire();
            defer send_lock.release();

            while (true) {
                if (self.closed) return error.Closed;

                switch (self.status) {
                    .waiting_to_recv => {
                        if (self.recv_ptr) |recv_ptr| {
                            recv_ptr.* = data;
                            self.status = .sent;
                            return;
                        }
                    },
                    else => {},
                }
            }
        }

        pub fn recv(self: *@This(), data: *T) ChannelError!void {
            if (self.closed) return error.Closed;

            const recv_lock = self.recv_lock.acquire();
            defer recv_lock.release();

            self.recv_ptr = data;
            self.status = .waiting_to_recv;

            while (true) {
                if (self.closed) return error.Closed;

                switch (self.status) {
                    .sent => {
                        self.reset();
                        return;
                    },
                    else => {},
                }
            }
        }
    };
}

const Message = union(enum) { numbers: i64, results };

fn testThread(input_chan: *Channel(Message), output_chan: *Channel(i64)) void {
    var total: i64 = 0;
    var input: Message = undefined;

    while (true) {
        input_chan.recv(&input) catch {
            debug("numbers_chan closing\n", .{});
            return;
        };

        switch (input) {
            .numbers => |numbers| {
                total += numbers;
                debug("Received {}\n", .{input});
                debug("New thread total: {}\n", .{total});
            },
            .results => {
                output_chan.send(total) catch {
                    debug("Output channel closed unexpectedly\n", .{});
                };
                // total = 0;
                return;
            },
        }
    }
}

test "Channels" {
    var test_count: u16 = 0;
    const test_total: u16 = 10000;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    while (test_count < test_total) : (test_count += 1) {
        std.debug.print("Test {}\n", .{test_count});

        var numbers_chan = Channel(Message){};
        var total_chan = Channel(i64){};

        var i: i64 = 0;
        const max: i64 = 100;
        const max_threads = try std.Thread.getCpuCount();

        var threads = try allocator.alloc(std.Thread, max_threads);
        defer allocator.free(threads);

        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, testThread, .{ &numbers_chan, &total_chan });
        }

        while (i < max) : (i += 1) {
            debug("Sending {}\n", .{i});
            try numbers_chan.send(Message{ .numbers = i });
        }

        var thread_total: i64 = 0;

        for (threads) |_, t| {
            var chan_total: i64 = 0;
            try numbers_chan.send(.results);
            debug("Receiving #{}\n", .{t});
            try total_chan.recv(&chan_total);
            debug("Receiving total {}\n", .{chan_total});
            thread_total += chan_total;
        }

        numbers_chan.close();
        total_chan.close();

        var assert_total: i64 = 0;
        i = 0;
        while (i < max) : (i += 1) {
            assert_total += i;
        }

        debug("{} == {}\n", .{ assert_total, thread_total });
        try testing.expect(assert_total == thread_total);

        for (threads) |*thread| thread.join();
    }
}
