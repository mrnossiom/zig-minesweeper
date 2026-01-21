const std = @import("std");
const Io = std.Io;

pub fn Queue(
    comptime T: type,
    comptime size: usize,
) type {
    return struct {
        buf: [size]T = undefined,

        len: usize = 0,
        tail_idx: usize = 0,

        io: Io,
        mutex: Io.Mutex = .init,
        not_full: Io.Condition = .init,
        not_empty: Io.Condition = .init,

        const Self = @This();

        pub fn init(io: Io) Self {
            return .{ .io = io };
        }

        pub fn pushFront(self: *Self, el: T) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            while (self.len == size) {
                try self.not_full.wait(self.io, &self.mutex);
            }

            if (self.len == 0) {
                self.not_empty.signal(self.io);
            }

            self.buf[(self.tail_idx + self.len) % size] = el;
            self.len += 1;
        }

        pub fn popBack(self: *Self) !T {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            while (self.len == 0) {
                try self.not_empty.wait(self.io, &self.mutex);
            }

            if (self.len == size) {
                self.not_full.signal(self.io);
            }

            const el = self.buf[self.tail_idx];
            self.len -= 1;
            self.tail_idx = (self.tail_idx + 1) % size;

            return el;
        }
    };
}

test "queue" {
    var queue = Queue(u8, 2).init();

    queue.pushFront(1);
    queue.pushFront(2);
    const el1 = queue.popBack();
    std.debug.assert(el1 == 1);
    queue.pushFront(3);
}
