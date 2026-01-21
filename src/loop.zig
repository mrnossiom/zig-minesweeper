const std = @import("std");
const posix = std.posix;

const root = @import("root");
const tty = root.tty;
const queue = root.queue;

const SigHandler = struct {
    ctx: *anyopaque,
    handlerFn: *const fn (ctx: *anyopaque) void,
};

pub const Loop = struct {
    queue: queue.Queue(Event, 16),

    tty: *root.tty.Tty,
    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = .init(false),

    const Self = @This();

    pub fn init(io: std.Io, term: *tty.Tty) !Self {
        return .{ .queue = .init(io), .tty = term };
    }

    pub fn start(self: *Self) !void {
        self.registerWinSizeChange();
        self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
    }

    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
        // deinit memory on foreign thread
    }

    var handler: ?SigHandler = null;

    pub fn registerWinSizeChange(self: *Self) void {
        handler = .{ .ctx = self, .handlerFn = Self.handleWinSizeChange };

        // setup signal handler for window size change
        const action = posix.Sigaction{
            .handler = .{ .handler = Self.handleWinSizeSig },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &action, null);
    }

    fn handleWinSizeSig(_: std.os.linux.SIG) callconv(.c) void {
        if (handler) |hdl| hdl.handlerFn(hdl.ctx);
    }

    fn handleWinSizeChange(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const win_size = self.tty.getWinsize() catch unreachable;
        self.queue.pushFront(.{ .win_size = win_size }) catch unreachable;
    }

    fn parseEvent(buf: []const u8) !?Event {
        switch (buf.len) {
            0 => unreachable,
            1 => {
                // single key press
                return .{ .key_press = .{ .codepoint = buf[0] } };
            },
            6 => {
                if (std.mem.eql(u8, buf[0..3], "\x1b[M")) {
                    // csi code
                    return .{ .mouse = .{ .button = @enumFromInt(buf[3] & 0b11), .x = buf[4] - 32, .y = buf[5] - 32 } };
                } else {
                    // not handled, discard
                    // std.debug.print("{any}\r\n", .{buf});
                    return null;
                }
            },
            else => {
                // std.debug.print("{any}\r\n", .{buf});
                return null;
            },
        }
    }

    fn run(self: *Self) !void {
        while (true) {
            var buf: [16]u8 = undefined;
            const len = try self.tty.reader.interface.readSliceShort(&buf);

            const ev = try Self.parseEvent(buf[0..len]) orelse continue;
            try self.queue.pushFront(ev);
        }
    }

    pub fn nextEvent(self: *Self) !Event {
        return self.queue.popBack();
    }
};

pub const Event = union(enum) {
    key_press: Key,
    win_size: WinSize,
    mouse: Mouse,
};

pub const Key = struct { codepoint: u8 };
pub const WinSize = struct { row: u16, col: u16 };
pub const Mouse = struct { button: MouseButton, x: u16, y: u16 };
pub const MouseButton = enum(u2) { left = 0, middle = 1, right = 2, release = 3 };
