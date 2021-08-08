const std = @import("std");

const buffer_size = 1024 * 1024;
const Count = struct { char: u8 = undefined, count: u64 = 0 };

const DEBUG_MODE = false;

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

    var machines = try allocator.alloc(CountingMachine, max_threads);

    const file = try std.fs.cwd().openFile(filename, .{ .write = true });
    defer file.close();

    const in = file.reader();

    // Spawn one thread per counting machine
    for (machines) |*machine|
        try machine.init();

    var counts = [_]Count{.{}} ** 256;

    for (counts) |*count, i| {
        count.char = @intCast(u8, i);
    }

    // Loop while there is still new input and while threads are still working
    var input_remaining = true;
    var suspended_count: u8 = 0;
    while (input_remaining or suspended_count < max_threads) {
        suspended_count = 0;
        // std.debug.print("Inside infinite loop.\n", .{});

        for (machines) |*machine, machine_id| {
            debug("{} {} machine state\n", .{ machine_id, machine.state });
            switch (machine.state) {
                .waiting => {
                    if (input_remaining) {
                        var slice = machine.buffer[0..machine.buffer.len];
                        machine.byte_count = try in.read(slice);

                        debug("{} bytes read from input.\n", .{machine.byte_count});

                        if (machine.byte_count <= 0) {
                            // std.debug.print("No more input.\n", .{});
                            input_remaining = false;
                            machine.state = .suspended;
                        } else machine.state = .ready;
                    } else {
                        machine.state = .suspended;
                    }
                },
                .suspended => suspended_count += 1,
                else => continue,
            }
        }
    }

    // Sum the results
    for (machines) |*machine| {
        for (counts) |*count, i| {
            count.count += machine.counts[i];
        }
    }

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

    for (machines) |*machine|
        machine.thread.join();

    const elapsed = std.time.milliTimestamp() - start_time;

    try out.print("{} ms\n", .{elapsed});

    return 0;
}
