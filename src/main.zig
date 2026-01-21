const std = @import("std");

pub const ctrlseq = @import("./ctrlseq.zig");
pub const tty = @import("./tty.zig");
pub const queue = @import("./queue.zig");
pub const loop = @import("./loop.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    try stdout.print(ctrlseq.color.colorStr("Welcome to Minesweeper!\n", ctrlseq.color.red), .{});

    var term_read_buf: [256]u8 = undefined;
    var term_write_buf: [256]u8 = undefined;
    var term = try tty.Tty.init(io, &term_read_buf, &term_write_buf);
    defer term.deinit();

    var lp = try loop.Loop.init(io, &term);

    try lp.start();
    defer lp.stop();

    const seed = std.Io.Clock.now(.real, io).toMicroseconds();
    var grid = try Grid.init(alloc, @bitCast(seed), .{ .height = 10, .width = 20, .nb_of_bombs = 30 });
    defer grid.deinit();

    grid.reset();

    try term.enterGameScreen();

    var lock_game = false;

    while (true) {
        // draw
        var writer = term.writer.interface;
        try writer.print(ctrlseq.erase_display ++ ctrlseq.cursor_home, .{});
        try grid.display(&writer);

        // event
        const event = try lp.nextEvent();
        switch (event) {
            .key_press => |kp| {
                if (kp.codepoint == 'q') break;
            },
            .win_size => |ws| {
                if ((ws.col < grid.options.width) or (ws.row < grid.options.height)) {
                    try term.writer.interface.print(ctrlseq.erase_display ++ ctrlseq.cursor_home ++ "The terminal is not large enough", .{});
                    lock_game = true;
                } else {
                    lock_game = false;
                }
            },
            .mouse => |mouse| {
                if (lock_game) continue;
                // skip out of bounds
                const idx = grid.posToIdx(&.{ .x = (mouse.x / 2) + 1, .y = mouse.y }) orelse continue;

                switch (mouse.button) {
                    .left => {
                        _ = grid.uncoverCell(idx, true);
                    },
                    .right => {
                        grid.toggleFlag(idx);
                    },
                    else => continue,
                }

                if (grid.isGameOver()) break;
            },
        }
    }

    try term.exitGameScreen();

    try grid.displayClear(stdout);

    if (grid.allBombsUncovered()) {
        try stdout.print("You win!\r\n", .{});
    } else if (grid.exploded) {
        try stdout.print("You exploded!\r\n", .{});
    } else {
        try stdout.print("You abandoned!\r\n", .{});
    }
}

const Position = struct { x: u32, y: u32 };

