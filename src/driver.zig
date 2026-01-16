const std = @import("std");

const Diagnostics = @import("diagnostics.zig");

const Self = @This();

const Stdfile = std.fs.File;

allocator: std.mem.Allocator,

diagnostics: *Diagnostics,

pub fn init(allocator: std.mem.Allocator, diagnostics: *Diagnostics) Self {
    return Self {
        .allocator = allocator,
        .diagnostics = diagnostics
    };
}

pub fn run(self: *Self, code: []const u8) !void {
    _ = self;
    _ = code;
}

pub fn run_prompt(self: *Self) !void {
    const stdin = Stdfile.stdin();
    const stdout = Stdfile.stdout();

    var buffer : [4096]u8 = undefined;
    var in = stdin.reader(&buffer);

    var line = std.Io.Writer.Allocating.init(self.allocator);
    defer line.deinit();

    while (true) {

        try stdout.writeAll("> ");

        line.clearRetainingCapacity();

        _ = in.interface.streamDelimiter(&line.writer, '\n') catch |err| {
            if (err == error.EndOfStream) break else return err;
        };
        _ = in.interface.toss(1);

        try self.run(line.written());
    }

    if (line.written().len > 0) {
        try self.run(line.written());
    }
}


pub fn run_file(self: *Self, file : []const u8) !void {
    const MAX_SIZE_IN_BYTES = 256 * 1024 * 1024;
    const data = try std.fs.cwd().readFileAlloc(self.allocator, file, MAX_SIZE_IN_BYTES); 
    defer self.allocator.free(data);
    try self.run(data);
    if (self.diagnostics.has_errors()) {
        std.process.exit(65);
    }
}
