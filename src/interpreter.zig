const std = @import("std");

const Self = @This();

const Stdfile = std.fs.File;

allocator: std.mem.Allocator,

had_error: bool,

pub fn init(allocator: std.mem.Allocator) Self {
    return Self {
        .allocator = allocator,
        .had_error = false,
    };
}

pub fn report_error(self: *Self, line: usize, message: []const u8) void {
    self.report("<inline>", line, "{s}", .{message});
}

pub fn report(
    self: *Self, 
    where: []const u8, 
    line: usize, 
    comptime fmt: []const u8, 
    args: anytype
) void {
    var stderr_buffer : [1024]u8 = undefined;
    _ = std.fmt.bufPrint(&stderr_buffer, "[{s}:{d}]" ++ fmt, .{where, line} ++ args) catch |err| {
        std.debug.panic("Broken bufprint: {s}", .{@errorName(err)});
    };
    Stdfile.stderr().writeAll(&stderr_buffer) catch |err| {
        std.debug.panic("Broken stderr stream: {s}", .{@errorName(err)});
    };
    self.had_error = true;
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
        
        self.had_error = false;
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
    if (self.had_error) {
        std.process.exit(65);
    }
}
