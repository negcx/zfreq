const std = @import("std");

const buffer_size = 1024 * 1024;
const Count = struct { char: u8 = undefined, count: u64 = 0 };

const DEBUG_MODE = true;

const Mutex = std.Thread.Mutex;

const ChannelError = error{Closed};

fn UnbufferedChannel(comptime T: type) type {
    return struct {
        lock: Mutex = Mutex{},
        data: ?T = null,
        closed: bool = false,

        pub fn close(self: *@This()) void {
            if (self.closed) return;
            const lock = self.lock.acquire();
            defer lock.release();
            self.closed = true;
        }

        pub fn send(self: *@This(), data: T) ChannelError!void {
            if (self.closed) return error.Closed;

            const lock = self.lock.acquire();
            if (self.closed) {
                lock.release();
                return error.Closed;
            }
            self.data = data;
            lock.release();
            while (self.data != null and !self.closed) {
                debug("Looping on send.\n", .{});
            }
        }

        pub fn recv(self: *@This(), data: *T) ChannelError!void {
            if (self.closed) return error.Closed;

            while (true and !self.closed) {
                debug("Looping on receive\n", .{});
                if (self.data != null) {
                    const lock = self.lock.acquire();
                    defer lock.release();

                    if (self.closed) return error.Closed;
                    if (self.data == null) continue;

                    data.* = self.data orelse unreachable;
                    self.data = null;
                    return;
                }
            }

            if (self.closed) return error.Closed;
        }
    };
}

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG_MODE) {
        std.debug.print(fmt, args);
    }
}

fn cmpCount(comptime _context: type, lhs: Count, rhs: Count) bool {
    _ = _context;
    return lhs.count >= rhs.count;
}

const CountingMachineState = enum { waiting, ready, running, suspended };

const CountingMachine = struct {
    counts: [256]u64 = [_]u64{0} ** 256,
    buffer: [buffer_size]u8 = undefined,
    byte_count: usize = 0,
    state: CountingMachineState = .waiting,
    thread: std.Thread = undefined,

    fn init(self: *CountingMachine) anyerror!void {
        for (self.counts) |*c|
            c.* = 0;

        self.byte_count = 0;
        self.state = .waiting;

        self.thread = try std.Thread.spawn(.{}, count, .{self});
    }

    fn count(self: *CountingMachine) void {
        debug("Thread starting.\n", .{});

        while (self.state != CountingMachineState.suspended) {
            switch (self.state) {
                .ready => self.state = .running,
                .running => self.run(),
                else => continue,
            }
        }

        debug("Thread ending.\n", .{});
    }

    fn run(self: *CountingMachine) void {
        debug("{} Staring to count in thread...\n", .{std.Thread.getCurrentId()});

        const slice = self.buffer[0..self.byte_count];
        for (slice) |byte| self.counts[byte] += 1;
        self.state = CountingMachineState.waiting;

        debug("{} Counting in thread finished.\n", .{std.Thread.getCurrentId()});
    }
};

const SimpleCount = [256]u64;
const Data = struct { buf: [buffer_size]u8, size: usize };
const DataChannel = UnbufferedChannel(Data);
const ResultsChannel = UnbufferedChannel(SimpleCount);

fn countThread(in_chan: *DataChannel, out_chan: *ResultsChannel) void {
    var counts: [256]u64 = [_]u64{0} ** 256;
    var data: Data = undefined;

    debug("Thread started.\n", .{});

    while (true) {
        in_chan.recv(&data) catch {
            debug("Data channel closed, sending results\n", .{});
            out_chan.send(counts) catch return;
            return;
        };

        debug("Data received\n", .{});

        for (data.buf[0..data.size]) |byte| counts[byte] += 1;
    }
}

pub fn main() anyerror!u8 {
    const start_time = std.time.milliTimestamp();

    // Allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // We don't need to free the memory as the operating system will do it for us.
    // defer arena.deinit();
    var allocator = &arena.allocator;
    var args_iterator = std.process.args();
    _ = args_iterator.skip();

    var filename = try (args_iterator.next(allocator) orelse {
        std.debug.warn("First argument should be a filename\n", .{});
        return error.InvalidArgs;
    });

    const max_threads = try std.Thread.getCpuCount();

    var data_chan = DataChannel{};
    var results_chan = ResultsChannel{};
    // var buf: [buffer_size]u8 = [_]u8{0} ** buffer_size;

    var i: u8 = 0;

    var threads = try allocator.alloc(std.Thread, max_threads);

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, countThread, .{ &data_chan, &results_chan });
    }

    // while (i < max_threads) : (i += 1) {
    //     var thread = try std.Thread.spawn(.{}, countThread, .{ &data_chan, &results_chan });
    //     defer thread.join();
    // }

    var all_counts = try allocator.alloc(SimpleCount, max_threads);

    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const in = file.reader();

    var counts = [_]Count{.{}} ** 256;

    for (counts) |*count, n| {
        count.char = @intCast(u8, n);
    }

    for (all_counts) |*c| {
        for (c.*) |*x| x.* = 0;
    }

    var data: Data = undefined;

    while (true) {
        data.size = try in.read(data.buf[0..buffer_size]);
        if (data.size <= 0) break;
        debug("{} bytes read\n", .{data.size});
        try data_chan.send(data);
    }

    data_chan.close();

    i = 0;
    while (i < max_threads) : (i += 1) {
        debug("Receiving results\n", .{});
        try results_chan.recv(&all_counts[i]);
    }

    for (all_counts) |thread_count| {
        for (counts) |*count, n| {
            count.count += thread_count[n];
        }
    }

    // // Loop while there is still new input and while threads are still working
    // var input_remaining = true;
    // var suspended_count: u8 = 0;
    // while (input_remaining or suspended_count < max_threads) {
    //     suspended_count = 0;
    //     // std.debug.print("Inside infinite loop.\n", .{});

    //     for (machines) |*machine, machine_id| {
    //         debug("{} {} machine state\n", .{ machine_id, machine.state });
    //         switch (machine.state) {
    //             .waiting => {
    //                 if (input_remaining) {
    //                     var slice = machine.buffer[0..machine.buffer.len];
    //                     machine.byte_count = try in.read(slice);

    //                     debug("{} bytes read from input.\n", .{machine.byte_count});

    //                     if (machine.byte_count <= 0) {
    //                         // std.debug.print("No more input.\n", .{});
    //                         input_remaining = false;
    //                         machine.state = .suspended;
    //                     } else machine.state = .ready;
    //                 } else {
    //                     machine.state = .suspended;
    //                 }
    //             },
    //             .suspended => suspended_count += 1,
    //             else => continue,
    //         }
    //     }
    // }

    // // Sum the results
    // for (machines) |*machine| {
    //     for (counts) |*count, i| {
    //         count.count += machine.counts[i];
    //     }
    // }

    // Sort and print the results
    std.sort.sort(Count, &counts, Count, cmpCount);

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

    // for (machines) |*machine|
    //     machine.thread.join();

    const elapsed = std.time.milliTimestamp() - start_time;

    try out.print("{} ms\n", .{elapsed});

    return 0;
}
