const std = @import("std");

pub const Count = struct { char: u8 = undefined, count: u64 = 0 };

pub fn cmpCount(comptime _context: type, lhs: Count, rhs: Count) bool {
    _ = _context;
    return lhs.count >= rhs.count;
}

pub fn main() anyerror!u8 {
    var counts = [_]Count{.{}} ** 256;

    for (counts) |*count, i| {
        count.char = @intCast(u8, i);
    }

    const in = std.io.getStdIn().reader();
    const out = std.io.getStdOut().writer();

    // while (true) {
    //     counts[in.readByte() catch break].count += 1;
    // }

    var buffer = try std.heap.page_allocator.alloc(u8, 1024 * 1024);
    var bytes_read: usize = 1;

    while (true) {
        bytes_read = try in.read(buffer);
        if (bytes_read <= 0) {
            break;
        }
        var bytes = buffer[0..bytes_read];
        for (bytes) |byte| {
            counts[byte].count += 1;
        }
    }

    std.sort.sort(Count, &counts, Count, cmpCount);

    for (counts) |*count| {
        if (count.count > 0) {
            if (count.char >= 20 and count.char <= 126) {
                try out.print("'{c}' {}\n", .{ count.char, count.count });
            } else {
                try out.print("0x{X} {}\n", .{ count.char, count.count });
            }
        }
    }

    return 0;
}
