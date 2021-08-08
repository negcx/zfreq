const std = @import("std");

const buffer_size = 1024 * 1024 * 16;
const Count = struct { char: u8 = undefined, count: u64 = 0 };

fn cmpCount(comptime _context: type, lhs: Count, rhs: Count) bool {
    _ = _context;
    return lhs.count >= rhs.count;
}

const CountingMachineState = enum { waiting, ready, suspended };

const CountingMachine = struct {
    counts: [256]u64 = [_]u64{0} ** 256,
    buffer: [buffer_size]u8 = undefined,
    byte_count: usize = 0,
    state: CountingMachineState = CountingMachineState.waiting,
    thread: std.Thread = undefined,

    fn init(self: *CountingMachine) anyerror!void {
        for (self.counts) |*c|
            c.* = 0;

        self.byte_count = 0;
        self.state = CountingMachineState.waiting;

        self.thread = try std.Thread.spawn(.{}, count, .{self});
    }

    fn count(self: *CountingMachine) void {
        std.debug.print("Thread starting.\n", .{});

        while (self.state != CountingMachineState.suspended) {
            switch (self.state) {
                CountingMachineState.ready => self.run(),
                else => continue,
            }
        }

        std.debug.print("Thread ending.\n", .{});
    }

    fn run(self: *CountingMachine) void {
        // std.debug.print("Staring to count in thread...\n", .{});

        const slice = self.buffer[0..self.byte_count];
        for (slice) |byte| self.counts[byte] += 1;
        self.state = CountingMachineState.waiting;

        // std.debug.print("Counting in thread finished.\n", .{});
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

    //var threads = try allocator.alloc(std.Thread, max_threads);

    const file = try std.fs.cwd().openFile(filename, .{ .write = true });
    defer file.close();

    const in = file.reader();

    // const in = std.io.getStdIn().reader();

    // Spawn one thread per counting machine
    for (machines) |*machine|
        try machine.init();
    //     // std.debug.print("{}, {} initial state\n", .{ machine.state, machine.counts[0] });
    //     var thread = try std.Thread.spawn(.{}, CountingMachine.count, .{machine});
    //     thread.detach();
    // }

    var counts = [_]Count{.{}} ** 256;

    for (counts) |*count, i| {
        count.char = @intCast(u8, i);
    }

    // Loop while there is still new input and while threads are still working
    var input_remaining = true;
    var working_count: u8 = 0;
    while (input_remaining or working_count > 0) {
        working_count = 0;
        // std.debug.print("Inside infinite loop.\n", .{});

        for (machines) |*machine, machine_id| {
            std.debug.print("{} {} machine state\n", .{ machine_id, machine.state });
            switch (machine.state) {
                .waiting => {
                    if (input_remaining) {
                        var slice = machine.buffer[0..machine.buffer.len];
                        machine.byte_count = try in.read(slice);

                        std.debug.print("{} bytes read from input.\n", .{machine.byte_count});

                        if (machine.byte_count <= 0) {
                            // std.debug.print("No more input.\n", .{});
                            input_remaining = false;
                            machine.state = .suspended;
                        } else machine.state = .ready;
                    } else {
                        machine.state = .suspended;
                    }
                },
                .ready => working_count += 1,
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
