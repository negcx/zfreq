//! Copyright (c) Kyle Johnson 2021
//!
//! The Channels implementation below is an implementation of *unbuffered* channels,
//! similar to Go's unbuffered channels. Both sides of the channel block until
//! the message is successfully delivered.

const std = @import("std");
const testing = std.testing;

const Mutex = std.Thread.Mutex;
const AutoResetEvent = std.Thread.AutoResetEvent;

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
        ready_to_receive: AutoResetEvent = AutoResetEvent{},
        sent: AutoResetEvent = AutoResetEvent{},
        recv_ptr: ?*T = null,
        closed: bool = false,

        /// Close does not acquire a read or write lock, but no other functionality writes to
        /// the `closed` variable. This is intended as a way to shut down all the blocking
        /// sending and receiving when there is nothing else to send.
        pub fn close(self: *@This()) void {
            @atomicStore(bool, &self.closed, true, std.builtin.AtomicOrder.Monotonic);
        }

        /// Send will acquire a send lock, ensuring that only one sender can modify data
        /// at a time. The sender plays a passive role, waiting until the state of the chan
        /// is in `waiting_to_recv` and until the pointer to the receiver's memory are
        /// available to act. At that point, only the sender and not the receiver can update
        /// the channel, copying the data and then transitioning the state to `sent`.
        pub fn send(self: *@This(), data: T) ChannelError!void {
            var closed = false;
            closed = @atomicLoad(bool, &self.closed, std.builtin.AtomicOrder.Monotonic);
            if (closed) return error.Closed;

            const send_lock = self.send_lock.acquire();
            defer send_lock.release();

            while (true) {
                closed = @atomicLoad(bool, &self.closed, std.builtin.AtomicOrder.Monotonic);
                if (closed) return error.Closed;
                self.ready_to_receive.timedWait(100) catch continue;
                break;
            }

            if (self.recv_ptr) |recv_ptr| recv_ptr.* = data;

            self.sent.set();
        }

        /// recv acquires a lock on receiving ensuring its the only receiver that can write
        /// to the channel. Upon acquiring the lock, it updates the status to `waiting_to_recv`
        /// and adds its pointer to memory. This is the handoff to the sender. From here, recv
        /// waits for the state to transition to `sent` at which point the receiver knows that
        /// the sender has copied memory into its pointer. The receiver then resets the state of
        /// the channel before releasing its lock.
        pub fn recv(self: *@This(), data: *T) ChannelError!void {
            var closed: bool = false;
            closed = @atomicLoad(bool, &self.closed, std.builtin.AtomicOrder.Monotonic);
            if (closed) return error.Closed;

            const recv_lock = self.recv_lock.acquire();
            defer recv_lock.release();

            closed = @atomicLoad(bool, &self.closed, std.builtin.AtomicOrder.Monotonic);
            if (closed) return error.Closed;

            self.recv_ptr = data;

            self.ready_to_receive.set();

            while (true) {
                closed = @atomicLoad(bool, &self.closed, std.builtin.AtomicOrder.Monotonic);
                if (closed) return error.Closed;

                self.sent.timedWait(100) catch continue;
                break;
            }

            self.recv_ptr = null;
        }
    };
}

// TESTS

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