const Grid = struct {
    alloc: std.mem.Allocator,

    cells: std.ArrayList(Cell),
    options: Self.Options,
    prng: std.Random.DefaultPrng,

    nb_of_cells_uncovered: u32 = 0,
    exploded: bool = false,

    const Self = @This();

    const Idx = usize;
    const Options = struct { width: u32, height: u32, nb_of_bombs: u32 };

    fn init(alloc: std.mem.Allocator, seed: u64, options: Self.Options) !Self {
        const grid_len = options.width * options.height;
        var cells = try std.ArrayList(Cell).initCapacity(alloc, grid_len);

        const prng = std.Random.DefaultPrng.init(seed);

        // make all cells default
        for (0..grid_len) |_| {
            try cells.append(alloc, .{});
        }

        return .{ .alloc = alloc, .cells = cells, .options = options, .prng = prng };
    }

    fn deinit(self: *Self) void {
        self.cells.deinit(self.alloc);
    }

    fn reset(self: *Self) void {
        var nb_of_bombs = self.options.nb_of_bombs;

        while (nb_of_bombs != 0) {
            const rpos = self.prng.random().intRangeAtMost(usize, 0, self.cells.items.len - 1);
            const cell = &self.cells.items[rpos];

            switch (cell.content) {
                .count => {
                    nb_of_bombs -= 1;
                    cell.content = .bomb;
                },
                .bomb => continue,
            }
        }

        for (self.cells.items, 0..) |cell, idx| {
            if (cell.content == .bomb) {
                const neighbors = self.neighborsIdx(idx);
                for (neighbors) |neighbor| {
                    self.cells.items[(neighbor orelse continue)].content.incrementCount();
                }
            }
        }
    }

    fn posToIdx(self: *const Self, pos: *const Position) ?Idx {
        if (pos.x > self.options.width or pos.y > self.options.height) return null;
        return (pos.y - 1) * self.options.width + (pos.x - 1);
    }

    fn neighborsIdx(self: *Self, idx: Idx) [8]?Idx {
        const width = self.options.width;
        const height = self.options.height;

        const first_col = idx % width == 0;
        const last_col = idx % width == (width - 1);
        const first_row = idx < width;
        const last_row = idx >= width * (height - 1);

        return .{
            if (!first_col) idx - 1 else null,
            if (!last_col) idx + 1 else null,
            if (!first_row) idx - width else null,
            if (!last_row) idx + width else null,
            if (!first_col and !first_row) idx - 1 - width else null,
            if (!first_col and !last_row) idx - 1 + width else null,
            if (!last_col and !first_row) idx + 1 - width else null,
            if (!last_col and !last_row) idx + 1 + width else null,
        };
    }

    fn display(self: *const Self, writer: *std.Io.Writer) !void {
        for (self.cells.items, 0..) |cell, idx| {
            try cell.display(writer);
            try writer.print(" ", .{});
            if (idx % self.options.width == self.options.width - 1) try writer.print("\r\n", .{});
        }
    }

    fn displayClear(self: *const Self, writer: *std.Io.Writer) !void {
        for (self.cells.items, 0..) |cell, idx| {
            try cell.displayContent(writer);
            try writer.print(" ", .{});
            if (idx % self.options.width == self.options.width - 1) try writer.print("\r\n", .{});
        }
    }

    fn uncoverCell(self: *Self, idx: Idx, from_user: bool) void {
        var cell = &self.cells.items[idx];

        if (cell.state == .flagged) return;
        const old_state = cell.state;
        cell.state = .revealed;

        if (old_state == .covered) self.nb_of_cells_uncovered += 1;

        switch (cell.content) {
            .bomb => {
                self.exploded = true;
                return;
            },
            .count => |n| {
                const neighbors = self.neighborsIdx(idx);
                if (old_state == .covered and n == 0) {
                    for (neighbors) |neighbor| self.uncoverCell(neighbor orelse continue, false);
                } else if (old_state == .revealed and n != 0 and from_user) {
                    var count_flags: u32 = 0;
                    for (neighbors) |neighbor| if (self.cells.items[neighbor orelse continue].state == .flagged) {
                        count_flags += 1;
                    };
                    if (count_flags != self.cells.items[idx].content.count) return;
                    for (neighbors) |neighbor| if (self.cells.items[neighbor orelse continue].state == .covered) {
                        self.uncoverCell(neighbor orelse continue, false);
                    };
                }
            },
        }
    }

    fn toggleFlag(self: *Self, idx: Idx) void {
        const cell = &self.cells.items[idx];

        cell.state = switch (cell.state) {
            .flagged => .covered,
            .covered => .flagged,
            .revealed => .revealed,
        };
    }

    fn allBombsUncovered(self: *const Self) bool {
        return self.nb_of_cells_uncovered + self.options.nb_of_bombs == self.cells.items.len;
    }

    fn isGameOver(self: *const Self) bool {
        return self.exploded or self.allBombsUncovered();
    }
};

const Cell = struct {
    state: CellState = .covered,
    content: CellContent = .{ .count = 0 },

    fn display(self: *const Cell, writer: *std.Io.Writer) !void {
        return switch (self.state) {
            .flagged => try writer.print(ctrlseq.color.colorStr("~", ctrlseq.color.orange), .{}),
            .covered => try writer.print("-", .{}),
            .revealed => self.displayContent(writer),
        };
    }

    fn displayContent(self: *const Cell, writer: *std.Io.Writer) !void {
        return switch (self.content) {
            .count => |num| if (num == 0) {
                try writer.print("0", .{});
            } else {
                try writer.print(ctrlseq.color.colorStr("{c}", ctrlseq.color.blue), .{num + @as(u8, 48)});
            },
            .bomb => try writer.print(ctrlseq.color.colorStr("*", ctrlseq.color.red), .{}),
        };
    }
};

const CellState = enum {
    flagged,
    covered,
    revealed,
};

const CellContent = union(enum) {
    count: u8,
    bomb,

    fn incrementCount(self: *CellContent) void {
        switch (self.*) {
            .count => |n| {
                self.* = .{ .count = n + 1 };
            },
            .bomb => {},
        }
    }
};

const Action = enum { uncover, flag };

const MinesweeperError = error{ParseError};
