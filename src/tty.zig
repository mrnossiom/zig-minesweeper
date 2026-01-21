const std = @import("std");
const fs = std.fs;
const posix = std.posix;

const root = @import("root");
const loop = root.loop;
const queue = root.queue;
const ctrlseq = root.ctrlseq;

pub const Tty = if (@import("builtin").os.tag == .linux) PosixTty else @compileError("os not supported");

/// Manages a posix tty. Making it easy to manipulate raw features.
pub const PosixTty = struct {
    io: std.Io,

    file: std.Io.File,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,

    // initial terminal IOs settings
    initial_termios: posix.termios,

    pub fn init(io: std.Io, read_buf: []u8, write_buf: []u8) !PosixTty {
        // get the current terminal
        const file = try std.Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write });
        const initial_termios = try makeRawTerminal(file.handle);

        const reader = file.reader(io, read_buf);
        const writer = file.writer(io, write_buf);

        return .{
            .io = io,
            .file = file,
            .reader = reader,
            .writer = writer,
            .initial_termios = initial_termios,
        };
    }

    pub fn deinit(self: *PosixTty) void {
        // reset terminal properties
        posix.tcsetattr(self.file.handle, .FLUSH, self.initial_termios) catch {};
        // close the tty handle
        self.file.close(self.io);
        // remove the sigaction handler
        posix.sigaction(posix.SIG.WINCH, null, null);
    }

    pub fn getWinsize(self: *const PosixTty) !loop.WinSize {
        var winsize = posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };

        // see tiocgwincz(2const)
        const err = posix.system.ioctl(self.file.handle, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
        if (posix.errno(err) != .SUCCESS) return error.IoError;
        return .{ .row = winsize.row, .col = winsize.col };
    }

    pub fn enterGameScreen(self: *PosixTty) !void {
        try self.writer.interface.print(ctrlseq.alt_screen_enter ++ ctrlseq.cursor_hide ++ ctrlseq.mouse_enable, .{});
    }
    pub fn exitGameScreen(self: *PosixTty) !void {
        try self.writer.interface.print(ctrlseq.alt_screen_exit ++ ctrlseq.cursor_show ++ ctrlseq.mouse_disable, .{});
    }
};

// Returns original terminal IO settings to restore them later
fn makeRawTerminal(fd: posix.fd_t) !posix.termios {
    const initial = try posix.tcgetattr(fd);

    var next = initial;
    // see termios(3)
    next.iflag.BRKINT = false;
    next.iflag.ICRNL = false;
    next.iflag.IGNBRK = false;
    next.iflag.IGNCR = false;
    next.iflag.INLCR = false;
    next.iflag.ISTRIP = false;
    next.iflag.IXON = false;
    next.iflag.PARMRK = false;

    // don't post-process output
    next.oflag.OPOST = false;

    next.lflag.ECHO = false;
    next.lflag.ECHONL = false;
    next.lflag.ICANON = false;
    next.lflag.IEXTEN = false;
    next.lflag.ISIG = false;

    next.cflag.CSIZE = .CS8;
    next.cflag.PARENB = false;
    try posix.tcsetattr(fd, .FLUSH, next);

    return initial;
}
